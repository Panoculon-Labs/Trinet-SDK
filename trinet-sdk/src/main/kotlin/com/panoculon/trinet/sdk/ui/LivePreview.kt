package com.panoculon.trinet.sdk.ui

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.panoculon.trinet.sdk.sei.NalParser
import com.panoculon.trinet.sdk.session.TrinetSession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.withContext
import java.nio.ByteBuffer

private const val TAG = "trinet.preview"

/**
 * Live decoder + preview surface for an active [TrinetSession]. Feeds H.264
 * Annex B frames into a [SurfaceView] via [MediaCodec].
 *
 * Two subtleties the previous implementation got wrong:
 *
 * 1. SPS/PPS may arrive in a different frame than we first start observing.
 *    Some encoders emit them alongside every IDR, but if the decoder loop
 *    subscribes after `session.start()` the first IDR can be missed — and
 *    we'd then wait a full GOP (seconds) for the next one. We *cache* SPS/PPS
 *    across frames and configure the decoder the first time we have both.
 *
 * 2. MediaCodec's `dequeueInputBuffer` can block; it MUST run off the main
 *    thread or Compose will ANR at 30 fps. We hop to [Dispatchers.Default] for
 *    the entire decoder loop.
 */
@Composable
fun LivePreview(
    frames: SharedFlow<TrinetSession.Frame>,
    width: Int,
    height: Int,
    modifier: Modifier = Modifier,
) {
    var surface by remember { mutableStateOf<android.view.Surface?>(null) }

    // Letterbox the SurfaceView to the source aspect ratio so 16:9 video is
    // not stretched to fill a portrait container. Box fills the parent so the
    // background around the letterboxed video stays black.
    val sourceAspect = width.toFloat() / height.toFloat()
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        AndroidView(
            modifier = Modifier
                .fillMaxSize()
                .aspectRatio(sourceAspect, matchHeightConstraintsFirst = false),
            factory = { ctx ->
                SurfaceView(ctx).also { sv ->
                    sv.holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            Log.i(TAG, "surfaceCreated")
                            surface = holder.surface
                        }
                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {
                            Log.i(TAG, "surfaceChanged ${w}x$h fmt=$format")
                        }
                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            Log.i(TAG, "surfaceDestroyed")
                            surface = null
                        }
                    })
                }
            },
        )
    }

    val activeSurface = surface
    LaunchedEffect(activeSurface, width, height) {
        val surf = activeSurface ?: return@LaunchedEffect
        Log.i(TAG, "decoder loop launching ${width}x$height")
        withContext(Dispatchers.Default) {
            runDecoderLoop(frames, width, height, surf)
        }
    }
}

private suspend fun runDecoderLoop(
    frames: SharedFlow<TrinetSession.Frame>,
    width: Int,
    height: Int,
    surface: android.view.Surface,
) {
    var decoder: MediaCodec? = null
    var cachedSps: ByteArray? = null
    var cachedPps: ByteArray? = null
    var configured = false
    var frameCount = 0L
    var queuedCount = 0L
    var firstKeyQueued = false
    val info = MediaCodec.BufferInfo()

    try {
        frames.collect { frame ->
            frameCount++
            val nals = NalParser.splitNalUnits(frame.annexB)
            if (nals.isEmpty()) {
                if (frameCount <= 3) Log.w(TAG, "frame #$frameCount: NO NALs in ${frame.annexB.size}B payload")
                return@collect
            }

            // Log the first few frames so we know what the firmware is actually emitting.
            if (frameCount <= 5) {
                val types = nals.joinToString(",") { it.h264Type.toString() }
                Log.i(TAG, "frame #$frameCount size=${frame.annexB.size} nalTypes=[$types]")
            }

            // Cache SPS/PPS the moment we see them. They may arrive in the same AU as IDR,
            // or in an earlier frame — either way we hold onto them until we can configure.
            for (n in nals) when (n.h264Type) {
                7 -> if (cachedSps == null) {
                    cachedSps = n.copy()
                    Log.i(TAG, "SPS captured (${cachedSps!!.size}B) at frame #$frameCount")
                }
                8 -> if (cachedPps == null) {
                    cachedPps = n.copy()
                    Log.i(TAG, "PPS captured (${cachedPps!!.size}B) at frame #$frameCount")
                }
            }

            if (!configured) {
                val sps = cachedSps
                val pps = cachedPps
                if (sps == null || pps == null) {
                    if (frameCount == 30L || frameCount == 90L || frameCount == 300L) {
                        Log.w(TAG, "still waiting for SPS/PPS after $frameCount frames (sps=${sps != null} pps=${pps != null})")
                    }
                    return@collect
                }
                val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                    setByteBuffer("csd-0", ByteBuffer.wrap(annexBOf(sps)))
                    setByteBuffer("csd-1", ByteBuffer.wrap(annexBOf(pps)))
                }
                try {
                    decoder = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC).apply {
                        configure(format, surface, null, 0)
                        start()
                    }
                    configured = true
                    Log.i(TAG, "decoder configured ${width}x$height at frame #$frameCount")
                } catch (t: Throwable) {
                    Log.e(TAG, "decoder configure failed", t)
                    return@collect
                }
            }

            val dec = decoder ?: return@collect

            // MediaCodec requires the first queued buffer to be a keyframe. If we
            // configured mid-GOP, skip non-IDR frames until the next IDR arrives.
            val isKey = nals.any { it.h264Type == 5 }
            if (!firstKeyQueued && !isKey) return@collect

            val inIdx = dec.dequeueInputBuffer(10_000)
            if (inIdx >= 0) {
                val buf = dec.getInputBuffer(inIdx)!!
                buf.clear()
                buf.put(frame.annexB)
                val flags = if (isKey) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                dec.queueInputBuffer(inIdx, 0, frame.annexB.size, frame.ptsUs, flags)
                queuedCount++
                if (isKey) firstKeyQueued = true
                if (queuedCount == 1L || queuedCount % 60L == 0L) {
                    Log.i(TAG, "decoded queued=$queuedCount (recv=$frameCount key=$isKey)")
                }
            } else if (frameCount % 30L == 0L) {
                Log.w(TAG, "no input buffer (backpressure); dropping recv=$frameCount")
            }

            // Drain any ready output so the surface actually updates.
            while (true) {
                val outIdx = dec.dequeueOutputBuffer(info, 0)
                if (outIdx < 0) break
                dec.releaseOutputBuffer(outIdx, true)
            }
        }
    } catch (t: Throwable) {
        Log.e(TAG, "decoder loop failed", t)
    } finally {
        try { decoder?.stop() } catch (_: Throwable) {}
        decoder?.release()
        Log.i(TAG, "decoder loop exited recv=$frameCount queued=$queuedCount")
    }
}

private val START_CODE = byteArrayOf(0, 0, 0, 1)

private fun annexBOf(nal: ByteArray): ByteArray {
    val out = ByteArray(START_CODE.size + nal.size)
    System.arraycopy(START_CODE, 0, out, 0, START_CODE.size)
    System.arraycopy(nal, 0, out, START_CODE.size, nal.size)
    return out
}
