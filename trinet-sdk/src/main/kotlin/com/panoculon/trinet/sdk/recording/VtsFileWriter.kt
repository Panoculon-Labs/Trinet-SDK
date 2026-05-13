package com.panoculon.trinet.sdk.recording

import com.panoculon.trinet.sdk.io.BinaryWriter
import com.panoculon.trinet.sdk.model.VtsEntry
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.File
import java.io.FileOutputStream

/**
 * Writes a TRIVTS01 v2 sidecar file. Layout matches `the reference format spec:74-81`:
 *   header(32): magic[8] "TRIVTS01", version=2, frame_rate_milli, reserved[16].
 *   entries(24 each): frame_number(u32), sof_ts_ns(u64), venc_seq(u32), venc_pts_us(u64).
 */
class VtsFileWriter(
    private val file: File,
    fps: Float,
) : Closeable {

    companion object {
        val MAGIC = "TRIVTS01".toByteArray(Charsets.US_ASCII)
        const val VERSION = 2
        const val HEADER_SIZE = 32
    }

    private val frameRateMilli: Int = (fps * 1000f).toInt()
    private val out = BufferedOutputStream(FileOutputStream(file))
    var entryCount: Long = 0L
        private set

    init {
        writeHeader()
    }

    private fun writeHeader() {
        val w = BinaryWriter(HEADER_SIZE)
        w.bytes(MAGIC)
        w.u32(VERSION.toLong())
        w.u32(frameRateMilli.toLong())
        w.zeros(HEADER_SIZE - w.position())
        out.write(w.toByteArray())
    }

    @Synchronized
    fun append(entry: VtsEntry) {
        val w = BinaryWriter(VtsEntry.SIZE_BYTES)
        entry.writeTo(w)
        out.write(w.toByteArray())
        entryCount++
    }

    @Synchronized
    fun flush() { out.flush() }

    @Synchronized
    override fun close() {
        out.flush()
        out.close()
    }
}
