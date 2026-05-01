package com.panoculon.trinet.app.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.panoculon.trinet.app.data.RecordingInfo
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * "Info" dialog for a recording — surfaces bitrate, GOP length, FPS, codec,
 * IMU sample rate, sensor full-scale, frame-sync state, device id, and a few
 * other nerdy stats.
 */
@Composable
fun InfoDialog(
    info: RecordingInfo,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Recording info") },
        text = {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                SectionHeader("Identity")
                StatRow("Folder", info.folderName)
                StatRow("Device ID", info.deviceIdHex ?: "(pre-v4 recording)")
                info.createdAtEpochMs?.let {
                    val ts = SimpleDateFormat("yyyy-MM-dd HH:mm:ss z", Locale.US).format(Date(it))
                    StatRow("Created", ts)
                }

                Spacer(Modifier.height(8.dp))
                SectionHeader("Video")
                StatRow("File size", info.videoSizeBytes?.let(::formatBytes) ?: "-")
                StatRow("Duration", info.videoDurationMs?.let(::formatMs) ?: "-")
                StatRow("Codec", info.codec ?: "-")
                StatRow("Resolution",
                    if (info.width != null && info.height != null) "${info.width} × ${info.height}" else "-")
                StatRow("FPS (mp4)", info.frameRateFps?.let { "%.2f".format(it) } ?: "-")
                StatRow("FPS (sidecar)", info.vtsFps?.let { "%.2f".format(it) } ?: "-")
                StatRow("Total frames", info.totalFrames?.toString() ?: "-")
                StatRow("Keyframes", info.keyframeCount?.toString() ?: "-")
                StatRow("Mean GOP", info.gopFrames?.let { "$it frames" } ?: "-")
                StatRow("Avg bitrate", info.avgBitrateBps?.let(::formatBitrate) ?: "-")

                Spacer(Modifier.height(8.dp))
                SectionHeader("Inertial sensor")
                StatRow("Format version", info.imuVersion?.let { "TRIMU001 v$it" } ?: "-")
                StatRow("Nominal rate", info.imuSampleRateHz?.let { "$it Hz" } ?: "-")
                StatRow("Actual rate",
                    info.imuActualRateHz?.let { "%.1f Hz".format(it) } ?: "-")
                StatRow("Samples", info.imuSampleCount?.toString() ?: "-")
                StatRow("Accel range", info.accelFsName ?: "-")
                StatRow("Gyro range", info.gyroFsName ?: "-")
                StatRow("Frame-sync",
                    when (info.frameSyncEnabled) { true -> "on"; false -> "off"; null -> "-" })

                Spacer(Modifier.height(8.dp))
                SectionHeader("Frame timestamps (vts)")
                StatRow("Format version", info.vtsVersion?.let { "TRIVTS01 v$it" } ?: "-")
                StatRow("Frame count", info.vtsFrameCount?.toString() ?: "-")
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text("Close") }
        },
    )
}

@Composable
private fun SectionHeader(label: String) {
    Text(
        text = label,
        style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.SemiBold),
        modifier = Modifier.padding(top = 4.dp, bottom = 2.dp),
    )
}

@Composable
private fun StatRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(
            value,
            style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
        )
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1_000_000_000L -> "%.2f GB".format(bytes / 1e9)
    bytes >= 1_000_000L     -> "%.2f MB".format(bytes / 1e6)
    bytes >= 1_000L         -> "%.1f KB".format(bytes / 1e3)
    else                    -> "$bytes B"
}

private fun formatMs(ms: Long): String {
    val totalSec = ms / 1000
    val s = totalSec % 60
    val m = (totalSec / 60) % 60
    val h = totalSec / 3600
    val frac = ms % 1000
    return if (h > 0) "%d:%02d:%02d.%03d".format(h, m, s, frac)
    else               "%02d:%02d.%03d".format(m, s, frac)
}

private fun formatBitrate(bps: Long): String = when {
    bps >= 10_000_000L -> "%.2f Mbps".format(bps / 1e6)
    bps >= 100_000L    -> "%.0f kbps".format(bps / 1e3)
    else               -> "$bps bps"
}
