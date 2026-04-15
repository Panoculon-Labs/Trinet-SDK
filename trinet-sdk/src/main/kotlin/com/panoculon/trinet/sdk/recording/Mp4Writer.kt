package com.panoculon.trinet.sdk.recording

import android.media.MediaCodec
import android.media.MediaFormat
import android.media.MediaMuxer
import com.panoculon.trinet.sdk.sei.NalParser
import java.io.Closeable
import java.io.File
import java.nio.ByteBuffer

/**
 * Wraps [MediaMuxer] to write MP4 from raw H.264 Annex B NAL units. Extracts SPS/PPS
 * from the first IDR group and feeds them as csd-0/csd-1; subsequent NALs (including
 * SEI for IMU passthrough) are written as sample buffers.
 *
 * The wall-clock PTS is supplied by the caller as a microsecond timestamp per *frame*
 * (one PTS per access unit, even if that AU contains multiple NALs like SEI + IDR).
 */
class Mp4Writer(
    private val outFile: File,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
) : Closeable {

    private val muxer = MediaMuxer(outFile.absolutePath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var trackIndex: Int = -1
    private var started = false
    private var sps: ByteArray? = null
    private var pps: ByteArray? = null
    private val pendingNals = ArrayList<ByteArray>()
    var frameCount: Long = 0L; private set

    /**
     * Submit one access unit (one frame's worth of NAL units, in Annex B format with
     * start codes between them). Caller supplies presentation timestamp in microseconds.
     */
    @Synchronized
    fun writeAccessUnit(annexB: ByteArray, ptsUs: Long) {
        val nals = NalParser.splitNalUnits(annexB)
        if (nals.isEmpty()) return

        if (!started) {
            for (n in nals) {
                when (n.h264Type) {
                    7 -> sps = n.copy()
                    8 -> pps = n.copy()
                }
            }
            if (sps != null && pps != null) startMuxer()
            else {
                // No SPS/PPS yet — buffer and bail until we have them.
                for (n in nals) pendingNals.add(annexBOf(n.copy()))
                return
            }
        }

        // Reassemble into a single byte buffer; mark KEY_FRAME if any VCL NAL is IDR (type 5).
        val merged = annexBOf(*nals.map { it.copy() }.toTypedArray())
        val isKey = nals.any { it.h264Type == 5 }
        writeBuffer(merged, ptsUs, isKey)
        frameCount++

        // Drain anything we buffered before we had SPS/PPS (rare).
        if (pendingNals.isNotEmpty()) {
            for (b in pendingNals) writeBuffer(b, ptsUs, false)
            pendingNals.clear()
        }
    }

    private fun startMuxer() {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setByteBuffer("csd-0", ByteBuffer.wrap(annexBOf(sps!!)))
            setByteBuffer("csd-1", ByteBuffer.wrap(annexBOf(pps!!)))
        }
        trackIndex = muxer.addTrack(format)
        muxer.start()
        started = true
    }

    private fun writeBuffer(annexB: ByteArray, ptsUs: Long, key: Boolean) {
        val bb = ByteBuffer.wrap(annexB)
        val info = MediaCodec.BufferInfo().apply {
            offset = 0
            size = annexB.size
            presentationTimeUs = ptsUs
            flags = if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
        }
        muxer.writeSampleData(trackIndex, bb, info)
    }

    @Synchronized
    override fun close() {
        if (started) {
            try { muxer.stop() } catch (_: IllegalStateException) { /* zero-frame stop */ }
        }
        muxer.release()
    }

    companion object {
        private val START_CODE = byteArrayOf(0, 0, 0, 1)

        /** Concatenate NAL bodies into an Annex B stream, prefixing each with a 4-byte start code. */
        private fun annexBOf(vararg nals: ByteArray): ByteArray {
            val total = nals.sumOf { it.size + START_CODE.size }
            val out = ByteArray(total)
            var off = 0
            for (n in nals) {
                System.arraycopy(START_CODE, 0, out, off, START_CODE.size); off += START_CODE.size
                System.arraycopy(n, 0, out, off, n.size); off += n.size
            }
            return out
        }
    }
}
