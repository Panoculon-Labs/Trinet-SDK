package com.panoculon.trinet.sdk.transport

import com.panoculon.trinet.sdk.session.FrameCallback

/**
 * JNI bridge to libuvc + libusb. All methods are static so the native side can
 * resolve them with a single GetStaticMethodID at JNI_OnLoad.
 *
 * Threading: native code dispatches frame callbacks on libuvc's stream thread;
 * the Kotlin handler must not block.
 */
internal object NativeBridge {

    init {
        // Load in dependency order so the dynamic linker has everything resolved
        // by the time trinet_native's JNI_OnLoad runs.
        System.loadLibrary("usb-1.0")
        System.loadLibrary("uvc")
        System.loadLibrary("trinet_native")
    }

    @Volatile private var sink: FrameCallback? = null
    @Volatile private var errorSink: ((String) -> Unit)? = null

    fun setSink(sink: FrameCallback?, errorSink: ((String) -> Unit)?) {
        this.sink = sink
        this.errorSink = errorSink
    }

    @JvmStatic external fun nativeVersion(): String
    @JvmStatic external fun nativeOpen(usbFd: Int): Long
    @JvmStatic external fun nativeStartStream(handle: Long, width: Int, height: Int, fps: Int): Boolean
    @JvmStatic external fun nativeStopStream(handle: Long)
    @JvmStatic external fun nativeClose(handle: Long)

    // Called from JNI on libuvc's stream thread.
    @JvmStatic
    @Suppress("unused")
    fun onFrameNative(buffer: ByteArray, ptsUs: Long) {
        sink?.onFrame(buffer, ptsUs)
    }

    @JvmStatic
    @Suppress("unused")
    fun onErrorNative(message: String) {
        errorSink?.invoke(message)
    }
}
