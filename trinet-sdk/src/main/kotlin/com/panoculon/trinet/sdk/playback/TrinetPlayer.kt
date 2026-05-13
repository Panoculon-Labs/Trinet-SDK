package com.panoculon.trinet.sdk.playback

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.view.Surface
import com.panoculon.trinet.sdk.model.ImuSample
import com.panoculon.trinet.sdk.model.VtsEntry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.io.Closeable

/**
 * Minimal H.264 player: decodes [folder].video into a Surface, paces frames at the
 * MP4-encoded PTS, and exposes the current frame's IMU sample via [currentSample].
 *
 * IMU lookup: nearest-by-timestamp from the .imu sidecar, anchored to the matching
 * entry in the .vts sidecar. Both sidecars are mmap'd.
 */
class TrinetPlayer(
    private val folder: RecordingFolder,
    private val surface: Surface,
) : Closeable {

    private val extractor = MediaExtractor().apply { setDataSource(folder.video.absolutePath) }
    private val videoTrackIndex: Int
    private val format: MediaFormat
    private val decoder: MediaCodec

    val imu = ImuFileReader(folder.imu)
    val vts = VtsFileReader(folder.vts)

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var renderJob: Job? = null
    @Volatile private var started = false
    @Volatile private var closed = false
    @Volatile private var paused = false
    // Scrub mode: render loop is suspended and scrubTo() drives the decoder
    // synchronously. Guarded by `decoderLock` so only one path mutates
    // MediaCodec at a time.
    @Volatile private var scrubbing = false
    private val decoderLock = Any()
    // Last frame successfully rendered by scrubTo(). Used to detect a
    // monotonic-forward drag within the current GOP so we can skip the
    // flush+seek-to-IDR and just decode forward — the cheap path.
    @Volatile private var lastScrubbedFrame: Int = -1

    private val _currentFrame = MutableStateFlow(0)
    val currentFrame: StateFlow<Int> = _currentFrame.asStateFlow()

    private val _currentSample = MutableStateFlow<ImuSample?>(null)
    val currentSample: StateFlow<ImuSample?> = _currentSample.asStateFlow()

    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    /**
     * Emits every sample the render loop advances past, including on seek.
     * Consumers (e.g. a viewmodel running Madgwick fusion) subscribe here
     * rather than to [currentSample] so they receive every step, not just
     * distinct values.
     */
    private val _sampleStream = kotlinx.coroutines.flow.MutableSharedFlow<SeekOrStep>(
        extraBufferCapacity = 64,
        onBufferOverflow = kotlinx.coroutines.channels.BufferOverflow.DROP_OLDEST,
    )
    val sampleStream: kotlinx.coroutines.flow.SharedFlow<SeekOrStep> =
        _sampleStream.asSharedFlow()

    /** Tagged sample: [reset]=true means "history invalidated, rebuild from this sample". */
    data class SeekOrStep(val sample: ImuSample, val reset: Boolean, val frame: Int)

    val frameCount: Int get() = vts.entryCount

    init {
        var idx = -1
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) { idx = i; break }
        }
        require(idx >= 0) { "no video track in ${folder.video}" }
        videoTrackIndex = idx
        extractor.selectTrack(videoTrackIndex)
        format = extractor.getTrackFormat(videoTrackIndex)
        decoder = MediaCodec.createDecoderByType(format.getString(MediaFormat.KEY_MIME)!!)
        decoder.configure(format, surface, null, 0)
    }

    fun play() {
        if (closed) return
        paused = false
        _isPlaying.value = true
        if (renderJob?.isActive == true) return
        // If the render loop finished (EOS) the decoder is still in Executing
        // state — calling start() again crashes. Flush + rewind to restart.
        try {
            if (started) {
                try { decoder.flush() } catch (_: IllegalStateException) {}
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                _currentFrame.value = 0
            } else {
                decoder.start()
                started = true
            }
        } catch (_: IllegalStateException) {
            // Decoder in an unrecoverable state (e.g. Released after close()).
            _isPlaying.value = false
            return
        }
        renderJob = scope.launch { renderLoop() }
    }

    fun pause() {
        paused = true
        _isPlaying.value = false
    }

    fun togglePlayPause() { if (_isPlaying.value) pause() else play() }

    private suspend fun renderLoop() {
        val info = MediaCodec.BufferInfo()
        var inputDone = false
        var outputDone = false
        var startSystemMs = System.currentTimeMillis()
        var firstPtsUs = -1L
        var wasYielding = false

        while (scope.isActive && !outputDone) {
            if (paused || scrubbing) {
                wasYielding = true
                kotlinx.coroutines.delay(30)
                continue
            }
            // Resuming after pause/scrub — extractor is at a new position, so
            // invalidate pacing anchors so the very first output frame resets
            // startSystemMs. Without this, frames pile up or get starved
            // because targetMs is computed against the pre-scrub wall-clock.
            if (wasYielding) {
                firstPtsUs = -1L
                inputDone = false
                wasYielding = false
            }
            try {
                // Hold the decoder lock for the tight queue→dequeue critical
                // section so scrubTo() can't flush mid-op.
                synchronized(decoderLock) {
                    if (!inputDone) {
                        val inIdx = decoder.dequeueInputBuffer(0)
                        if (inIdx >= 0) {
                            val buf = decoder.getInputBuffer(inIdx)!!
                            val n = extractor.readSampleData(buf, 0)
                            if (n < 0) {
                                decoder.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                val pts = extractor.sampleTime
                                decoder.queueInputBuffer(inIdx, 0, n, pts, 0)
                                extractor.advance()
                            }
                        }
                    }
                }

                val outIdx = synchronized(decoderLock) {
                    if (scrubbing) -1 else decoder.dequeueOutputBuffer(info, 10_000)
                }
                if (outIdx >= 0) {
                    if (firstPtsUs < 0) {
                        firstPtsUs = info.presentationTimeUs
                        startSystemMs = System.currentTimeMillis()
                    }
                    val targetMs = startSystemMs + (info.presentationTimeUs - firstPtsUs) / 1000L
                    val now = System.currentTimeMillis()
                    if (targetMs > now) kotlinx.coroutines.delay(targetMs - now)

                    synchronized(decoderLock) {
                        if (!scrubbing) {
                            decoder.releaseOutputBuffer(outIdx, true)
                            advanceTimeline(info.presentationTimeUs, reset = false)
                            if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outputDone = true
                        }
                    }
                } else {
                    kotlinx.coroutines.delay(2)
                }
            } catch (_: IllegalStateException) {
                // scrubTo flushed the codec — reset timing anchors and keep going.
                firstPtsUs = -1L
                inputDone = false
                kotlinx.coroutines.delay(10)
            }
        }
        _isPlaying.value = false
    }

    private fun advanceTimeline(ptsUs: Long, reset: Boolean) {
        val nextFrame = (_currentFrame.value + 1).coerceAtMost(frameCount - 1)
        _currentFrame.value = nextFrame
        if (vts.entryCount == 0 || imu.sampleCount == 0) return
        val entry: VtsEntry = vts.entryAt(nextFrame)
        val idx = imu.indexAt(entry.sofTimestampNs)
        if (idx >= 0) {
            val s = imu.sampleAt(idx)
            _currentSample.value = s
            _sampleStream.tryEmit(SeekOrStep(s, reset, nextFrame))
        }
    }

    /**
     * Enter scrub mode. The render loop yields the decoder so [scrubTo] can
     * drive it synchronously. Call [endScrub] when the user releases the
     * slider — if [endScrub] is passed `resume = true` the loop continues
     * from the current position, otherwise the player stays paused.
     */
    fun beginScrub() {
        if (closed) return
        scrubbing = true
        lastScrubbedFrame = -1  // next scrubTo will take the slow path (full flush)
    }

    /**
     * Decode a frame at [frame] and render it to the surface. VLC-style
     * live-scrub: every slider drag update calls this; the user sees the
     * video follow their thumb.
     *
     * Must be called from a background dispatcher while [beginScrub] is
     * active — each call can spend up to [SCRUB_BUDGET_MS] wall-clock ms
     * decoding, so never invoke on the main thread.
     *
     * Fast path: if the target is a monotonic forward step within the
     * current GOP (< 30 frames past the last rendered scrub), we skip the
     * flush + SEEK_TO_PREVIOUS_SYNC and just keep feeding the extractor
     * forward. Cross-GOP or backward scrubs take the slow path.
     */
    fun scrubTo(frame: Int) {
        if (closed || !started) return
        val clamped = frame.coerceIn(0, (frameCount - 1).coerceAtLeast(0))
        _currentFrame.value = clamped
        if (vts.entryCount == 0) return
        val targetPtsUs = vts.entryAt(clamped).vencPtsUs

        // Keep the numeric IMU readout in sync immediately; the viewmodel
        // rebuilds plot history on its own in the scrub worker.
        if (imu.sampleCount > 0) {
            val idx = imu.indexAt(vts.entryAt(clamped).sofTimestampNs)
            if (idx >= 0) _currentSample.value = imu.sampleAt(idx)
        }

        synchronized(decoderLock) {
            val prev = lastScrubbedFrame
            val fastPath = prev in 0..clamped && (clamped - prev) < 30
            if (!fastPath) {
                try {
                    decoder.flush()
                    extractor.seekTo(targetPtsUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                } catch (_: IllegalStateException) { return }
            }

            val info = MediaCodec.BufferInfo()
            var rendered = false
            val start = System.currentTimeMillis()
            // Time-bounded: each scrub has ~SCRUB_BUDGET_MS to produce a
            // frame. Worst case on slow path is ~one GOP (1s @ 30 fps, ~150 ms
            // of decode work on a modern phone). The conflated input flow
            // naturally drops stale targets while we're busy.
            while (!rendered && System.currentTimeMillis() - start < SCRUB_BUDGET_MS) {
                try {
                    val inIdx = decoder.dequeueInputBuffer(5_000)
                    if (inIdx >= 0) {
                        val buf = decoder.getInputBuffer(inIdx)!!
                        val n = extractor.readSampleData(buf, 0)
                        if (n < 0) {
                            decoder.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        } else {
                            val pts = extractor.sampleTime
                            decoder.queueInputBuffer(inIdx, 0, n, pts, 0)
                            extractor.advance()
                        }
                    }
                    val outIdx = decoder.dequeueOutputBuffer(info, 5_000)
                    if (outIdx >= 0) {
                        val atTarget = info.presentationTimeUs >= targetPtsUs
                        decoder.releaseOutputBuffer(outIdx, atTarget)
                        if (atTarget) rendered = true
                    }
                } catch (_: IllegalStateException) { return }
            }
            // If we rendered, remember the position so the next scrub can
            // take the fast path when possible. On timeout, force full
            // flush+seek next time to recover cleanly.
            lastScrubbedFrame = if (rendered) clamped else -1
        }
    }

    companion object {
        private const val SCRUB_BUDGET_MS = 80L
    }

    /** Exit scrub mode. If [resume] is true, resume playback; else stay paused. */
    fun endScrub(resume: Boolean) {
        scrubbing = false
        if (resume) play() else pause()
    }

    /** Seek to a specific frame (0-based). Updates IMU to match the frame's SoF. */
    fun seekToFrame(frame: Int) {
        if (closed) return
        val clamped = frame.coerceIn(0, (frameCount - 1).coerceAtLeast(0))
        _currentFrame.value = clamped
        if (vts.entryCount == 0 || imu.sampleCount == 0) return
        val entry = vts.entryAt(clamped)
        val idx = imu.indexAt(entry.sofTimestampNs)
        if (idx >= 0) {
            // Note: the viewmodel backfills plot history + Madgwick from the
            // .imu sidecar on seek, so we intentionally don't emit through
            // sampleStream here — that would race the backfill.
            _currentSample.value = imu.sampleAt(idx)
        }
        synchronized(decoderLock) {
            extractor.seekTo(entry.vencPtsUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            if (started) {
                try { decoder.flush() } catch (_: IllegalStateException) {}
            }
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        scope.cancel()
        try { decoder.stop() } catch (_: IllegalStateException) {}
        decoder.release()
        extractor.release()
        imu.close(); vts.close()
    }
}
