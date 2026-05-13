package com.panoculon.trinet.sdk.playback

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.model.TriposeSample
import com.panoculon.trinet.sdk.recording.PoseFileWriter
import java.io.File
import java.io.RandomAccessFile
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/**
 * Reader for TRPSF001 v1 pose sidecars. Memory-mapped for O(1) random access
 * and a binary-search-by-sof_timestamp lookup mirroring [ImuFileReader].
 *
 * The firmware writer claims `record_size = 136` in the header but the actual
 * on-disk stride is 120 bytes (8-byte wall stamp + 112-byte packed payload).
 * This reader infers the stride from file size minus header so it stays
 * correct regardless of whether the firmware bug gets fixed.
 */
class PoseFileReader(file: File) : AutoCloseable {

    val version: Int
    val recordSize: Int
    val recordCount: Int

    /** Stride actually observed in the file. Will be [PoseFileWriter.RECORD_STRIDE_BYTES]
     *  (120) on real recordings; can differ once firmware bumps to a wider payload. */
    val effectiveStride: Int

    private val raf = RandomAccessFile(file, "r")
    private val map: MappedByteBuffer
    private val dataOffset: Int = PoseFileWriter.HEADER_SIZE

    init {
        require(file.length() >= PoseFileWriter.HEADER_SIZE) { "pose file too short: ${file.length()}" }
        map = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, file.length())
            .also { it.order(java.nio.ByteOrder.LITTLE_ENDIAN) }
        val header = ByteArray(PoseFileWriter.HEADER_SIZE)
        map.position(0); map.get(header)
        val r = BinaryReader(header)
        val magic = r.bytes(8)
        require(magic.contentEquals(PoseFileWriter.MAGIC)) { "bad pose magic" }
        version = r.u32().toInt()
        recordSize = r.u32().toInt()

        val payloadBytes = (file.length() - PoseFileWriter.HEADER_SIZE).toInt()
        // Real stride is 120 bytes on every shipping firmware; trust geometry,
        // not the header (which reports 136 due to a known firmware bug).
        effectiveStride = PoseFileWriter.RECORD_STRIDE_BYTES
        recordCount = if (payloadBytes <= 0) 0 else payloadBytes / effectiveStride
    }

    /** Read the [index]-th pose record (0-based). Returns (wallClockNs, sample). */
    fun recordAt(index: Int): Pair<Long, TriposeSample> {
        require(index in 0 until recordCount) { "index $index out of bounds [0, $recordCount)" }
        val pos = dataOffset + index * effectiveStride
        val buf = ByteArray(effectiveStride)
        map.position(pos); map.get(buf)
        val r = BinaryReader(buf)
        val wallNs = r.u64()
        val sample = TriposeSample.read(r)
        return wallNs to sample
    }

    fun sampleAt(index: Int): TriposeSample = recordAt(index).second
    fun wallClockNsAt(index: Int): Long = recordAt(index).first

    /** Read all records. Allocates linearly — use only on bounded files. */
    fun readAll(): List<Pair<Long, TriposeSample>> = (0 until recordCount).map { recordAt(it) }

    /** Binary-search by `sof_timestamp_ns` (matches the .vts clock). */
    fun indexAt(sofTimestampNs: Long): Int {
        if (recordCount == 0) return -1
        var lo = 0; var hi = recordCount - 1
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val midTs = sofAt(mid)
            if (midTs < sofTimestampNs) lo = mid + 1 else hi = mid
        }
        if (lo > 0 && kotlin.math.abs(sofAt(lo - 1) - sofTimestampNs) <
            kotlin.math.abs(sofAt(lo) - sofTimestampNs)) return lo - 1
        return lo
    }

    private fun sofAt(index: Int): Long {
        // sof_timestamp_ns lives at offset 4 within the packed payload
        // (after flags+state+pad), which itself starts at +8 within the record.
        val pos = dataOffset + index * effectiveStride + 8 + 4
        return map.getLong(pos)
    }

    override fun close() { raf.close() }
}
