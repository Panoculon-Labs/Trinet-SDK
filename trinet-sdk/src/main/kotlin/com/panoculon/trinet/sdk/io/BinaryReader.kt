package com.panoculon.trinet.sdk.io

import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Little-endian primitive accessors over a byte array. */
class BinaryReader(val data: ByteArray, val base: Int = 0, val length: Int = data.size - base) {
    private val buf: ByteBuffer = ByteBuffer.wrap(data, base, length).order(ByteOrder.LITTLE_ENDIAN)

    fun position(): Int = buf.position() - base
    fun remaining(): Int = buf.remaining()
    fun seek(offset: Int) { buf.position(base + offset) }
    fun skip(n: Int) { buf.position(buf.position() + n) }

    fun u8(): Int = buf.get().toInt() and 0xFF
    fun u16(): Int = buf.short.toInt() and 0xFFFF
    fun u32(): Long = buf.int.toLong() and 0xFFFFFFFFL
    fun i32(): Int = buf.int
    fun u64(): Long = buf.long
    fun f32(): Float = buf.float

    fun bytes(n: Int): ByteArray {
        val out = ByteArray(n)
        buf.get(out)
        return out
    }

    fun floatArray(n: Int): FloatArray {
        val out = FloatArray(n)
        for (i in 0 until n) out[i] = buf.float
        return out
    }
}
