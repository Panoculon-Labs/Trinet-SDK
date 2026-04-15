package com.panoculon.trinet.sdk.recording

import com.panoculon.trinet.sdk.TrinetSdk
import com.panoculon.trinet.sdk.model.ImuSample
import com.panoculon.trinet.sdk.model.VtsEntry
import com.panoculon.trinet.sdk.sei.SeiImuParser
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Orchestrates a single recording: the caller pushes raw H.264 access units (one
 * per video frame), and the recorder splits SEI for IMU sidecar writing while
 * passing the full bitstream through to the MP4 muxer.
 *
 * Per-recording folder layout: video.mp4 + imu.bin + frames.bin + meta.json.
 */
class TrinetRecorder(
    private val rootDir: File,
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val sampleRateHz: Int,
    private val accelFsDefault: Int = 2,
    private val gyroFsDefault: Int = 3,
    private val device: DeviceMeta = DeviceMeta(0x2207, 0x0016, null),
) {

    data class DeviceMeta(val vendorId: Int, val productId: Int, val serial: String?)

    private var folder: File? = null
    private var mp4: Mp4Writer? = null
    private var imu: ImuFileWriter? = null
    private var vts: VtsFileWriter? = null
    private var startNs: Long = 0L
    private var observedAccelFs: Int = accelFsDefault
    private var observedGyroFs: Int = gyroFsDefault
    private var pendingFrameTsForVts: Long? = null
    private var frameNumber: Long = 0L

    private var handle: RecordingHandle? = null

    /** Begin a new recording. Creates `recording_<ts>/` under [rootDir]. */
    @Synchronized
    fun start(): RecordingHandle {
        check(folder == null) { "TrinetRecorder.start called while another recording is in progress" }
        val id = "recording_" + SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
        val dir = File(rootDir, id).also { require(it.mkdirs() || it.isDirectory) { "cannot create $it" } }
        folder = dir

        mp4 = Mp4Writer(File(dir, "video.mp4"), width, height, fps)
        // ImuFileWriter writes its header on the first sample (so accelFs/gyroFs reflect
        // what the device actually announced via SEI).
        imu = ImuFileWriter(
            file = File(dir, "imu.bin"),
            sampleRateHz = sampleRateHz,
            accelFs = accelFsDefault,
            gyroFs = gyroFsDefault,
            flagsFsync = true,
        )
        vts = VtsFileWriter(File(dir, "frames.bin"), fps.toFloat())

        startNs = System.nanoTime()
        frameNumber = 0L
        pendingFrameTsForVts = null

        val h = RecordingHandle(dir, ::stopInternal)
        handle = h
        h.update(RecordingState.Active(0, 0, 0))
        return h
    }

    /**
     * Submit one access unit (one video frame's NAL bundle, Annex B). [ptsUs] is
     * the presentation timestamp; the recorder also derives a `sof_ts_ns` for the
     * VTS sidecar from any SEI-IMU samples found in this AU.
     */
    @Synchronized
    fun submitAccessUnit(annexB: ByteArray, ptsUs: Long) {
        val mp = mp4 ?: return
        val imuW = imu ?: return
        val vtsW = vts ?: return

        // 1) Pass through to MP4 muxer (SEI included, best-effort).
        mp.writeAccessUnit(annexB, ptsUs)

        // 2) Extract any Trinet IMU SEI in this AU and append the samples.
        val seiPayloads = SeiImuParser.parse(annexB)
        var sofForFrame: Long? = null
        for (p in seiPayloads) {
            observedAccelFs = p.header.accelFs
            observedGyroFs = p.header.gyroFs
            for (s in p.samples) {
                imuW.append(s)
                if (sofForFrame == null) {
                    sofForFrame = deriveSofNs(s)
                }
            }
        }

        // 3) Append VTS entry — fall back to monotonic ns if no SEI in this frame.
        val sofNs = sofForFrame ?: (System.nanoTime() - startNs)
        vtsW.append(
            VtsEntry(
                frameNumber = frameNumber,
                sofTimestampNs = sofNs,
                vencSeq = frameNumber,
                vencPtsUs = ptsUs,
            )
        )
        frameNumber++

        handle?.update(
            RecordingState.Active(
                frameCount = frameNumber,
                sampleCount = imuW.sampleCount,
                durationMs = (System.nanoTime() - startNs) / 1_000_000L,
            )
        )
    }

    /** Timestamp-to-SoF conversion baked into the Trinet wire contract. */
    private fun deriveSofNs(s: ImuSample): Long =
        s.timestampNs - (s.fsyncDelayUs * 1_000f).toLong()

    @Synchronized
    private fun stopInternal() {
        val dir = folder ?: return
        val durationMs = (System.nanoTime() - startNs) / 1_000_000L

        try {
            imu?.close()
            vts?.close()
            mp4?.close()

            MetaWriter.write(
                File(dir, "meta.json"),
                RecordingMeta(
                    id = dir.name,
                    createdAtEpochMs = System.currentTimeMillis(),
                    deviceVendorId = device.vendorId,
                    deviceProductId = device.productId,
                    deviceSerial = device.serial,
                    width = width,
                    height = height,
                    fps = fps,
                    codec = "h264",
                    sdkVersion = TrinetSdk.VERSION,
                ),
            )

            handle?.update(
                RecordingState.Stopped(
                    folder = dir,
                    frameCount = frameNumber,
                    sampleCount = imu?.sampleCount ?: 0L,
                    durationMs = durationMs,
                )
            )
        } catch (t: Throwable) {
            handle?.update(RecordingState.Failed(t))
        } finally {
            mp4 = null; imu = null; vts = null; folder = null
        }
    }
}
