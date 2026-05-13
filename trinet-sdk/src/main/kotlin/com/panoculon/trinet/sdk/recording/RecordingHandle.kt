package com.panoculon.trinet.sdk.recording

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

sealed interface RecordingState {
    data object Idle : RecordingState
    data class Active(val frameCount: Long, val sampleCount: Long, val durationMs: Long) : RecordingState
    data class Stopped(val folder: File, val frameCount: Long, val sampleCount: Long, val durationMs: Long) : RecordingState
    data class Failed(val error: Throwable) : RecordingState
}

/**
 * Public handle to an in-progress or completed recording. The folder layout is:
 *   <folder>/video.mp4
 *   <folder>/imu.bin
 *   <folder>/frames.bin
 *   <folder>/meta.json
 */
class RecordingHandle internal constructor(
    val folder: File,
    private val onStop: () -> Unit,
) {
    private val _state = MutableStateFlow<RecordingState>(RecordingState.Active(0, 0, 0))
    val state: StateFlow<RecordingState> = _state.asStateFlow()

    val videoFile: File get() = File(folder, "video.mp4")
    val imuFile: File get() = File(folder, "imu.bin")
    val vtsFile: File get() = File(folder, "frames.bin")
    val metaFile: File get() = File(folder, "meta.json")

    internal fun update(state: RecordingState) { _state.value = state }

    /** Stop the recording and finalize all sidecars + the MP4 container. */
    fun stop() = onStop()
}
