package com.panoculon.trinet.sdk.device

import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import com.panoculon.trinet.sdk.session.SessionConfig
import com.panoculon.trinet.sdk.session.TrinetSession
import com.panoculon.trinet.sdk.transport.NativeBridge
import java.io.Closeable

/**
 * Owns a granted USB connection to a Trinet camera. Hand the [usbDevice] you got
 * from [DeviceDiscovery] (after the user granted permission) and call [open] to
 * obtain a streaming [TrinetSession].
 */
class TrinetDevice(
    val usbDevice: UsbDevice,
    private val usbManager: UsbManager,
) : Closeable {

    val info: DeviceInfo = DeviceInfo(
        vendorId = usbDevice.vendorId,
        productId = usbDevice.productId,
        serial = runCatching { usbDevice.serialNumber }.getOrNull(),
        productName = usbDevice.productName,
        deviceName = usbDevice.deviceName,
    )

    private var connection: UsbDeviceConnection? = null
    private var nativeHandle: Long = 0L

    /** Open the USB device and initialize libuvc. Must be called on a worker thread. */
    fun open(config: SessionConfig = SessionConfig()): TrinetSession {
        require(usbManager.hasPermission(usbDevice)) {
            "USB permission not granted for ${usbDevice.deviceName}"
        }
        val conn = usbManager.openDevice(usbDevice)
            ?: error("openDevice returned null for ${usbDevice.deviceName}")
        connection = conn

        // Claim the first UVC interface so libusb can issue control transfers.
        for (i in 0 until usbDevice.interfaceCount) {
            conn.claimInterface(usbDevice.getInterface(i), /* force = */ true)
        }
        val handle = NativeBridge.nativeOpen(conn.fileDescriptor)
        if (handle == 0L) {
            conn.close()
            connection = null
            error("native open failed (libuvc/libusb)")
        }
        nativeHandle = handle
        return TrinetSession(handle, config)
    }

    override fun close() {
        if (nativeHandle != 0L) {
            NativeBridge.nativeClose(nativeHandle)
            nativeHandle = 0L
        }
        connection?.close()
        connection = null
    }
}
