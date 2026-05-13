package com.panoculon.trinet.sdk.ui.trajectory

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.panoculon.trinet.sdk.model.TriposeSample

/**
 * Three-pane trajectory display: top-down (XY) and side (XZ) orthographic
 * views in the top row, a 3-D thumbnail in the bottom row, with a footer
 * showing the latest position + filter state. Recomposes whenever
 * [historyVersion] bumps.
 */
@Composable
fun TrajectoryPanel(
    history: PoseHistory,
    historyVersion: Int,
    modifier: Modifier = Modifier,
    placeholder: String = "Waiting for VIO pose…",
) {
    // historyVersion is read here so Compose subscribes; otherwise the
    // history mutates silently and the canvas never repaints.
    val _v = historyVersion
    val latest = history.latestSample
    Column(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .height(220.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            TrajectoryView2D(
                history = history,
                plane = TrajectoryPlane.XY,
                modifier = Modifier.weight(1f).fillMaxSize(),
            )
            TrajectoryView2D(
                history = history,
                plane = TrajectoryPlane.XZ,
                modifier = Modifier.weight(1f).fillMaxSize(),
            )
        }
        Spacer(Modifier.height(8.dp))
        TrajectoryView3D(
            history = history,
            modifier = Modifier
                .fillMaxWidth()
                .height(220.dp),
        )
        Spacer(Modifier.height(8.dp))
        StatusFooter(latest, history.length, placeholder)
    }
}

@Composable
private fun StatusFooter(latest: TriposeSample?, historyLength: Int, placeholder: String) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = MaterialTheme.colorScheme.surface,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            if (latest == null) {
                Text(
                    placeholder,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
                return@Surface
            }
            Column {
                Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                    StateChip(latest.filterState, latest.isDegraded, latest.isLost)
                    Spacer(Modifier.width(10.dp))
                    Text(
                        "samples %d · tracked %d".format(historyLength, latest.numTracked),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.labelSmall,
                    )
                }
                Spacer(Modifier.height(6.dp))
                Text(
                    "x %+.2f m   y %+.2f m   z %+.2f m".format(
                        latest.positionM[0], latest.positionM[1], latest.positionM[2]
                    ),
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    "σx %.2f m   σy %.2f m   σz %.2f m".format(
                        latest.positionCovDiag[0], latest.positionCovDiag[1], latest.positionCovDiag[2]
                    ),
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun StateChip(state: Int, degraded: Boolean, lost: Boolean) {
    val (label, color) = when {
        lost -> "LOST" to androidx.compose.ui.graphics.Color(0xFFB85C5C)
        degraded -> "DEGRADED" to androidx.compose.ui.graphics.Color(0xFFD9A441)
        state == TriposeSample.STATE_TRACKING -> "TRACKING" to MaterialTheme.colorScheme.primary
        state == TriposeSample.STATE_INIT -> "INIT" to MaterialTheme.colorScheme.onSurfaceVariant
        else -> "?" to MaterialTheme.colorScheme.onSurfaceVariant
    }
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = color.copy(alpha = 0.18f),
    ) {
        Text(
            label,
            color = color,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
        )
    }
}
