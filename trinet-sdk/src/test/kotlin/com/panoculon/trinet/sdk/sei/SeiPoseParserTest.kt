package com.panoculon.trinet.sdk.sei

import com.panoculon.trinet.sdk.io.BinaryWriter
import com.panoculon.trinet.sdk.model.TriposeSample
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class SeiPoseParserTest {

    private fun sample(seed: Float = 0f, ts: Long = 1_234_000_000L) = TriposeSample(
        flags = TriposeSample.FLAG_INITIALIZED,
        filterState = TriposeSample.STATE_TRACKING,
        sofTimestampNs = ts,
        positionM = floatArrayOf(seed, seed + 0.1f, seed + 0.2f),
        quatXyzw = floatArrayOf(0f, 0f, 0f, 1f),
        velocityMs = floatArrayOf(seed + 1f, seed + 1.1f, seed + 1.2f),
        gyroBias = floatArrayOf(seed * 0.01f, seed * 0.02f, seed * 0.03f),
        accelBias = floatArrayOf(seed * 0.04f, seed * 0.05f, seed * 0.06f),
        positionCovDiag = floatArrayOf(0.05f, 0.05f, 0.06f),
        orientCovDiag = floatArrayOf(0.01f, 0.01f, 0.02f),
        numTracked = 42,
        npuLatencyUs = 12345,
    )

    /** Build a single SEI NAL containing a TRIPOSE payload (matches firmware UVC injector). */
    private fun buildSeiNal(s: TriposeSample): ByteArray {
        val payloadW = BinaryWriter(SeiConstants.TRIPOSE_HEADER_SIZE + TriposeSample.SIZE_BYTES)
        payloadW.bytes(SeiConstants.TRIPOSE_UUID)
        payloadW.u8(SeiConstants.TRIPOSE_VERSION) // version
        payloadW.u8(0)                            // pad
        s.writeTo(payloadW)
        val payload = payloadW.toByteArray()

        val rbsp = BinaryWriter(payload.size + 16)
        var pt = SeiConstants.SEI_TYPE_USER_DATA_UNREGISTERED
        while (pt >= 255) { rbsp.u8(0xFF); pt -= 255 }
        rbsp.u8(pt)
        var ps = payload.size
        while (ps >= 255) { rbsp.u8(0xFF); ps -= 255 }
        rbsp.u8(ps)
        rbsp.bytes(payload)
        rbsp.u8(0x80)
        val ebsp = NalParser.addEmulationPrevention(rbsp.toByteArray())

        val framed = BinaryWriter(ebsp.size + 5)
        framed.u8(0); framed.u8(0); framed.u8(0); framed.u8(1)
        framed.u8(0x06) // SEI NAL header
        framed.bytes(ebsp)
        return framed.toByteArray()
    }

    @Test fun roundTripSinglePoseSei() {
        val s = sample(seed = 0.5f)
        val annexB = buildSeiNal(s)

        val payloads = SeiPoseParser.parse(annexB)
        assertEquals(1, payloads.size)
        val p = payloads.single()
        assertEquals(SeiConstants.TRIPOSE_VERSION, p.header.version)
        assertEquals(s, p.sample)
    }

    @Test fun ignoresNonPoseSei() {
        // Build a "bare SEI" with a different UUID — parser must skip it.
        val payloadW = BinaryWriter()
        // Use IMU UUID to ensure the pose parser doesn't pick it up.
        payloadW.bytes(SeiConstants.TRIMU_UUID)
        payloadW.zeros(64)
        val payload = payloadW.toByteArray()

        val rbsp = BinaryWriter()
        rbsp.u8(SeiConstants.SEI_TYPE_USER_DATA_UNREGISTERED)
        rbsp.u8(payload.size)
        rbsp.bytes(payload)
        rbsp.u8(0x80)
        val ebsp = NalParser.addEmulationPrevention(rbsp.toByteArray())

        val framed = BinaryWriter()
        framed.u8(0); framed.u8(0); framed.u8(0); framed.u8(1); framed.u8(0x06)
        framed.bytes(ebsp)
        assertEquals(0, SeiPoseParser.parse(framed.toByteArray()).size)
    }

    @Test fun handlesEmulationPreventionInPosePayload() {
        val s = sample(seed = 0f, ts = 0x0000_0001_2345_6789L)
        val annexB = buildSeiNal(s)
        // The framing helper already invokes addEmulationPrevention, so this
        // test confirms the round-trip when EPB bytes happen to land inside
        // the pose payload's float fields.
        val payloads = SeiPoseParser.parse(annexB)
        assertNotNull(payloads.firstOrNull())
        assertEquals(s, payloads.single().sample)
    }
}
