package com.panoculon.trinet.sdk.recording

import com.panoculon.trinet.sdk.io.BinaryWriter
import com.panoculon.trinet.sdk.model.ImuSample
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream

/**
 * Writes a TRIMU001 v3 sidecar file. Layout matches `the reference format spec:58-72`:
 *   header(64): magic[8] "TRIMU001", version=3, sample_rate_hz, accel_fs, gyro_fs,
 *               start_time_ns, video_start_ns, flags, reserved[24].
 *   samples(80 each): see [ImuSample].
 */
class ImuFileWriter(
    private val file: File,
    private val sampleRateHz: Int,
    private val accelFs: Int,
    private val gyroFs: Int,
    flagsFsync: Boolean = true,
    private val batchSize: Int = 64,
) : Closeable {

    companion object {
        val MAGIC = "TRIMU001".toByteArray(Charsets.US_ASCII)
        const val VERSION = 3
        const val HEADER_SIZE = 64
        const val FLAG_FSYNC = 0x01
    }

    private val flags: Int = if (flagsFsync) FLAG_FSYNC else 0
    private val batch = ArrayList<ImuSample>(batchSize)
    private val out = BufferedOutputStream(FileOutputStream(file))
    private var headerWritten = false
    var sampleCount: Long = 0L
        private set

    private fun writeHeader(startTimeNs: Long) {
        val w = BinaryWriter(HEADER_SIZE)
        w.bytes(MAGIC)                 // 0..7
        w.u32(VERSION.toLong())        // 8..11
        w.u32(sampleRateHz.toLong())   // 12..15
        w.u16(accelFs)                 // 16..17
        w.u16(gyroFs)                  // 18..19
        w.u64(startTimeNs)             // 20..27
        w.u64(0L)                      // 28..35  video_start_ns (filled with 0; reader infers)
        w.u32(flags.toLong())          // 36..39
        w.zeros(HEADER_SIZE - w.position())  // 24-byte tail of reserved
        out.write(w.toByteArray())
    }

    /** Append one sample. The first call writes the header using its timestamp. */
    @Synchronized
    fun append(sample: ImuSample) {
        if (!headerWritten) {
            writeHeader(sample.timestampNs)
            headerWritten = true
        }
        batch.add(sample)
        sampleCount++
        if (batch.size >= batchSize) flushBatch()
    }

    @Synchronized
    fun flush() {
        flushBatch()
        out.flush()
    }

    private fun flushBatch() {
        if (batch.isEmpty()) return
        val w = BinaryWriter(batch.size * ImuSample.SIZE_BYTES)
        for (s in batch) s.writeTo(w)
        out.write(w.toByteArray())
        batch.clear()
    }

    @Synchronized
    override fun close() {
        flushBatch()
        out.flush()
        out.close()
    }
}
