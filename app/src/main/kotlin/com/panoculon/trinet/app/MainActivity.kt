package com.panoculon.trinet.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import com.panoculon.trinet.app.ui.TrinetNavHost
import com.panoculon.trinet.app.ui.theme.TrinetTheme

class MainActivity : ComponentActivity() {

    private val usbAttachReceiver = UsbAttachReceiver { onUsbChange?.invoke() }
    private var onUsbChange: (() -> Unit)? = null

    private val cameraPermissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        // Triggers the device view model to retry now that CAMERA is granted.
        if (granted) onUsbChange?.invoke()
    }

    fun setOnUsbChange(handler: () -> Unit) { onUsbChange = handler }

    fun ensureCameraPermission(): Boolean {
        val granted = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        if (!granted) cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
        return granted
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // If the activity was launched by USB_DEVICE_ATTACHED, the system has already
        // granted us permission to the device — record it so the ViewModel skips the
        // permission prompt entirely.
        intent?.let { handleUsbAttachIntent(it) }
        setContent {
            TrinetTheme {
                TrinetNavHost()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleUsbAttachIntent(intent)
        if (intent.action == UsbManager.ACTION_USB_DEVICE_ATTACHED) onUsbChange?.invoke()
    }

    private fun handleUsbAttachIntent(intent: Intent) {
        if (intent.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
        val device: UsbDevice? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }
        if (device != null) AttachedDeviceCache.preGranted = device
    }

    override fun onStart() {
        super.onStart()
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(usbAttachReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(usbAttachReceiver, filter)
        }
    }

    override fun onStop() {
        runCatching { unregisterReceiver(usbAttachReceiver) }
        super.onStop()
    }
}
