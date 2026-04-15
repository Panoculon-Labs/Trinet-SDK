package com.panoculon.trinet.sdk.io

import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Little-endian primitive writer to a byte buffer or stream. */
class BinaryWriter(initialCapacity: Int = 64) {
    private var buf: ByteBuffer = ByteBuffer.allocate(initialCapacity).order(ByteOrder.LITTLE_ENDIAN)

    fun position(): Int = buf.position()

    private fun ensure(extra: Int) {
        if (buf.remaining() >= extra) return
        val next = ByteBuffer.allocate(maxOf(buf.capacity() * 2, buf.position() + extra))
            .order(ByteOrder.LITTLE_ENDIAN)
        buf.flip()
        next.put(buf)
        buf = next
    }

    fun u8(v: Int) { ensure(1); buf.put((v and 0xFF).toByte()) }
    fun u16(v: Int) { ensure(2); buf.putShort((v and 0xFFFF).toShort()) }
    fun u32(v: Long) { ensure(4); buf.putInt((v and 0xFFFFFFFFL).toInt()) }
    fun i32(v: Int) { ensure(4); buf.putInt(v) }
    fun u64(v: Long) { ensure(8); buf.putLong(v) }
    fun f32(v: Float) { ensure(4); buf.putFloat(v) }
    fun bytes(b: ByteArray) { ensure(b.size); buf.put(b) }
    fun zeros(n: Int) { ensure(n); for (i in 0 until n) buf.put(0) }

    fun toByteArray(): ByteArray {
        val out = ByteArray(buf.position())
        System.arraycopy(buf.array(), 0, out, 0, out.size)
        return out
    }

    fun writeTo(out: OutputStream) {
        out.write(buf.array(), 0, buf.position())
    }
}
