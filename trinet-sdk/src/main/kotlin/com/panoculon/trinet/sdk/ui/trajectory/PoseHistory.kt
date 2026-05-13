package com.panoculon.trinet.sdk.ui.trajectory

import com.panoculon.trinet.sdk.model.TriposeSample

/**
 * Fixed-capacity ring buffer of VIO pose samples for the trajectory renderer.
 *
 * Mirrors the synchronisation model of [com.panoculon.trinet.sdk.ui.ImuHistory]:
 * background writers (live SEI parser, playback collector) call [add]; the
 * Compose draw scope reads [snapshotXYZ] / [snapshotQuat] on the main thread.
 * Every mutator bumps [epoch] so Compose recomposes by observing a derived
 * StateFlow on the version counter.
 */
class PoseHistory(private val capacity: Int = 4096) {

    private val x = FloatArray(capacity)
    private val y = FloatArray(capacity)
    private val z = FloatArray(capacity)
    private val qx = FloatArray(capacity)
    private val qy = FloatArray(capacity)
    private val qz = FloatArray(capacity)
    private val qw = FloatArray(capacity)
    private val state = IntArray(capacity)
    private var head = 0
    private var count = 0
    private var version = 0

    private var latest: TriposeSample? = null

    @get:Synchronized val length: Int get() = count
    @get:Synchronized val epoch: Int get() = version
    @get:Synchronized val latestSample: TriposeSample? get() = latest

    @Synchronized fun reset() {
        head = 0; count = 0; version++; latest = null
    }

    @Synchronized fun add(s: TriposeSample) {
        x[head] = s.positionM[0]
        y[head] = s.positionM[1]
        z[head] = s.positionM[2]
        qx[head] = s.quatXyzw[0]
        qy[head] = s.quatXyzw[1]
        qz[head] = s.quatXyzw[2]
        qw[head] = s.quatXyzw[3]
        state[head] = s.filterState
        head = (head + 1) % capacity
        if (count < capacity) count++
        latest = s
        version++
    }

    /** XYZ snapshot in chronological order (oldest first). length = 3 * count. */
    @Synchronized fun snapshotXYZ(): FloatArray {
        val c = count
        if (c == 0) return FloatArray(0)
        val out = FloatArray(c * 3)
        val start = if (c < capacity) 0 else head
        var i = 0
        while (i < c) {
            val src = (start + i) % capacity
            out[i * 3]     = x[src]
            out[i * 3 + 1] = y[src]
            out[i * 3 + 2] = z[src]
            i++
        }
        return out
    }

    /** Filter-state snapshot in chronological order. length = count. */
    @Synchronized fun snapshotState(): IntArray {
        val c = count
        if (c == 0) return IntArray(0)
        val out = IntArray(c)
        val start = if (c < capacity) 0 else head
        var i = 0
        while (i < c) {
            out[i] = state[(start + i) % capacity]
            i++
        }
        return out
    }

    /** Quaternion of the latest pose, or identity if the history is empty. */
    @Synchronized fun latestQuat(): FloatArray {
        if (count == 0) return floatArrayOf(0f, 0f, 0f, 1f)
        val last = (head - 1 + capacity) % capacity
        return floatArrayOf(qx[last], qy[last], qz[last], qw[last])
    }
}
