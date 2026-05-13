package com.panoculon.trinet.sdk.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.panoculon.trinet.sdk.model.ImuSample
import kotlin.math.sqrt

private val AxisColors = listOf(Color(0xFFD16C6C), Color(0xFF7DA05B), Color(0xFF6A92C8))

/**
 * Polished sidebar that visualises the IMU history window and the Madgwick-fused
 * orientation. Scrollable so it fits below video + controls without cramming.
 *
 * The firmware emits raw accel/gyro/mag only. Orientation is computed by the
 * caller (a Madgwick filter in the viewmodel) and handed in via [quatXyzw].
 */
@Composable
fun ImuOverlayPanel(
    history: ImuHistory,
    sample: ImuSample?,
    quatXyzw: FloatArray,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        OrientationHeader(quatXyzw = quatXyzw, sample = sample)

        SensorCard(
            title = "Accelerometer",
            unit = "m/s²",
            values = sample?.accel,
            magnitude = sample?.accel?.let { mag3(it) },
            history = TriAxis(history.accelX(), history.accelY(), history.accelZ()),
        )
        SensorCard(
            title = "Gyroscope",
            unit = "rad/s",
            values = sample?.gyro,
            magnitude = sample?.gyro?.let { mag3(it) },
            history = TriAxis(history.gyroX(), history.gyroY(), history.gyroZ()),
        )
        SensorCard(
            title = "Magnetometer",
            unit = "µT",
            values = sample?.mag,
            magnitude = sample?.mag?.let { mag3(it) },
            history = TriAxis(history.magX(), history.magY(), history.magZ()),
        )
    }
}

@Composable
private fun OrientationHeader(quatXyzw: FloatArray, sample: ImuSample?) {
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OrientationCube(quatXyzw = quatXyzw, modifier = Modifier.size(88.dp))
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    "Orientation · Madgwick 6-DOF",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "quat (x y z w)",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "%+.3f  %+.3f  %+.3f  %+.3f".format(
                        quatXyzw[0], quatXyzw[1], quatXyzw[2], quatXyzw[3],
                    ),
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.height(4.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    Stat("temp", sample?.let { "%.1f°C".format(it.tempC) } ?: "—")
                    Stat("Δfsync", sample?.let { "%.0f µs".format(it.fsyncDelayUs) } ?: "—")
                }
            }
        }
    }
}

private data class TriAxis(val x: FloatArray, val y: FloatArray, val z: FloatArray)

@Composable
private fun SensorCard(
    title: String,
    unit: String,
    values: FloatArray?,
    magnitude: Float?,
    history: TriAxis,
) {
    Surface(
        shape = RoundedCornerShape(18.dp),
        color = MaterialTheme.colorScheme.background,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.titleSmall,
                    color = MaterialTheme.colorScheme.onSurface)
                Spacer(Modifier.weight(1f))
                Text(unit, style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Spacer(Modifier.height(6.dp))

            // Numeric readouts (X / Y / Z / |v|)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                AxisReadout("x", values?.getOrNull(0), AxisColors[0], Modifier.weight(1f))
                AxisReadout("y", values?.getOrNull(1), AxisColors[1], Modifier.weight(1f))
                AxisReadout("z", values?.getOrNull(2), AxisColors[2], Modifier.weight(1f))
                AxisReadout("|v|", magnitude, MaterialTheme.colorScheme.onSurfaceVariant, Modifier.weight(1f))
            }

            Spacer(Modifier.height(8.dp))

            // Three stacked axis plots, tiny and clean
            TimeSeriesPlot(values = history.x, color = AxisColors[0],
                modifier = Modifier.fillMaxWidth().height(40.dp))
            Spacer(Modifier.height(2.dp))
            TimeSeriesPlot(values = history.y, color = AxisColors[1],
                modifier = Modifier.fillMaxWidth().height(40.dp))
            Spacer(Modifier.height(2.dp))
            TimeSeriesPlot(values = history.z, color = AxisColors[2],
                modifier = Modifier.fillMaxWidth().height(40.dp))
        }
    }
}

@Composable
private fun AxisReadout(label: String, value: Float?, accent: Color, modifier: Modifier = Modifier) {
    Column(modifier = modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(modifier = Modifier.size(6.dp).clip(CircleShape).background(accent))
            Spacer(Modifier.width(5.dp))
            Text(label, style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Text(
            text = value?.let { "%+.2f".format(it) } ?: "—",
            style = MaterialTheme.typography.bodyMedium.copy(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
            ),
            color = MaterialTheme.colorScheme.onSurface,
        )
    }
}

@Composable
private fun Stat(label: String, value: String) {
    Column {
        Text(label, style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurface)
    }
}

private fun mag3(v: FloatArray): Float =
    sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
