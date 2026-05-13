package com.panoculon.trinet.sdk.recording

import com.panoculon.trinet.sdk.io.BinaryWriter
import com.panoculon.trinet.sdk.model.TriposeSample
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream

/**
 * Writes a TRPSF001 v1 pose sidecar in the same on-disk format the Trinet
 * camera produces when recording to SD card.
 *
 * File layout:
 *   header(32):
 *     magic[8]        "TRPSF001"
 *     version         uint32 = 1
 *     record_size     uint32 = 136  (header CLAIMS 136, but actual stride is 120)
 *     reserved[16]    zeros
 *   record(120 each):
 *     wall_clock_ns   uint64        (monotonic, set on append)
 *     pose_payload    112 bytes     (see [TriposeSample])
 *
 * Note the header record_size mismatch: firmware sets the field to 136 (legacy
 * 128-byte payload assumption) but the packed struct + 8-byte wall stamp adds
 * up to 120. Readers must override stride from the header value.
 */
class PoseFileWriter(
    private val file: File,
) : Closeable {

    companion object {
        val MAGIC = "TRPSF001".toByteArray(Charsets.US_ASCII)
        const val VERSION = 1
        /** Firmware-compatible value: claims 136 even though the real stride is 120. */
        const val HEADER_RECORD_SIZE_FIELD = 136
        const val RECORD_STRIDE_BYTES = 8 + TriposeSample.SIZE_BYTES // 120
        const val HEADER_SIZE = 32
    }

    private val out = BufferedOutputStream(FileOutputStream(file))
    private var headerWritten = false
    var recordCount: Long = 0L
        private set

    private fun writeHeader() {
        val w = BinaryWriter(HEADER_SIZE)
        w.bytes(MAGIC)                         // 0..7
        w.u32(VERSION.toLong())                // 8..11
        w.u32(HEADER_RECORD_SIZE_FIELD.toLong()) // 12..15
        w.zeros(HEADER_SIZE - 16)              // 16..31 reserved
        out.write(w.toByteArray())
        headerWritten = true
    }

    /**
     * Append one pose record. [wallClockNs] is what firmware writes — we accept
     * it from the caller so live-recording flows (which derive a wall stamp
     * from [System.nanoTime]) and replay flows stay consistent.
     */
    @Synchronized
    fun append(sample: TriposeSample, wallClockNs: Long = System.nanoTime()) {
        if (!headerWritten) writeHeader()
        val w = BinaryWriter(RECORD_STRIDE_BYTES)
        w.u64(wallClockNs)
        sample.writeTo(w)
        out.write(w.toByteArray())
        recordCount++
    }

    @Synchronized
    fun flush() {
        out.flush()
    }

    @Synchronized
    override fun close() {
        out.flush()
        out.close()
    }
}
