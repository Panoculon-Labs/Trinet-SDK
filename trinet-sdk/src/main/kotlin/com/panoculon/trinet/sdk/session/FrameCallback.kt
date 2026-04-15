package com.panoculon.trinet.sdk.session

/**
 * Per-frame callback invoked from libuvc's stream thread. Implementers must
 * not block — copy data and return.
 *
 * @param annexB H.264 access unit in Annex B framing (start codes preserved),
 *               typically containing one IDR/non-IDR plus optional SEI.
 * @param ptsUs  Capture timestamp in microseconds.
 */
fun interface FrameCallback {
    fun onFrame(annexB: ByteArray, ptsUs: Long)
}
