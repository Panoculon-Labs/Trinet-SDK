package com.panoculon.trinet.sdk.sei

/**
 * Annex B H.264 bitstream utilities: start-code scanning plus emulation-
 * prevention byte removal.
 */
object NalParser {

    /**
     * Split an Annex B byte stream into NAL unit payloads (start codes stripped,
     * trailing zero stuffing trimmed). Each returned slice begins with the NAL
     * header byte (e.g. NAL type bits in `byte & 0x1F` for H.264).
     */
    fun splitNalUnits(data: ByteArray, base: Int = 0, length: Int = data.size - base): List<NalSlice> {
        val end = base + length
        // Track each start code: (offsetOfStartCode, lengthOfStartCode). The NAL begins at offset+length.
        val codes = ArrayList<IntArray>()
        var i = base
        while (i + 2 < end) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (i + 3 < end && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                    codes.add(intArrayOf(i, 4)); i += 4; continue
                }
                if (data[i + 2] == 1.toByte()) {
                    codes.add(intArrayOf(i, 3)); i += 3; continue
                }
            }
            i++
        }

        val out = ArrayList<NalSlice>(codes.size)
        for (idx in codes.indices) {
            val s = codes[idx][0] + codes[idx][1]
            var e = if (idx + 1 < codes.size) codes[idx + 1][0] else end
            while (e > s && data[e - 1] == 0.toByte()) e--
            if (e > s) out.add(NalSlice(data, s, e - s))
        }
        return out
    }

    /**
     * Remove H.264/H.265 emulation prevention bytes: any sequence `00 00 03`
     * collapses to `00 00`. Returns a fresh byte array.
     */
    fun removeEmulationPrevention(data: ByteArray, base: Int = 0, length: Int = data.size - base): ByteArray {
        val out = ByteArray(length)
        var oi = 0
        var i = base
        val end = base + length
        while (i < end) {
            if (i + 2 < end && data[i] == 0.toByte() && data[i + 1] == 0.toByte() && data[i + 2] == 3.toByte()) {
                out[oi++] = 0
                out[oi++] = 0
                i += 3
            } else {
                out[oi++] = data[i]
                i++
            }
        }
        return if (oi == out.size) out else out.copyOf(oi)
    }

    /**
     * Apply H.264/H.265 emulation prevention encoding: insert `0x03` after any
     * `00 00` whose next byte is `<= 0x03` so the encoded stream contains no
     * accidental start codes. Inverse of [removeEmulationPrevention].
     */
    fun addEmulationPrevention(data: ByteArray, base: Int = 0, length: Int = data.size - base): ByteArray {
        val out = ArrayList<Byte>(length + length / 32)
        val end = base + length
        var i = base
        while (i < end) {
            val b = data[i]
            out.add(b)
            if (b == 0.toByte() && i + 1 < end && data[i + 1] == 0.toByte()) {
                out.add(0)
                if (i + 2 < end) {
                    val nxt = data[i + 2].toInt() and 0xFF
                    if (nxt <= 0x03) out.add(0x03)
                } else {
                    out.add(0x03)
                }
                i += 2
            } else {
                i += 1
            }
        }
        return ByteArray(out.size) { out[it] }
    }
}

/** Zero-copy view into an Annex B byte stream describing a single NAL unit. */
data class NalSlice(val source: ByteArray, val offset: Int, val length: Int) {
    /** First byte of the NAL unit (the NAL header). */
    val headerByte: Int get() = source[offset].toInt() and 0xFF

    /** H.264 nal_unit_type = forbidden_zero(1) + nal_ref_idc(2) + nal_unit_type(5). */
    val h264Type: Int get() = headerByte and 0x1F

    /** Slice the payload (everything after the NAL header byte). */
    fun payload(): ByteArray {
        val out = ByteArray(length - 1)
        System.arraycopy(source, offset + 1, out, 0, out.size)
        return out
    }

    /** Copy the full NAL (header + payload). */
    fun copy(): ByteArray = source.copyOfRange(offset, offset + length)
}
