package com.panoculon.trinet.sdk.session

import android.util.Log
import com.panoculon.trinet.sdk.transport.NativeBridge
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.io.Closeable

private const val TAG = "trinet.session"

/**
 * One active streaming session over an open UVC device. Frames are fanned out
 * via [frames] for any number of consumers (e.g. recorder + live preview decoder).
 */
class TrinetSession internal constructor(
    private val nativeHandle: Long,
    val config: SessionConfig,
) : Closeable {

    // replay = 1 so a late-attaching subscriber (e.g. Compose LivePreview, mounted
    // after sess.start() returns) still sees the last frame — critical for catching
    // the first IDR + its SPS/PPS when they arrive before the subscriber registers.
    private val _frames = MutableSharedFlow<Frame>(
        replay = 1,
        extraBufferCapacity = 32,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )
    val frames: SharedFlow<Frame> = _frames.asSharedFlow()

    @Volatile private var emitCount = 0L
    @Volatile private var emitDrops = 0L

    private val _errors = MutableSharedFlow<String>(extraBufferCapacity = 4)
    val errors: SharedFlow<String> = _errors.asSharedFlow()

    @Volatile private var started = false
    @Volatile private var closed = false

    data class Frame(val annexB: ByteArray, val ptsUs: Long)

    /** Begin streaming. Returns false if libuvc rejected the format negotiation. */
    @Synchronized
    fun start(): Boolean {
        check(!closed) { "session closed" }
        if (started) return true
        NativeBridge.setSink(
            sink = { buf, pts ->
                val ok = _frames.tryEmit(Frame(buf, pts))
                val n = ++emitCount
                if (!ok) emitDrops++
                if (n == 1L || n == 30L || n % 300L == 0L) {
                    Log.i(TAG, "frames emitted=$n drops=$emitDrops subscribers=${_frames.subscriptionCount.value}")
                }
            },
            errorSink = { msg ->
                Log.w(TAG, "native error: $msg")
                _errors.tryEmit(msg)
            },
        )
        val ok = NativeBridge.nativeStartStream(nativeHandle, config.width, config.height, config.fps)
        if (ok) started = true else NativeBridge.setSink(null, null)
        return ok
    }

    @Synchronized
    fun stop() {
        if (!started) return
        NativeBridge.nativeStopStream(nativeHandle)
        NativeBridge.setSink(null, null)
        started = false
    }

    /**
     * Stop streaming and mark this session unusable. The native UVC handle is
     * owned by [com.panoculon.trinet.sdk.device.TrinetDevice]; closing the
     * session does NOT release it — closing the Device does.
     *
     * Calling nativeClose here caused a SIGABRT (pthread_mutex destroyed)
     * because RecordViewModel.cleanup used to call both session.close() and
     * device.close(), resulting in two uvc_close invocations on the same
     * handle.
     */
    @Synchronized
    override fun close() {
        if (closed) return
        stop()
        closed = true
    }
}
