package com.panoculon.trinet.app.data

import android.media.MediaExtractor
import android.media.MediaFormat
import com.panoculon.trinet.sdk.playback.ImuFileReader
import com.panoculon.trinet.sdk.playback.VtsFileReader
import java.io.File

/**
 * Snapshot of "nerdy stats" about a recording — the kind of info you'd surface
 * in an "Info" dialog: file sizes, codec, bitrate, GOP, sample rates, sensor
 * full-scale, frame-sync state, device id.
 *
 * All fields are nullable so a malformed or partial recording can still produce
 * a partial info dialog rather than crashing.
 */
data class RecordingInfo(
    // identity
    val folderName: String,
    val deviceIdHex: String?,        // null = pre-v4 recording, no id
    val createdAtEpochMs: Long?,

    // video
    val videoSizeBytes: Long?,
    val videoDurationMs: Long?,
    val codec: String?,              // e.g. "video/avc" or "video/hevc"
    val width: Int?,
    val height: Int?,
    val frameRateFps: Float?,        // from MP4 metadata if available
    val totalFrames: Int?,
    val avgBitrateBps: Long?,        // computed = file_size_bits / duration_s
    val gopFrames: Int?,             // mean keyframe interval, in frames
    val keyframeCount: Int?,

    // imu
    val imuSampleRateHz: Int?,       // nominal
    val imuActualRateHz: Float?,     // measured
    val imuSampleCount: Int?,
    val accelFsName: String?,
    val gyroFsName: String?,
    val frameSyncEnabled: Boolean?,
    val imuVersion: Int?,
    val imuStartTimeNs: Long?,

    // vts
    val vtsFps: Float?,              // configured fps from sidecar header
    val vtsFrameCount: Int?,
    val vtsVersion: Int?,
)

object RecordingInfoCollector {

    private val ACCEL_FS_NAMES = mapOf(0 to "±2 g", 1 to "±4 g", 2 to "±8 g", 3 to "±16 g")
    private val GYRO_FS_NAMES =
        mapOf(0 to "±250 dps", 1 to "±500 dps", 2 to "±1000 dps", 3 to "±2000 dps")

