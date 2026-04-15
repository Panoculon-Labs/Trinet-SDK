package com.panoculon.trinet.sdk.sei

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.model.ImuSample

/** Header preceding samples in each Trinet IMU SEI payload. */
data class SeiImuHeader(
    val version: Int,
    val numSamples: Int,
    val accelFs: Int,
    val gyroFs: Int,
)

/** Decoded SEI IMU payload. */
data class SeiImuPayload(
    val header: SeiImuHeader,
    val samples: List<ImuSample>,
)

/** Decode Trinet IMU SEI NAL units out of an H.264 Annex B bitstream. */
object SeiImuParser {

    /** Return decoded IMU payloads from every Trinet-SEI NAL in the bitstream. */
    fun parse(annexB: ByteArray, base: Int = 0, length: Int = annexB.size - base): List<SeiImuPayload> {
        val out = ArrayList<SeiImuPayload>()
        for (nal in NalParser.splitNalUnits(annexB, base, length)) {
            if (nal.h264Type != SeiConstants.H264_NAL_TYPE_SEI) continue
            decodeSei(nal.copy())?.let(out::add)
        }
        return out
    }

    /**
     * Decode the Trinet IMU payload from a single SEI NAL (with emulation prevention
     * still in the bitstream). Returns null if the NAL holds no Trinet payload.
     */
    fun decodeSei(seiNal: ByteArray): SeiImuPayload? {
        val raw = NalParser.removeEmulationPrevention(seiNal)
        // raw[0] is the NAL header; SEI messages start at raw[1].
        var pos = 1
        while (pos < raw.size - 1) {
            // payload_type (cumulative 0xFF)
            var payloadType = 0
            while (pos < raw.size && (raw[pos].toInt() and 0xFF) == 0xFF) {
                payloadType += 255; pos++
            }
            if (pos >= raw.size) return null
            payloadType += raw[pos].toInt() and 0xFF
            pos++

            // payload_size (cumulative 0xFF)
            var payloadSize = 0
            while (pos < raw.size && (raw[pos].toInt() and 0xFF) == 0xFF) {
                payloadSize += 255; pos++
            }
            if (pos >= raw.size) return null
            payloadSize += raw[pos].toInt() and 0xFF
            pos++

            if (pos + payloadSize > raw.size) return null

            if (payloadType == SeiConstants.SEI_TYPE_USER_DATA_UNREGISTERED &&
                payloadSize >= SeiConstants.SEI_HEADER_SIZE
            ) {
                val payload = raw.copyOfRange(pos, pos + payloadSize)
                if (matchesTrimuUuid(payload)) {
                    return decodePayload(payload)
                }
            }
            pos += payloadSize
        }
        return null
    }

    private fun matchesTrimuUuid(payload: ByteArray): Boolean {
        val uuid = SeiConstants.TRIMU_UUID
        if (payload.size < uuid.size) return false
        for (i in uuid.indices) if (payload[i] != uuid[i]) return false
        return true
    }

    private fun decodePayload(payload: ByteArray): SeiImuPayload {
        val r = BinaryReader(payload)
        r.skip(16) // UUID
        val version = r.u8()
        val numSamples = r.u16()
        val accelFs = r.u16()
        val gyroFs = r.u16()
        val header = SeiImuHeader(version, numSamples, accelFs, gyroFs)

        val samples = ArrayList<ImuSample>(numSamples)
        val sampleBase = SeiConstants.SEI_HEADER_SIZE
        var i = 0
        while (i < numSamples && sampleBase + (i + 1) * ImuSample.SIZE_BYTES <= payload.size) {
            val sub = BinaryReader(payload, sampleBase + i * ImuSample.SIZE_BYTES, ImuSample.SIZE_BYTES)
            samples.add(ImuSample.read(sub))
            i++
        }
        return SeiImuPayload(header, samples)
    }
}
