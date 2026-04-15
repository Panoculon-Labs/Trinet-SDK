package com.panoculon.trinet.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbManager

/**
 * Listens for USB attach/detach events while the activity is foregrounded so the
 * UI can react instantly without polling.
 */
class UsbAttachReceiver(private val onChange: () -> Unit) : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            UsbManager.ACTION_USB_DEVICE_ATTACHED,
            UsbManager.ACTION_USB_DEVICE_DETACHED -> onChange()
        }
    }
}
