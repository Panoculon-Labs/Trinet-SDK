package com.panoculon.trinet.app.viewmodel

import android.app.Application
import android.content.Context
import android.hardware.usb.UsbManager
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.panoculon.trinet.app.AttachedDeviceCache
import com.panoculon.trinet.sdk.device.DeviceDiscovery
import com.panoculon.trinet.sdk.device.DeviceInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface DeviceStatus {
    data object Disconnected : DeviceStatus
    data class Detected(val info: DeviceInfo) : DeviceStatus
    data class Granted(val info: DeviceInfo) : DeviceStatus
    data class Error(val message: String) : DeviceStatus
}

class DeviceViewModel(app: Application) : AndroidViewModel(app) {
    private val _status = MutableStateFlow<DeviceStatus>(DeviceStatus.Disconnected)
    val status: StateFlow<DeviceStatus> = _status.asStateFlow()

    @Volatile private var permissionInFlight = false
    @Volatile private var permissionDenied = false

    fun refresh(autoRequestPermission: Boolean = true) {
        val mgr = getApplication<Application>().getSystemService(Context.USB_SERVICE) as UsbManager

        // Prefer the device handed to us by USB_DEVICE_ATTACHED — those are pre-granted.
        val attached = AttachedDeviceCache.preGranted
        val device = attached ?: DeviceDiscovery.connectedDevices(getApplication()).firstOrNull()

        if (device == null) {
            _status.value = DeviceStatus.Disconnected
            permissionDenied = false
            return
        }
        val info = DeviceInfo(
            vendorId = device.vendorId,
            productId = device.productId,
            serial = runCatching { device.serialNumber }.getOrNull(),
            productName = device.productName,
            deviceName = device.deviceName,
        )
        when {
            mgr.hasPermission(device) -> {
                _status.value = DeviceStatus.Granted(info)
                permissionDenied = false
            }
            permissionDenied -> {
                _status.value = DeviceStatus.Error(
                    "Permission denied — another app may have claimed the device. " +
                        "Unplug it, open Trinet first, then plug it back in."
                )
            }
            else -> {
                _status.value = DeviceStatus.Detected(info)
                if (autoRequestPermission && !permissionInFlight) requestPermission()
            }
        }
    }

    fun requestPermission() {
        if (permissionInFlight) return
        val ctx = getApplication<Application>()
        val device = DeviceDiscovery.connectedDevices(ctx).firstOrNull() ?: return
        permissionInFlight = true
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val ok = DeviceDiscovery.requestPermission(ctx, device)
                if (ok) {
                    permissionDenied = false
                    refresh(autoRequestPermission = false)
                } else {
                    permissionDenied = true
                    _status.value = DeviceStatus.Error("USB permission denied — replug to retry")
                }
            } finally {
                permissionInFlight = false
            }
        }
    }
}
