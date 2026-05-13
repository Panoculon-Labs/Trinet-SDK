package com.panoculon.trinet.sdk.sei

import com.panoculon.trinet.sdk.io.BinaryWriter
import com.panoculon.trinet.sdk.model.ImuSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class SeiImuParserTest {

    private fun sample(ts: Long, seed: Float) = ImuSample(
        timestampNs = ts,
        accel = floatArrayOf(seed, seed + 0.1f, seed + 0.2f),
        gyro = floatArrayOf(seed + 1f, seed + 1.1f, seed + 1.2f),
        mag = floatArrayOf(seed + 2f, seed + 2.1f, seed + 2.2f),
        tempC = 25.0f + seed,
        quatXyzw = floatArrayOf(0f, 0f, 0f, 1f),
        linAccel = floatArrayOf(seed * 0.1f, seed * 0.2f, seed * 0.3f),
        fsyncDelayUs = 123.4f + seed,
    )

    /** Build a single SEI NAL with a TRIMU payload, wrapped in a 4-byte start code. */
    private fun buildSeiNal(samples: List<ImuSample>, accelFs: Int = 2, gyroFs: Int = 3): ByteArray {
        // Construct the SEI payload: UUID(16) + version(1) + num_samples(2) + accel_fs(2) + gyro_fs(2) + samples.
        val payloadW = BinaryWriter(SeiConstants.SEI_HEADER_SIZE + samples.size * ImuSample.SIZE_BYTES)
        payloadW.bytes(SeiConstants.TRIMU_UUID)
        payloadW.u8(3) // version
        payloadW.u16(samples.size)
        payloadW.u16(accelFs)
        payloadW.u16(gyroFs)
        for (s in samples) s.writeTo(payloadW)
        val payload = payloadW.toByteArray()

        // Build the SEI RBSP: type, size, payload, trailing bits. The whole RBSP
        // (excluding the NAL header byte) is then EPB-encoded so the bitstream
        // contains no spurious start codes — same shape an H.264 encoder emits.
        val rbsp = BinaryWriter(payload.size + 16)
        var pt = SeiConstants.SEI_TYPE_USER_DATA_UNREGISTERED
        while (pt >= 255) { rbsp.u8(0xFF); pt -= 255 }
        rbsp.u8(pt)
        var ps = payload.size
        while (ps >= 255) { rbsp.u8(0xFF); ps -= 255 }
        rbsp.u8(ps)
        rbsp.bytes(payload)
        rbsp.u8(0x80)
        val rbspBytes = rbsp.toByteArray()
        val ebsp = NalParser.addEmulationPrevention(rbspBytes)

        val framed = BinaryWriter(ebsp.size + 5)
        framed.u8(0); framed.u8(0); framed.u8(0); framed.u8(1)
        framed.u8(0x06) // NAL header: SEI
        framed.bytes(ebsp)
        return framed.toByteArray()
    }

    @Test fun roundTripSingleSeiNal() {
        val samples = listOf(sample(1_000_000_000L, 0f), sample(1_001_000_000L, 1f))
        val annexB = buildSeiNal(samples, accelFs = 2, gyroFs = 3)

        val payloads = SeiImuParser.parse(annexB)
        assertEquals(1, payloads.size)
        val p = payloads.single()
        assertEquals(3, p.header.version)
        assertEquals(samples.size, p.header.numSamples)
        assertEquals(2, p.header.accelFs)
        assertEquals(3, p.header.gyroFs)
        assertEquals(samples, p.samples)
    }

    @Test fun ignoresNonSeiNals() {
        // A bare SPS NAL (type 7) should not yield a payload.
        val annexB = byteArrayOf(0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1F)
        assertEquals(0, SeiImuParser.parse(annexB).size)
    }

    @Test fun handlesEmulationPreventionInPayload() {
        // Force a 00 00 00 sequence in the timestamp by choosing ts such that bytes
        // 0..2 are zero. timestamp_ns little-endian: pick 0x0000_0000_0000_FF00 — no zeros.
        // Use a value that yields an internal 00 00 03-style escape after we manually inject one.
        // Simpler: build the payload, then add an EPB into the stream and confirm parser still works.
        val samples = listOf(sample(0x1234_5678_9ABC_DEF0L, 0f))
        val payloadW = BinaryWriter()
        payloadW.bytes(SeiConstants.TRIMU_UUID)
        payloadW.u8(3); payloadW.u16(1); payloadW.u16(2); payloadW.u16(3)
        for (s in samples) s.writeTo(payloadW)
        val payload = payloadW.toByteArray()

        val seiMsg = BinaryWriter()
        seiMsg.u8(0x06)
        seiMsg.u8(SeiConstants.SEI_TYPE_USER_DATA_UNREGISTERED)
        seiMsg.u8(payload.size)
        seiMsg.bytes(payload)
        seiMsg.u8(0x80)
        val raw = seiMsg.toByteArray()

        // Inject an emulation prevention byte after the first 00 00 we find,
        // so that the decoder must strip it back out.
        val idx = (0 until raw.size - 2).first { raw[it] == 0.toByte() && raw[it + 1] == 0.toByte() }
        val withEpb = raw.copyOfRange(0, idx + 2) + byteArrayOf(0x03) + raw.copyOfRange(idx + 2, raw.size)

        val annexB = byteArrayOf(0, 0, 0, 1) + withEpb
        val payloads = SeiImuParser.parse(annexB)
        assertNotNull(payloads.firstOrNull())
        assertEquals(samples, payloads.single().samples)
    }
}
