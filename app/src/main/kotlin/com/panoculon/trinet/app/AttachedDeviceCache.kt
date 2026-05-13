package com.panoculon.trinet.app

import android.hardware.usb.UsbDevice

/**
 * Stash for a UsbDevice handed to MainActivity by Android's USB_DEVICE_ATTACHED
 * intent. Activities launched via that intent are already permission-granted for
 * the device, so we skip [DeviceDiscovery.requestPermission] entirely.
 *
 * Cleared by the consumer once it has taken ownership.
 */
object AttachedDeviceCache {
    @Volatile var preGranted: UsbDevice? = null
}
