package com.panoculon.trinet.sdk.device

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume

private const val TAG = "trinet.discovery"
private const val ACTION_USB_PERMISSION = "com.panoculon.trinet.sdk.USB_PERMISSION"

/** Helpers for finding and acquiring permission to a Trinet camera UVC device. */
object DeviceDiscovery {

    /** Enumerate currently connected Trinet-class USB devices. */
    fun connectedDevices(context: Context): List<UsbDevice> {
        val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        return manager.deviceList.values.filter { d ->
            d.vendorId == DeviceInfo.TRINET_VID && d.productId in DeviceInfo.TRINET_PIDS
        }
    }

    /**
     * Request runtime permission for [device]. Suspends until the user accepts
     * or rejects the system prompt. Returns true on grant.
     */
    suspend fun requestPermission(context: Context, device: UsbDevice): Boolean {
        val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        Log.i(TAG, "requestPermission(${device.deviceName} VID=${device.vendorId} PID=${device.productId})")
        Log.i(TAG, "  hasPermission=${manager.hasPermission(device)}")
        Log.i(TAG, "  total connected USB devices=${manager.deviceList.size}")
        if (manager.hasPermission(device)) return true

        return suspendCancellableCoroutine { cont ->
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(c: Context, intent: Intent) {
                    if (intent.action != ACTION_USB_PERMISSION) return
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val responseDevice = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
                    Log.i(TAG, "broadcast received: granted=$granted device=${responseDevice?.deviceName}")
                    runCatching { c.unregisterReceiver(this) }
                    if (cont.isActive) cont.resume(granted)
                }
            }
            val filter = IntentFilter(ACTION_USB_PERMISSION)
            if (Build.VERSION.SDK_INT >= 33) {
                // The system broadcasts the result on our behalf via the PendingIntent.
                // On API 33+ we must register as EXPORTED to receive that re-broadcast.
                context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                context.registerReceiver(receiver, filter)
            }
            val intentFlags =
                if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE
                else 0
            // setPackage targets our own app, making the intent explicit enough for
            // Android 14+'s implicit-intent + FLAG_MUTABLE security check.
            val pi = PendingIntent.getBroadcast(
                context, 0,
                Intent(ACTION_USB_PERMISSION).setPackage(context.packageName),
                intentFlags or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            Log.i(TAG, "calling UsbManager.requestPermission, awaiting broadcast…")
            manager.requestPermission(device, pi)
            cont.invokeOnCancellation { runCatching { context.unregisterReceiver(receiver) } }
        }
    }

    /** Convenience: open the first available Trinet camera device, prompting for permission if needed. */
    suspend fun openFirstAvailable(context: Context): TrinetDevice? {
        val device = connectedDevices(context).firstOrNull() ?: return null
        if (!requestPermission(context, device)) return null
        val manager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        return TrinetDevice(device, manager)
    }
}
