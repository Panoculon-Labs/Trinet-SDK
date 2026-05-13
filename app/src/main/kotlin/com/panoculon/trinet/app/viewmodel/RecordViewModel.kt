package com.panoculon.trinet.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.panoculon.trinet.app.data.AppPaths
import com.panoculon.trinet.sdk.device.DeviceDiscovery
import com.panoculon.trinet.sdk.device.TrinetDevice
import com.panoculon.trinet.sdk.recording.RecordingHandle
import com.panoculon.trinet.sdk.recording.RecordingState
import com.panoculon.trinet.sdk.recording.TrinetRecorder
import com.panoculon.trinet.sdk.session.SessionConfig
import com.panoculon.trinet.sdk.session.TrinetSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

sealed interface RecordUiState {
    data object Idle : RecordUiState
    data object Connecting : RecordUiState
    data class Streaming(val sampleRateHz: Int) : RecordUiState
    data class Recording(val frameCount: Long, val sampleCount: Long, val durationMs: Long) : RecordUiState
    data class Error(val message: String) : RecordUiState
}

class RecordViewModel(app: Application) : AndroidViewModel(app) {

    private val config = SessionConfig(width = 1920, height = 1080, fps = 30)
    private val sampleRateHz = 562

    private var device: TrinetDevice? = null
    private var session: TrinetSession? = null
    private var recorder: TrinetRecorder? = null
    private var handle: RecordingHandle? = null
    private var recordingFrameJob: kotlinx.coroutines.Job? = null

    val sessionConfig: SessionConfig = config

    val activeSession: TrinetSession?
        get() = session

    private val _ui = MutableStateFlow<RecordUiState>(RecordUiState.Idle)
    val ui: StateFlow<RecordUiState> = _ui.asStateFlow()

    fun connect() {
        if (_ui.value !is RecordUiState.Idle && _ui.value !is RecordUiState.Error) return
        _ui.value = RecordUiState.Connecting
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val ctx = getApplication<Application>()
                val dev = DeviceDiscovery.openFirstAvailable(ctx)
                    ?: throw IllegalStateException("no Trinet camera device found")
                device = dev
                val sess = dev.open(config)
                session = sess
                if (!sess.start()) throw IllegalStateException("libuvc rejected stream config")

                recorder = TrinetRecorder(
                    rootDir = AppPaths.recordingsDir(ctx),
                    width = config.width,
                    height = config.height,
                    fps = config.fps,
                    sampleRateHz = sampleRateHz,
                    device = TrinetRecorder.DeviceMeta(
                        vendorId = dev.info.vendorId,
                        productId = dev.info.productId,
                        serial = dev.info.serial,
                    ),
                )
                _ui.value = RecordUiState.Streaming(sampleRateHz)
            } catch (t: Throwable) {
                _ui.value = RecordUiState.Error(t.message ?: t::class.java.simpleName)
                cleanup()
            }
        }
    }

    fun startRecording() {
        val sess = session ?: return
        val rec = recorder ?: return
        val h = rec.start()
        handle = h
        h.state.onEach { s ->
            _ui.value = when (s) {
                is RecordingState.Active -> RecordUiState.Recording(s.frameCount, s.sampleCount, s.durationMs)
                is RecordingState.Stopped -> RecordUiState.Streaming(sampleRateHz)
                is RecordingState.Failed -> RecordUiState.Error(s.error.message ?: "recording failed")
                RecordingState.Idle -> RecordUiState.Streaming(sampleRateHz)
            }
        }.launchIn(viewModelScope)

        // Disk I/O path: hop to IO so per-frame writeSampleData + sidecar appends
        // never hit the main thread (would otherwise ANR at 30 fps during recording).
        recordingFrameJob = sess.frames
            .onEach { f -> rec.submitAccessUnit(f.annexB, f.ptsUs) }
            .flowOn(Dispatchers.IO)
            .launchIn(viewModelScope)
    }

    fun stopRecording() {
        recordingFrameJob?.cancel(); recordingFrameJob = null
        handle?.stop()
    }

    fun disconnect() {
        cleanup()
        _ui.value = RecordUiState.Idle
    }

    private fun cleanup() {
        handle?.stop(); handle = null
        recorder = null
        session?.close(); session = null
        device?.close(); device = null
    }

    override fun onCleared() {
        cleanup()
        super.onCleared()
    }
}
