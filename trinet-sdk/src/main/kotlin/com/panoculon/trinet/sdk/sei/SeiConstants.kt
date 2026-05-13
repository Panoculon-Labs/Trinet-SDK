package com.panoculon.trinet.sdk.sei

object SeiConstants {
    /** UUID prefixing every Trinet IMU SEI payload — see the Trinet SEI specification. */
    val TRIMU_UUID: ByteArray = byteArrayOf(
        0x54, 0x52, 0x49, 0x4E, 0x45, 0x54, 0x49, 0x4D,
        0x55, 0x53, 0x45, 0x49, 0x00, 0x01, 0x00, 0x00,
    )

    /**
     * UUID prefixing every Trinet TRIPOSE SEI payload (6-DOF pose from on-device VIO).
     * ASCII "TRINETPOSE_v1" + three NUL bytes. Defined by the Trinet SEI specification.
     */
    val TRIPOSE_UUID: ByteArray = byteArrayOf(
        0x54, 0x52, 0x49, 0x4E, 0x45, 0x54, 0x50, 0x4F,
        0x53, 0x45, 0x5F, 0x76, 0x31, 0x00, 0x00, 0x00,
    )

    /** SEI payload type for user_data_unregistered (carries the TRIMU and TRIPOSE UUIDs). */
    const val SEI_TYPE_USER_DATA_UNREGISTERED = 5

    /** UUID(16) + version(1) + num_samples(2) + accel_fs(2) + gyro_fs(2). */
    const val SEI_HEADER_SIZE = 16 + 1 + 2 + 2 + 2

    /** UUID(16) + version(1) + pad(1). Followed by the 112-byte vio_pose_payload_t. */
    const val TRIPOSE_HEADER_SIZE = 16 + 1 + 1

    /** Wire version emitted by the firmware (must match `version` byte in the SEI). */
    const val TRIPOSE_VERSION: Int = 1

    /** H.264 NAL unit type for SEI. */
    const val H264_NAL_TYPE_SEI = 6

    /** H.264 NAL unit types 1..5 are coded slices (frames). */
    fun isVclNalType(nalType: Int): Boolean = nalType in 1..5
}
