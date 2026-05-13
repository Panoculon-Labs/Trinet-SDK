package com.panoculon.trinet.sdk.io

import com.panoculon.trinet.sdk.model.ImuSample
import com.panoculon.trinet.sdk.model.VtsEntry
import org.junit.Assert.assertEquals
import org.junit.Test

class BinaryRoundTripTest {

    @Test fun imuSampleRoundTripsEightyBytes() {
        val s = ImuSample(
            timestampNs = 1_700_000_000_000_000_000L,
            accel = floatArrayOf(0.01f, -9.81f, 0.02f),
            gyro = floatArrayOf(0.001f, 0.002f, -0.003f),
            mag = floatArrayOf(40.5f, -12.3f, 5.7f),
            tempC = 31.25f,
            quatXyzw = floatArrayOf(0.0f, 0.0f, 0.7071f, 0.7071f),
            linAccel = floatArrayOf(0.0f, 0.0f, 0.05f),
            fsyncDelayUs = 412.7f,
        )
        val w = BinaryWriter(ImuSample.SIZE_BYTES)
        s.writeTo(w)
        val bytes = w.toByteArray()
        assertEquals(ImuSample.SIZE_BYTES, bytes.size)

        val r = BinaryReader(bytes)
        val decoded = ImuSample.read(r)
        assertEquals(s, decoded)
    }

    @Test fun vtsEntryRoundTripsTwentyFourBytes() {
        val e = VtsEntry(frameNumber = 42L, sofTimestampNs = 1_001_002_003_004L, vencSeq = 42L, vencPtsUs = 1_001_002L)
        val w = BinaryWriter(VtsEntry.SIZE_BYTES)
        e.writeTo(w)
        val bytes = w.toByteArray()
        assertEquals(VtsEntry.SIZE_BYTES, bytes.size)

        val r = BinaryReader(bytes)
        assertEquals(e, VtsEntry.read(r))
    }

    @Test fun binaryWriterIsLittleEndian() {
        val w = BinaryWriter()
        w.u32(0x12345678L)
        val b = w.toByteArray()
        // LE: 78 56 34 12
        assertEquals(0x78, b[0].toInt() and 0xFF)
        assertEquals(0x56, b[1].toInt() and 0xFF)
        assertEquals(0x34, b[2].toInt() and 0xFF)
        assertEquals(0x12, b[3].toInt() and 0xFF)
    }
}
