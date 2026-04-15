package com.panoculon.trinet.sdk

import com.panoculon.trinet.sdk.transport.NativeBridge

object TrinetSdk {
    const val VERSION = "0.1.0"

    /** Runtime version of the bundled libuvc/libusb JNI shim. */
    fun nativeVersion(): String = NativeBridge.nativeVersion()
}
