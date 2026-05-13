package com.panoculon.trinet.sdk.playback

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.model.VtsEntry
import com.panoculon.trinet.sdk.recording.VtsFileWriter
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel

/** Reader for TRIVTS01 v2 frame-timestamp sidecars. */
class VtsFileReader(file: File) : AutoCloseable {

    val version: Int
    val frameRateMilli: Int
    val entryCount: Int
    val fps: Float get() = frameRateMilli / 1000f

    private val raf = RandomAccessFile(file, "r")
    private val map: MappedByteBuffer
    private val entrySize: Int

    init {
        require(file.length() >= VtsFileWriter.HEADER_SIZE) { "vts file too short" }
        map = raf.channel.map(FileChannel.MapMode.READ_ONLY, 0, file.length())
            .also { it.order(ByteOrder.LITTLE_ENDIAN) }
        val header = ByteArray(VtsFileWriter.HEADER_SIZE)
        map.position(0); map.get(header)
        val r = BinaryReader(header)
        val magic = r.bytes(8)
        require(magic.contentEquals(VtsFileWriter.MAGIC)) { "bad vts magic" }
        version = r.u32().toInt()
        frameRateMilli = r.u32().toInt()
        entrySize = if (version >= 2) VtsEntry.SIZE_BYTES else 12
        val payload = file.length().toInt() - VtsFileWriter.HEADER_SIZE
        entryCount = payload / entrySize
    }

    fun entryAt(index: Int): VtsEntry {
        require(index in 0 until entryCount)
        val pos = VtsFileWriter.HEADER_SIZE + index * entrySize
        val buf = ByteArray(entrySize)
        map.position(pos); map.get(buf)
        val r = BinaryReader(buf)
        return if (version >= 2) {
            VtsEntry.read(r)
        } else {
            // v1: frame_number(u32), timestamp_ns(u64) — promote into v2 shape.
            val fn = r.u32()
            val ts = r.u64()
            VtsEntry(fn, ts, fn, ts / 1000)
        }
    }

    fun readAll(): List<VtsEntry> = (0 until entryCount).map { entryAt(it) }

    override fun close() { raf.close() }
}
