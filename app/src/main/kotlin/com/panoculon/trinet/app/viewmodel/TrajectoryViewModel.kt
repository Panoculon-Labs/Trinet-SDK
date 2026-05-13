package com.panoculon.trinet.app.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.panoculon.trinet.sdk.device.DeviceDiscovery
import com.panoculon.trinet.sdk.device.TrinetDevice
import com.panoculon.trinet.sdk.sei.SeiPoseParser
import com.panoculon.trinet.sdk.session.SessionConfig
import com.panoculon.trinet.sdk.session.TrinetSession
import com.panoculon.trinet.sdk.ui.trajectory.PoseHistory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch

sealed interface TrajectoryUiState {
    data object Idle : TrajectoryUiState
    data object Connecting : TrajectoryUiState
    data class Streaming(val samplesSeen: Long) : TrajectoryUiState
    data class Error(val message: String) : TrajectoryUiState
}

/**
 * Drives the live trajectory screen: open a UVC session, parse every access
 * unit for TRIPOSE SEIs, fold them into a [PoseHistory] the screen renders.
 *
 * Note: this view model owns its own UVC session, so opening it from a screen
 * already streaming (e.g. the Record screen) would contend for the camera.
 * For the playback flow we reuse [PoseHistory] but drive it from
 * [PlayerViewModel] instead.
 */
class TrajectoryViewModel(app: Application) : AndroidViewModel(app) {

    private val config = SessionConfig(width = 1920, height = 1080, fps = 30)

    private var device: TrinetDevice? = null
    private var session: TrinetSession? = null
    private var frameJob: kotlinx.coroutines.Job? = null

    val history = PoseHistory(capacity = 4096)
    private val _historyVersion = MutableStateFlow(0)
    val historyVersion: StateFlow<Int> = _historyVersion.asStateFlow()

    private val _ui = MutableStateFlow<TrajectoryUiState>(TrajectoryUiState.Idle)
    val ui: StateFlow<TrajectoryUiState> = _ui.asStateFlow()

    private var samplesSeen: Long = 0L

    fun connect() {
        if (_ui.value !is TrajectoryUiState.Idle && _ui.value !is TrajectoryUiState.Error) return
        _ui.value = TrajectoryUiState.Connecting
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val ctx = getApplication<Application>()
                val dev = DeviceDiscovery.openFirstAvailable(ctx)
                    ?: throw IllegalStateException("no Trinet camera device found")
                device = dev
                val sess = dev.open(config)
                session = sess
                if (!sess.start()) throw IllegalStateException("libuvc rejected stream config")

                // Tap TRIPOSE SEI on the IO dispatcher so the parser never
                // touches the main thread.
                frameJob = sess.frames
                    .onEach { f ->
                        for (p in SeiPoseParser.parse(f.annexB)) {
                            history.add(p.sample)
                            samplesSeen++
                            _historyVersion.value = history.epoch
                        }
                        _ui.value = TrajectoryUiState.Streaming(samplesSeen)
                    }
                    .flowOn(Dispatchers.IO)
                    .launchIn(viewModelScope)

                _ui.value = TrajectoryUiState.Streaming(samplesSeen)
            } catch (t: Throwable) {
                _ui.value = TrajectoryUiState.Error(t.message ?: t::class.java.simpleName)
                cleanup()
            }
        }
    }

    fun reset() {
        history.reset()
        samplesSeen = 0L
        _historyVersion.value = history.epoch
    }

    fun disconnect() {
        cleanup()
        _ui.value = TrajectoryUiState.Idle
    }

    private fun cleanup() {
        frameJob?.cancel(); frameJob = null
        session?.close(); session = null
        device?.close(); device = null
    }

    override fun onCleared() {
        cleanup()
        super.onCleared()
    }
}
