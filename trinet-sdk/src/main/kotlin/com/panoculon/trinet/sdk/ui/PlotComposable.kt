package com.panoculon.trinet.sdk.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.dp

/**
 * Lightweight scrolling time-series plot. Caller passes a window of samples
 * (oldest → newest) for a single channel. Suitable for accel/gyro magnitudes.
 */
@Composable
fun TimeSeriesPlot(
    values: FloatArray,
    modifier: Modifier = Modifier,
    color: Color = MaterialTheme.colorScheme.primary,
    minY: Float? = null,
    maxY: Float? = null,
    label: String? = null,
) {
    Box(modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            if (values.size < 2) return@Canvas
            val lo = minY ?: values.min()
            val hi = maxY ?: values.max()
            val range = (hi - lo).coerceAtLeast(1e-6f)
            val stepX = size.width / (values.size - 1).toFloat()

            val path = Path()
            for (i in values.indices) {
                val y = size.height - ((values[i] - lo) / range) * size.height
                val x = i * stepX
                if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            }
            drawPath(path = path, color = color, style = Stroke(width = 2f))

            // Zero baseline if the range crosses zero
            if (lo < 0f && hi > 0f) {
                val y0 = size.height - ((0f - lo) / range) * size.height
                drawLine(
                    color = color.copy(alpha = 0.25f),
                    start = Offset(0f, y0),
                    end = Offset(size.width, y0),
                    strokeWidth = 1f,
                )
            }
        }
        if (label != null) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(4.dp),
            )
        }
    }
}

/** Container that draws three stacked plots for a 3-axis channel (X, Y, Z). */
@Composable
fun TripleAxisPlot(
    x: FloatArray,
    y: FloatArray,
    z: FloatArray,
    modifier: Modifier = Modifier,
    label: String? = null,
) {
    androidx.compose.foundation.layout.Column(modifier = modifier.fillMaxWidth()) {
        if (label != null) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 4.dp, top = 4.dp, bottom = 2.dp),
            )
        }
        TimeSeriesPlot(values = x, modifier = Modifier.fillMaxWidth().height(40.dp), color = Color(0xFFB85C5C))
        TimeSeriesPlot(values = y, modifier = Modifier.fillMaxWidth().height(40.dp), color = Color(0xFF6B7A4B))
        TimeSeriesPlot(values = z, modifier = Modifier.fillMaxWidth().height(40.dp), color = Color(0xFF5C7AA8))
    }
}
