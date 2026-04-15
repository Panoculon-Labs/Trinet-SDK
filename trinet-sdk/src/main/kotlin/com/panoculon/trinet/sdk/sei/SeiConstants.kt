package com.panoculon.trinet.sdk.sei

object SeiConstants {
    /** UUID prefixing every Trinet IMU SEI payload — see the Trinet SEI specification. */
    val TRIMU_UUID: ByteArray = byteArrayOf(
        0x54, 0x52, 0x49, 0x4E, 0x45, 0x54, 0x49, 0x4D,
        0x55, 0x53, 0x45, 0x49, 0x00, 0x01, 0x00, 0x00,
    )

    /** SEI payload type for user_data_unregistered (carries the TRIMU UUID + samples). */
    const val SEI_TYPE_USER_DATA_UNREGISTERED = 5

    /** UUID(16) + version(1) + num_samples(2) + accel_fs(2) + gyro_fs(2). */
    const val SEI_HEADER_SIZE = 16 + 1 + 2 + 2 + 2

    /** H.264 NAL unit type for SEI. */
    const val H264_NAL_TYPE_SEI = 6

    /** H.264 NAL unit types 1..5 are coded slices (frames). */
    fun isVclNalType(nalType: Int): Boolean = nalType in 1..5
}
