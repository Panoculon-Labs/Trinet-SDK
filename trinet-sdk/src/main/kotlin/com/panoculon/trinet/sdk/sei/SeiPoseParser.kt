package com.panoculon.trinet.sdk.sei

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.model.TriposeSample

/** Header preceding the pose body in each Trinet TRIPOSE SEI payload. */
data class SeiPoseHeader(val version: Int)

/** Decoded SEI TRIPOSE payload. */
data class SeiPosePayload(
    val header: SeiPoseHeader,
    val sample: TriposeSample,
)

/** Decode Trinet TRIPOSE SEI NAL units out of an H.264 Annex B bitstream. */
object SeiPoseParser {

    /** Return decoded TRIPOSE payloads from every TRIPOSE-SEI NAL in the bitstream. */
    fun parse(annexB: ByteArray, base: Int = 0, length: Int = annexB.size - base): List<SeiPosePayload> {
        val out = ArrayList<SeiPosePayload>()
        for (nal in NalParser.splitNalUnits(annexB, base, length)) {
            if (nal.h264Type != SeiConstants.H264_NAL_TYPE_SEI) continue
            decodeSei(nal.copy())?.let(out::add)
        }
        return out
    }

    /**
     * Decode the Trinet TRIPOSE payload from a single SEI NAL (with emulation
     * prevention still in the bitstream). Returns null if the NAL holds no
     * Trinet pose payload.
     */
    fun decodeSei(seiNal: ByteArray): SeiPosePayload? {
        val raw = NalParser.removeEmulationPrevention(seiNal)
        var pos = 1
        while (pos < raw.size - 1) {
            var payloadType = 0
            while (pos < raw.size && (raw[pos].toInt() and 0xFF) == 0xFF) {
                payloadType += 255; pos++
            }
            if (pos >= raw.size) return null
            payloadType += raw[pos].toInt() and 0xFF
            pos++

            var payloadSize = 0
            while (pos < raw.size && (raw[pos].toInt() and 0xFF) == 0xFF) {
                payloadSize += 255; pos++
            }
            if (pos >= raw.size) return null
            payloadSize += raw[pos].toInt() and 0xFF
            pos++

            if (pos + payloadSize > raw.size) return null

            if (payloadType == SeiConstants.SEI_TYPE_USER_DATA_UNREGISTERED &&
                payloadSize >= SeiConstants.TRIPOSE_HEADER_SIZE + TriposeSample.SIZE_BYTES
            ) {
                val payload = raw.copyOfRange(pos, pos + payloadSize)
                if (matchesTriposeUuid(payload)) {
                    return decodePayload(payload)
                }
            }
            pos += payloadSize
        }
        return null
    }

    private fun matchesTriposeUuid(payload: ByteArray): Boolean {
        val uuid = SeiConstants.TRIPOSE_UUID
        if (payload.size < uuid.size) return false
        for (i in uuid.indices) if (payload[i] != uuid[i]) return false
        return true
    }

    private fun decodePayload(payload: ByteArray): SeiPosePayload? {
        val r = BinaryReader(payload)
        r.skip(16) // UUID
        val version = r.u8()
        r.skip(1)  // pad
        if (r.remaining() < TriposeSample.SIZE_BYTES) return null
        val sample = TriposeSample.read(r)
        return SeiPosePayload(SeiPoseHeader(version), sample)
    }
}
