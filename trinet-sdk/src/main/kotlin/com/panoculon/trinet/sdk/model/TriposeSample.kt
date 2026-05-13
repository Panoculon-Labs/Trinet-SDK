package com.panoculon.trinet.sdk.model

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.io.BinaryWriter

/**
 * 6-DOF pose sample emitted by the on-device VIO filter. One per camera frame
 * (UVC mode: embedded in a TRIPOSE SEI NAL; SD-card mode: appended to the
 * `.pose` sidecar). Mirrors firmware `vio_pose_payload_t` in
 * `project/app/trinet_vio/pose_ring.h` byte-for-byte.
 *
 * Wire layout (112 bytes, packed, little-endian):
 *   uint8       flags                  (bit0=INIT, bit1=DEGRADED, bit2=LOST, bit3=NPU_USED)
 *   uint8       filterState            (0=init, 1=tracking, 2=degraded, 3=lost)
 *   uint8[2]    pad
 *   uint64      sofTimestampNs         (camera Start-of-Frame, same clock as .vts)
 *   float32[3]  positionM              world frame, gravity-aligned Z up
 *   float32[4]  quatXyzw               world-from-body
 *   float32[3]  velocityMs
 *   float32[3]  gyroBias
 *   float32[3]  accelBias
 *   float32[3]  positionCovDiag        1-σ
 *   float32[3]  orientCovDiag          1-σ rad
 *   uint16      numTracked
 *   uint16      npuLatencyUs
 *   uint8[8]    reserved
 *
 * The world frame's X/Y heading is set at startup (no magnetometer) — only
 * relative orientation is meaningful, not absolute compass heading.
 */
data class TriposeSample(
    val flags: Int,
    val filterState: Int,
    val sofTimestampNs: Long,
    val positionM: FloatArray,
    val quatXyzw: FloatArray,
    val velocityMs: FloatArray,
    val gyroBias: FloatArray,
    val accelBias: FloatArray,
    val positionCovDiag: FloatArray,
    val orientCovDiag: FloatArray,
    val numTracked: Int,
    val npuLatencyUs: Int,
) {
    val isInitialized: Boolean get() = (flags and FLAG_INITIALIZED) != 0
    val isDegraded: Boolean   get() = (flags and FLAG_DEGRADED) != 0
    val isLost: Boolean       get() = (flags and FLAG_LOST) != 0

    companion object {
        const val SIZE_BYTES = 112

        const val FLAG_INITIALIZED = 0x01
        const val FLAG_DEGRADED    = 0x02
        const val FLAG_LOST        = 0x04
        const val FLAG_NPU_USED    = 0x08

        const val STATE_INIT      = 0
        const val STATE_TRACKING  = 1
        const val STATE_DEGRADED  = 2
        const val STATE_LOST      = 3

        fun read(reader: BinaryReader): TriposeSample {
            val flags = reader.u8()
            val state = reader.u8()
            reader.skip(2) // pad[2]
            val sofNs = reader.u64()
            val pos = reader.floatArray(3)
            val quat = reader.floatArray(4)
            val vel = reader.floatArray(3)
            val gyroB = reader.floatArray(3)
            val accelB = reader.floatArray(3)
            val posCov = reader.floatArray(3)
            val rotCov = reader.floatArray(3)
            val numTracked = reader.u16()
            val npuUs = reader.u16()
            reader.skip(8) // reserved
            return TriposeSample(
                flags = flags,
                filterState = state,
                sofTimestampNs = sofNs,
                positionM = pos,
                quatXyzw = quat,
                velocityMs = vel,
                gyroBias = gyroB,
                accelBias = accelB,
                positionCovDiag = posCov,
                orientCovDiag = rotCov,
                numTracked = numTracked,
                npuLatencyUs = npuUs,
            )
        }
    }

    fun writeTo(writer: BinaryWriter) {
        writer.u8(flags)
        writer.u8(filterState)
        writer.zeros(2)
        writer.u64(sofTimestampNs)
        positionM.forEach { writer.f32(it) }
        quatXyzw.forEach { writer.f32(it) }
        velocityMs.forEach { writer.f32(it) }
        gyroBias.forEach { writer.f32(it) }
        accelBias.forEach { writer.f32(it) }
        positionCovDiag.forEach { writer.f32(it) }
        orientCovDiag.forEach { writer.f32(it) }
        writer.u16(numTracked)
        writer.u16(npuLatencyUs)
        writer.zeros(8)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TriposeSample) return false
        return flags == other.flags &&
            filterState == other.filterState &&
            sofTimestampNs == other.sofTimestampNs &&
            positionM.contentEquals(other.positionM) &&
            quatXyzw.contentEquals(other.quatXyzw) &&
            velocityMs.contentEquals(other.velocityMs) &&
            gyroBias.contentEquals(other.gyroBias) &&
            accelBias.contentEquals(other.accelBias) &&
            positionCovDiag.contentEquals(other.positionCovDiag) &&
            orientCovDiag.contentEquals(other.orientCovDiag) &&
            numTracked == other.numTracked &&
            npuLatencyUs == other.npuLatencyUs
    }

    override fun hashCode(): Int {
        var r = flags
        r = 31 * r + filterState
        r = 31 * r + sofTimestampNs.hashCode()
        r = 31 * r + positionM.contentHashCode()
        r = 31 * r + quatXyzw.contentHashCode()
        r = 31 * r + velocityMs.contentHashCode()
        r = 31 * r + gyroBias.contentHashCode()
        r = 31 * r + accelBias.contentHashCode()
        r = 31 * r + positionCovDiag.contentHashCode()
        r = 31 * r + orientCovDiag.contentHashCode()
        r = 31 * r + numTracked
        r = 31 * r + npuLatencyUs
        return r
    }
}
