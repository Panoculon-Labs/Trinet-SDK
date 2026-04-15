package com.panoculon.trinet.sdk.model

import com.panoculon.trinet.sdk.io.BinaryReader
import com.panoculon.trinet.sdk.io.BinaryWriter

/**
 * v3 IMU sample as emitted by a Trinet device. Each video frame's SEI NAL
 * carries one or more of these, and they are also the on-disk layout in the
 * `imu.bin` sidecar.
 *
 * Wire layout (80 bytes, little-endian):
 *   uint64 timestamp_ns
 *   float32[3] accel  (m/s^2, includes gravity)
 *   float32[3] gyro   (rad/s)
 *   float32[3] mag    (uT)
 *   float32    temp_c
 *   float32[4] quat_xyzw (reserved; compute orientation with [Madgwick] instead)
 *   float32[3] lin_accel (reserved)
 *   float32    fsync_delay_us
 */
data class ImuSample(
    val timestampNs: Long,
    val accel: FloatArray,
    val gyro: FloatArray,
    val mag: FloatArray,
    val tempC: Float,
    val quatXyzw: FloatArray,
    val linAccel: FloatArray,
    val fsyncDelayUs: Float,
) {
    companion object {
        const val SIZE_BYTES = 80

        fun read(reader: BinaryReader): ImuSample = ImuSample(
            timestampNs = reader.u64(),
            accel = reader.floatArray(3),
            gyro = reader.floatArray(3),
            mag = reader.floatArray(3),
            tempC = reader.f32(),
            quatXyzw = reader.floatArray(4),
            linAccel = reader.floatArray(3),
            fsyncDelayUs = reader.f32(),
        )
    }

    fun writeTo(writer: BinaryWriter) {
        writer.u64(timestampNs)
        accel.forEach { writer.f32(it) }
        gyro.forEach { writer.f32(it) }
        mag.forEach { writer.f32(it) }
        writer.f32(tempC)
        quatXyzw.forEach { writer.f32(it) }
        linAccel.forEach { writer.f32(it) }
        writer.f32(fsyncDelayUs)
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is ImuSample) return false
        return timestampNs == other.timestampNs &&
            accel.contentEquals(other.accel) &&
            gyro.contentEquals(other.gyro) &&
            mag.contentEquals(other.mag) &&
            tempC == other.tempC &&
            quatXyzw.contentEquals(other.quatXyzw) &&
            linAccel.contentEquals(other.linAccel) &&
            fsyncDelayUs == other.fsyncDelayUs
    }

    override fun hashCode(): Int {
        var r = timestampNs.hashCode()
        r = 31 * r + accel.contentHashCode()
        r = 31 * r + gyro.contentHashCode()
        r = 31 * r + mag.contentHashCode()
        r = 31 * r + tempC.hashCode()
        r = 31 * r + quatXyzw.contentHashCode()
        r = 31 * r + linAccel.contentHashCode()
        r = 31 * r + fsyncDelayUs.hashCode()
        return r
    }
}