    /**
     * Read every recording artefact we can find under [folder] and produce a
     * RecordingInfo. Best-effort: missing or unreadable sidecars produce null
     * fields rather than throwing.
     */
    fun collect(folder: File): RecordingInfo {
        val video = File(folder, "video.mp4")
        val imu = File(folder, "imu.bin")
        val vts = File(folder, "frames.bin")

        // --- video / mp4 stats via MediaExtractor ---
        var codec: String? = null
        var width: Int? = null
        var height: Int? = null
        var frameRateFps: Float? = null
        var videoDurationMs: Long? = null
        var avgBitrateBps: Long? = null
        var totalFrames: Int? = null
        var gopFrames: Int? = null
        var keyframeCount: Int? = null

        if (video.exists()) {
            try {
                val ex = MediaExtractor()
                ex.setDataSource(video.absolutePath)
                var trackIndex = -1
                for (i in 0 until ex.trackCount) {
                    val fmt = ex.getTrackFormat(i)
                    val mime = fmt.getString(MediaFormat.KEY_MIME) ?: ""
                    if (mime.startsWith("video/")) {
                        trackIndex = i
                        codec = mime
                        if (fmt.containsKey(MediaFormat.KEY_WIDTH)) width = fmt.getInteger(MediaFormat.KEY_WIDTH)
                        if (fmt.containsKey(MediaFormat.KEY_HEIGHT)) height = fmt.getInteger(MediaFormat.KEY_HEIGHT)
                        if (fmt.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                            frameRateFps = runCatching { fmt.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat() }
                                .getOrElse { runCatching { fmt.getFloat(MediaFormat.KEY_FRAME_RATE) }.getOrNull() }
                        }
                        if (fmt.containsKey(MediaFormat.KEY_DURATION)) {
                            videoDurationMs = fmt.getLong(MediaFormat.KEY_DURATION) / 1000L
                        }
                        if (fmt.containsKey(MediaFormat.KEY_BIT_RATE)) {
                            avgBitrateBps = fmt.getInteger(MediaFormat.KEY_BIT_RATE).toLong()
                        }
                        break
                    }
                }
                if (trackIndex >= 0) {
                    ex.selectTrack(trackIndex)
                    // Buffer must hold the largest sample. 1080p AVC keyframes
                    // are typically <500 KB; 4 MB gives a comfortable margin
                    // for any sane bitrate. We don't actually use the bytes,
                    // we just need the call to succeed so we can read flags.
                    val scratch = java.nio.ByteBuffer.allocate(4 * 1024 * 1024)
                    var frames = 0
                    var keys = 0
                    while (true) {
                        val sampleSize = ex.readSampleData(scratch, 0)
                        if (sampleSize < 0) break
                        frames++
                        if ((ex.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC) != 0) keys++
                        ex.advance()
                    }
                    totalFrames = frames
                    keyframeCount = keys
                    if (keys > 0) gopFrames = (frames + keys - 1) / keys  // mean keyframe interval
                }
                ex.release()
            } catch (_: Throwable) {
                // best-effort; surface as nulls
            }

            // Bitrate fallback: file bits / duration — useful when MediaFormat
            // didn't expose KEY_BIT_RATE (varies by Android version + encoder).
            if (avgBitrateBps == null && videoDurationMs != null && videoDurationMs!! > 0) {
                avgBitrateBps = video.length() * 8_000L / videoDurationMs!!
            }
        }

        // --- imu sidecar ---
        var deviceIdHex: String? = null
        var imuSampleRateHz: Int? = null
        var imuActualRateHz: Float? = null
        var imuSampleCount: Int? = null
        var accelFsName: String? = null
        var gyroFsName: String? = null
        var frameSyncEnabled: Boolean? = null
        var imuVersion: Int? = null
        var imuStartTimeNs: Long? = null

        if (imu.exists()) {
            try {
                ImuFileReader(imu).use { r ->
                    imuVersion = r.version
                    imuSampleRateHz = r.sampleRateHz
                    imuSampleCount = r.sampleCount
                    accelFsName = ACCEL_FS_NAMES[r.accelFs] ?: "unknown(${r.accelFs})"
                    gyroFsName = GYRO_FS_NAMES[r.gyroFs] ?: "unknown(${r.gyroFs})"
                    frameSyncEnabled = (r.flags and 0x01) != 0
                    deviceIdHex = r.deviceIdHex.takeIf { it.isNotEmpty() }
                    imuStartTimeNs = r.startTimeNs
                    // Measured rate: (count-1) / duration. Need first + last sample
                    // timestamps; cheap to derive from first and last sample reads.
                    if (r.sampleCount >= 2) {
                        val first = r.sampleAt(0).timestampNs
                        val last = r.sampleAt(r.sampleCount - 1).timestampNs
                        val span = last - first
                        if (span > 0) {
                            imuActualRateHz = (r.sampleCount - 1).toFloat() * 1_000_000_000f / span
                        }
                    }
                }
            } catch (_: Throwable) {}
        }

        // --- vts sidecar ---
        var vtsFps: Float? = null
        var vtsFrameCount: Int? = null
        var vtsVersion: Int? = null
        if (vts.exists()) {
            try {
                VtsFileReader(vts).use { r ->
                    vtsVersion = r.version
                    vtsFps = r.fps
                    vtsFrameCount = r.entryCount
                }
            } catch (_: Throwable) {}
        }

        return RecordingInfo(
            folderName = folder.name,
            deviceIdHex = deviceIdHex,
            createdAtEpochMs = folder.lastModified().takeIf { it > 0 },
            videoSizeBytes = video.takeIf { it.exists() }?.length(),
            videoDurationMs = videoDurationMs,
            codec = codec,
            width = width,
            height = height,
            frameRateFps = frameRateFps,
            totalFrames = totalFrames,
            avgBitrateBps = avgBitrateBps,
            gopFrames = gopFrames,
            keyframeCount = keyframeCount,
            imuSampleRateHz = imuSampleRateHz,
            imuActualRateHz = imuActualRateHz,
            imuSampleCount = imuSampleCount,
            accelFsName = accelFsName,
            gyroFsName = gyroFsName,
            frameSyncEnabled = frameSyncEnabled,
            imuVersion = imuVersion,
            imuStartTimeNs = imuStartTimeNs,
            vtsFps = vtsFps,
            vtsFrameCount = vtsFrameCount,
            vtsVersion = vtsVersion,
        )
    }
}
