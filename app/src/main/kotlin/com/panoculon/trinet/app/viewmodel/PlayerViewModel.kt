package com.panoculon.trinet.app.viewmodel

import android.app.Application
import android.view.Surface
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.panoculon.trinet.app.data.AppPaths
import com.panoculon.trinet.sdk.fusion.Madgwick
import com.panoculon.trinet.sdk.model.ImuSample
import com.panoculon.trinet.sdk.playback.RecordingFolder
import com.panoculon.trinet.sdk.playback.TrinetPlayer
import com.panoculon.trinet.sdk.ui.ImuHistory
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import java.io.File

class PlayerViewModel(app: Application) : AndroidViewModel(app) {

    private var player: TrinetPlayer? = null
    private var bridgeJobs = mutableListOf<Job>()
    private val madgwick = Madgwick(beta = 0.1f)
    private var lastSampleNs: Long = 0L

    // Scrub requests arrive on the main thread from Slider.onValueChange. Each
    // scrubTo on the player does up to ~100 ms of synchronous decode, so we
    // CANNOT run it inline or the UI freezes. A conflated SharedFlow collapses
    // rapid drags into "only the latest target matters" and a single worker on
    // Dispatchers.Default pulls values and hands them to the player.
    private val scrubTargets = MutableSharedFlow<Int>(
        replay = 0,
        extraBufferCapacity = 1,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    private var scrubWorker: Job? = null

    // History + quaternion are exposed as StateFlows keyed by a version int so
    // Compose recomposes when the ring buffer mutates in place.
    val history = ImuHistory(capacity = 300)
    private val _historyVersion = MutableStateFlow(0)
    val historyVersion: StateFlow<Int> = _historyVersion.asStateFlow()

    private val _quat = MutableStateFlow(floatArrayOf(0f, 0f, 0f, 1f))
    val quat: StateFlow<FloatArray> = _quat.asStateFlow()

    private val _currentSample = MutableStateFlow<ImuSample?>(null)
    val currentSample: StateFlow<ImuSample?> = _currentSample.asStateFlow()

    private val _frame = MutableStateFlow(0)
    val frame: StateFlow<Int> = _frame.asStateFlow()

    private val _frameCount = MutableStateFlow(0)
    val frameCount: StateFlow<Int> = _frameCount.asStateFlow()

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    fun open(recordingId: String, surface: Surface) {
        val dir = File(AppPaths.recordingsDir(getApplication()), recordingId)
        val folder = RecordingFolder(dir)
        if (!folder.isComplete) return
        player?.close()
        bridgeJobs.forEach { it.cancel() }
        bridgeJobs.clear()
        history.reset(); madgwick.reset(); lastSampleNs = 0L
        _historyVersion.value++

        val p = TrinetPlayer(folder, surface)
        player = p
        _frameCount.value = p.frameCount

        bridgeJobs += p.currentFrame.onEach { _frame.value = it }.launchIn(viewModelScope)
        bridgeJobs += p.currentSample.onEach { _currentSample.value = it }.launchIn(viewModelScope)
        bridgeJobs += p.isPlaying.onEach { _isPlaying.value = it }.launchIn(viewModelScope)
        bridgeJobs += p.sampleStream.onEach { step ->
            if (step.reset) {
                history.reset()
                madgwick.reset()
                lastSampleNs = 0L
            }
            val s = step.sample
            // Seed Madgwick on first sample from accel (tilt); also reseed after a scrub
            // so the cube snaps to a sensible attitude instead of drifting from identity.
            if (lastSampleNs == 0L || step.reset) {
                madgwick.seedFromAccel(s.accel[0], s.accel[1], s.accel[2])
            } else {
                val dt = ((s.timestampNs - lastSampleNs).coerceAtLeast(0L)) / 1e9f
                madgwick.updateIMU(
                    gx = s.gyro[0], gy = s.gyro[1], gz = s.gyro[2],
                    ax = s.accel[0], ay = s.accel[1], az = s.accel[2],
                    dt = dt,
                )
            }
            lastSampleNs = s.timestampNs
            _quat.value = madgwick.asXyzw()
            history.add(s)
            _historyVersion.value = history.epoch
        }.launchIn(viewModelScope)

        p.play()
    }

    /**
     * Seek to [frame] AND replay Madgwick + refill the plot history from the
     * .imu sidecar so the plots don't stay empty while the user scrubs.
     */
    fun seek(frame: Int) {
        val p = player ?: return
        p.seekToFrame(frame)
        _frame.value = frame
        viewModelScope.launch(Dispatchers.Default) { backfillImuFor(p, frame) }
    }

    /**
     * Rebuild plot history + Madgwick quaternion for [frame] from the .imu
     * sidecar. Synchronous, but cheap (~5 ms for 300 samples) so safe to run
     * on the scrub worker on each drag update.
     */
    private fun backfillImuFor(p: TrinetPlayer, frame: Int) {
        if (p.vts.entryCount == 0 || p.imu.sampleCount == 0) return
        val entry = p.vts.entryAt(frame.coerceIn(0, p.vts.entryCount - 1))
        val anchorIdx = p.imu.indexAt(entry.sofTimestampNs)
        if (anchorIdx < 0) return
        val windowSize = 300
        val startIdx = (anchorIdx - windowSize + 1).coerceAtLeast(0)

        history.reset()
        madgwick.reset()
        val first = p.imu.sampleAt(startIdx)
        madgwick.seedFromAccel(first.accel[0], first.accel[1], first.accel[2])
        var lastNs = first.timestampNs
        history.add(first)
        var i = startIdx + 1
        while (i <= anchorIdx) {
            val s = p.imu.sampleAt(i)
            val dt = ((s.timestampNs - lastNs).coerceAtLeast(0L)) / 1e9f
            madgwick.updateIMU(
                gx = s.gyro[0], gy = s.gyro[1], gz = s.gyro[2],
                ax = s.accel[0], ay = s.accel[1], az = s.accel[2],
                dt = dt,
            )
            lastNs = s.timestampNs
            history.add(s)
            i++
        }
        lastSampleNs = lastNs
        _quat.value = madgwick.asXyzw()
        _currentSample.value = p.imu.sampleAt(anchorIdx)
        _historyVersion.value = history.epoch
    }

    fun togglePlayPause() { player?.togglePlayPause() }

    /**
     * User grabbed the slider. Put the player in scrub mode and start the
     * background worker that drains [scrubTargets]. The worker lives only for
     * the duration of the drag so we don't hold a decoder-busy coroutine
     * between scrubs.
     */
    fun beginScrub() {
        val p = player ?: return
        p.beginScrub()
        scrubWorker?.cancel()
        scrubWorker = viewModelScope.launch(Dispatchers.Default) {
            scrubTargets.collect { target ->
                // 1. Video: decode + render at target (bounded ~80ms wall-clock).
                p.scrubTo(target)
                // 2. IMU plots: rebuild rolling window + Madgwick for this
                //    frame so the graphs track the scrubber. Cheap (~5ms).
                backfillImuFor(p, target)
            }
        }
    }

    /**
     * Called on every slider drag update. Non-blocking: just publishes the
     * new target frame onto the conflated channel. The background worker
     * picks it up and decodes/renders the corresponding video frame.
     * We optimistically update [_frame] for the timecode readout.
     */
    fun scrubTo(frame: Int) {
        _frame.value = frame
        scrubTargets.tryEmit(frame)
    }

    /** User released the slider. Stop the scrub worker, run final seek + IMU backfill, then resume if desired. */
    fun endScrub(frame: Int, resume: Boolean) {
        scrubWorker?.cancel()
        scrubWorker = null
        val p = player ?: return
        p.endScrub(resume = resume)
        seek(frame)
    }

    override fun onCleared() {
        player?.close()
        player = null
        super.onCleared()
    }
}
