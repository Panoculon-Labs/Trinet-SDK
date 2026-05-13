package com.panoculon.trinet.sdk.device

/** Identity + capabilities of a connected (but not necessarily opened) Trinet device. */
data class DeviceInfo(
    val vendorId: Int,
    val productId: Int,
    val serial: String?,
    val productName: String?,
    val deviceName: String,
) {
    val isTrinet: Boolean get() = vendorId == TRINET_VID && productId in TRINET_PIDS

    companion object {
        const val TRINET_VID = 0x2207
        val TRINET_PIDS = setOf(0x0016, 0x0018, 0x001A)
    }
}
