package com.panoculon.trinet.sdk.ui

import com.panoculon.trinet.sdk.model.ImuSample

/**
 * Fixed-capacity ring buffer of recent IMU samples used by the overlay plots.
 *
 * Mutated from background dispatchers (sample-stream collector, seek backfill)
 * and read from Compose's main thread during recomposition, so every access is
 * synchronised on `this`. Without the synchronisation `materialise()` crashed
 * with an AIOOBE when a concurrent `add()` bumped `count` mid-iteration.
 *
 * The rolling window must be invalidated whenever playback seeks, otherwise the
 * plots draw values from both sides of the seek and show continuous motion the
 * user never actually scrubbed through.
 */
class ImuHistory(private val capacity: Int = 300) {
    private val ax = FloatArray(capacity)
    private val ay = FloatArray(capacity)
    private val az = FloatArray(capacity)
    private val gx = FloatArray(capacity)
    private val gy = FloatArray(capacity)
    private val gz = FloatArray(capacity)
    private val mx = FloatArray(capacity)
    private val my = FloatArray(capacity)
    private val mz = FloatArray(capacity)
    private val fs = FloatArray(capacity)
    private var head = 0      // next write index
    private var count = 0     // total valid entries [0..capacity]
    private var version = 0   // bumped each mutation to force Compose recomposition

    @get:Synchronized val length: Int get() = count
    @get:Synchronized val epoch: Int get() = version

    @Synchronized fun reset() {
        head = 0; count = 0; version++
    }

    @Synchronized fun add(s: ImuSample) {
        ax[head] = s.accel[0]; ay[head] = s.accel[1]; az[head] = s.accel[2]
        gx[head] = s.gyro[0];  gy[head] = s.gyro[1];  gz[head] = s.gyro[2]
        mx[head] = s.mag[0];   my[head] = s.mag[1];   mz[head] = s.mag[2]
        fs[head] = s.fsyncDelayUs
        head = (head + 1) % capacity
        if (count < capacity) count++
        version++
    }

    fun accelX() = snapshot(ax)
    fun accelY() = snapshot(ay)
    fun accelZ() = snapshot(az)
    fun gyroX()  = snapshot(gx)
    fun gyroY()  = snapshot(gy)
    fun gyroZ()  = snapshot(gz)
    fun magX()   = snapshot(mx)
    fun magY()   = snapshot(my)
    fun magZ()   = snapshot(mz)
    fun fsyncUs() = snapshot(fs)

    @Synchronized
    private fun snapshot(src: FloatArray): FloatArray {
        val c = count
        if (c == 0) return FloatArray(0)
        val out = FloatArray(c)
        val start = if (c < capacity) 0 else head
        var i = 0
        while (i < c) {
            out[i] = src[(start + i) % capacity]
            i++
        }
        return out
    }
}
