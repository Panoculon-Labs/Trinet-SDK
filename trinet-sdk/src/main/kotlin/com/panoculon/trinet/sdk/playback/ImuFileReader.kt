package com.panoculon.trinet.sdk.playback

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.model.ImuSample
import com.panoculon.trinet.sdk.recording.ImuFileWriter
import java.io.File
import java.io.RandomAccessFile
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * Memory-mapped reader for TRIMU001 sidecar files. Provides O(1) random access
 * by index and binary search by timestamp.
 *
 * Compatible with v1 (44 B), v2 (76 B), v3 (80 B) sample sizes — but only v3
 * decodes the full [ImuSample] model. v1/v2 files report fields beyond what
 * they store as zero / identity.
 */
class ImuFileReader(file: File) : AutoCloseable {

    val sampleRateHz: Int
    val accelFs: Int
    val gyroFs: Int
    val startTimeNs: Long
    val videoStartNs: Long
    val flags: Int
    val version: Int
    val sampleCount: Int
    val sampleSize: Int

    private val raf = RandomAccessFile(file, "r")
    private val map: MappedByteBuffer
    private val dataOffset: Int = ImuFileWriter.HEADER_SIZE

    init {
        require(file.length() >= ImuFileWriter.HEADER_SIZE) { "imu file too short: ${file.length()}" }
        map = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, file.length())
            .also { it.order(java.nio.ByteOrder.LITTLE_ENDIAN) }
        // Header
        val header = ByteArray(ImuFileWriter.HEADER_SIZE)
        map.position(0); map.get(header)
        val r = BinaryReader(header)
        val magic = r.bytes(8)
        require(magic.contentEquals(ImuFileWriter.MAGIC)) { "bad imu magic" }
        version = r.u32().toInt()
        sampleRateHz = r.u32().toInt()
        accelFs = r.u16()
        gyroFs = r.u16()
        startTimeNs = r.u64()
        videoStartNs = r.u64()
        flags = if (version >= 3) r.u32().toInt() else 0

        sampleSize = when (version) {
            1 -> 44
            2 -> 76
            3 -> 80
            else -> throw IllegalArgumentException("unsupported imu version $version")
        }
        val payloadBytes = file.length().toInt() - ImuFileWriter.HEADER_SIZE
        sampleCount = payloadBytes / sampleSize
    }

    /** Read the [index]-th sample (0-based). */
    fun sampleAt(index: Int): ImuSample {
        require(index in 0 until sampleCount) { "index $index out of bounds [0, $sampleCount)" }
        val pos = dataOffset + index * sampleSize
        val buf = ByteArray(sampleSize)
        map.position(pos); map.get(buf)
        return when (version) {
            3 -> ImuSample.read(BinaryReader(buf))
            else -> readLegacy(buf)
        }
    }

    /** Read all samples (use only on bounded files; mmap helps but allocation grows linearly). */
    fun readAll(): List<ImuSample> = (0 until sampleCount).map { sampleAt(it) }

    /** Find the sample index whose timestamp is closest to [timestampNs] (binary search). */
    fun indexAt(timestampNs: Long): Int {
        if (sampleCount == 0) return -1
        var lo = 0; var hi = sampleCount - 1
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val midTs = timestampAt(mid)
            if (midTs < timestampNs) lo = mid + 1 else hi = mid
        }
        // pick whichever neighbour is closer
        if (lo > 0 && kotlin.math.abs(timestampAt(lo - 1) - timestampNs) <
            kotlin.math.abs(timestampAt(lo) - timestampNs)) return lo - 1
        return lo
    }

    private fun timestampAt(index: Int): Long {
        val pos = dataOffset + index * sampleSize
        return java.lang.Long.reverseBytes(map.getLong(pos)).let {
            // mmap is set to LITTLE_ENDIAN; getLong already reads LE — this is a no-op.
            map.getLong(pos)
        }
    }

    private fun readLegacy(buf: ByteArray): ImuSample {
        val r = BinaryReader(buf)
        val ts = r.u64()
        val accel = r.floatArray(3)
        val gyro = r.floatArray(3)
        val mag = r.floatArray(3)
        val temp = if (version >= 2) r.f32() else 0f
        val quat = if (version >= 2) r.floatArray(4) else floatArrayOf(0f, 0f, 0f, 1f)
        val lin = if (version >= 2) r.floatArray(3) else floatArrayOf(0f, 0f, 0f)
        return ImuSample(ts, accel, gyro, mag, temp, quat, lin, 0f)
    }

    override fun close() { raf.close() }
}
