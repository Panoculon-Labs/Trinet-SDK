package com.panoculon.trinet.sdk.sei

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test

class NalParserTest {

    @Test fun splitsThreeAndFourByteStartCodes() {
        // 4-byte 00 00 00 01 then a NAL [0x09, 0xF0]
        // 3-byte 00 00 01 then a NAL [0x67, 0x42]
        val data = byteArrayOf(
            0, 0, 0, 1, 0x09, 0xF0.toByte(),
            0, 0, 1, 0x67, 0x42,
        )
        val nals = NalParser.splitNalUnits(data)
        assertEquals(2, nals.size)
        assertArrayEquals(byteArrayOf(0x09, 0xF0.toByte()), nals[0].copy())
        assertArrayEquals(byteArrayOf(0x67, 0x42), nals[1].copy())
    }

    @Test fun trimsTrailingZeroStuffing() {
        val data = byteArrayOf(
            0, 0, 0, 1, 0x09, 0xF0.toByte(), 0, 0,
            0, 0, 0, 1, 0x67, 0x42,
        )
        val nals = NalParser.splitNalUnits(data)
        assertEquals(2, nals.size)
        // First NAL trailing zeros must be trimmed before the next start code.
        assertArrayEquals(byteArrayOf(0x09, 0xF0.toByte()), nals[0].copy())
    }

    @Test fun removesEmulationPreventionBytes() {
        val input = byteArrayOf(0x06, 0, 0, 3, 0, 0, 3, 0xFF.toByte())
        val expected = byteArrayOf(0x06, 0, 0, 0, 0, 0xFF.toByte())
        assertArrayEquals(expected, NalParser.removeEmulationPrevention(input))
    }

    @Test fun nalHeaderTypeBits() {
        // H.264 NAL byte: 0x67 = 0110_0111 -> nal_unit_type = 0x07 (SPS)
        val data = byteArrayOf(0, 0, 0, 1, 0x67, 0x42)
        val nal = NalParser.splitNalUnits(data).single()
        assertEquals(7, nal.h264Type)
    }
}
