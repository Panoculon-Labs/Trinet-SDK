package com.panoculon.trinet.app.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.FiberManualRecord
import androidx.compose.material.icons.filled.VideoLibrary
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.panoculon.trinet.app.viewmodel.DeviceStatus
import com.panoculon.trinet.app.viewmodel.DeviceViewModel

@Composable
fun HomeScreen(navController: NavController) {
    val vm: DeviceViewModel = viewModel()
    val status by vm.status.collectAsState()
    val activity = androidx.compose.ui.platform.LocalContext.current as? com.panoculon.trinet.app.MainActivity

    LaunchedEffect(Unit) {
        activity?.ensureCameraPermission()
        vm.refresh()
        activity?.setOnUsbChange { vm.refresh() }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(horizontal = 28.dp)
            .padding(top = 72.dp, bottom = 28.dp),
    ) {
        Text(
            "Trinet",
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
            "egocentric capture",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Spacer(Modifier.height(40.dp))
        DeviceStatusCard(status = status, onRequestPermission = { vm.requestPermission() })

        Spacer(Modifier.weight(1f))

        ActionTile(
            title = "Record",
            subtitle = "Capture video + IMU",
            icon = Icons.Default.FiberManualRecord,
            iconTint = Color(0xFFB85C5C),
            onClick = { navController.navigate(Routes.RECORD) },
            emphasis = true,
        )
        Spacer(Modifier.height(12.dp))
        ActionTile(
            title = "Library",
            subtitle = "Review past recordings",
            icon = Icons.Default.VideoLibrary,
            iconTint = MaterialTheme.colorScheme.primary,
            onClick = { navController.navigate(Routes.LIBRARY) },
            emphasis = false,
        )
    }
}

@Composable
private fun DeviceStatusCard(status: DeviceStatus, onRequestPermission: () -> Unit) {
    val (label, detail, dotColor, tappable) = when (status) {
        DeviceStatus.Disconnected -> StatusRowData(
            label = "No device",
            detail = "Plug in the Trinet camera over USB-C",
            dotColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            tappable = false,
        )
        is DeviceStatus.Detected -> StatusRowData(
            label = "Device detected",
            detail = "Tap to grant USB permission",
            dotColor = Color(0xFFD9A441),
            tappable = true,
        )
        is DeviceStatus.Granted -> StatusRowData(
            label = "Connected",
            detail = "${status.info.productName ?: "Trinet UVC"}",
            dotColor = MaterialTheme.colorScheme.primary,
            tappable = false,
        )
        is DeviceStatus.Error -> StatusRowData(
            label = "Error",
            detail = status.message,
            dotColor = Color(0xFFB85C5C),
            tappable = false,
        )
    }

    val pulse = rememberInfiniteTransition(label = "status-pulse")
    val alphaAnim by pulse.animateFloat(
        initialValue = 0.6f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1400), RepeatMode.Reverse),
        label = "alpha",
    )
    val effectiveDot = if (tappable) dotColor.copy(alpha = alphaAnim) else dotColor
    val containerColor by animateColorAsState(
        targetValue = if (tappable) MaterialTheme.colorScheme.primary.copy(alpha = 0.10f)
                      else MaterialTheme.colorScheme.surface,
        label = "card-bg",
    )

    Surface(
        shape = RoundedCornerShape(20.dp),
        color = containerColor,
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = tappable) { onRequestPermission() },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 18.dp, vertical = 14.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(10.dp)
                    .clip(CircleShape)
                    .background(effectiveDot),
            )
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(label,
                    style = MaterialTheme.typography.labelLarge.copy(fontWeight = FontWeight.Medium),
                    color = MaterialTheme.colorScheme.onSurface)
                Text(detail,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (tappable) {
                Icon(Icons.AutoMirrored.Default.ArrowForward, contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

private data class StatusRowData(
    val label: String,
    val detail: String,
    val dotColor: Color,
    val tappable: Boolean,
)

@Composable
private fun ActionTile(
    title: String,
    subtitle: String,
    icon: ImageVector,
    iconTint: Color,
    onClick: () -> Unit,
    emphasis: Boolean,
) {
    val bg = if (emphasis) MaterialTheme.colorScheme.primary
             else MaterialTheme.colorScheme.surface
    val fg = if (emphasis) MaterialTheme.colorScheme.onPrimary
             else MaterialTheme.colorScheme.onSurface
    val subFg = if (emphasis) MaterialTheme.colorScheme.onPrimary.copy(alpha = 0.80f)
                else MaterialTheme.colorScheme.onSurfaceVariant
    Surface(
        shape = RoundedCornerShape(22.dp),
        color = bg,
        modifier = Modifier
            .fillMaxWidth()
            .clickable { onClick() },
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(horizontal = 22.dp, vertical = 20.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(if (emphasis) fg.copy(alpha = 0.15f) else iconTint.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, contentDescription = null,
                    tint = if (emphasis) fg else iconTint,
                    modifier = Modifier.size(22.dp))
            }
            Spacer(Modifier.width(16.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleLarge, color = fg)
                Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = subFg)
            }
            Icon(Icons.AutoMirrored.Default.ArrowForward, contentDescription = null,
                tint = fg.copy(alpha = 0.6f))
        }
    }
}

/** Kept for any other screen that still calls it. */
@Composable
fun SoftButton(text: String, onClick: () -> Unit, primary: Boolean) {
    Surface(
        shape = RoundedCornerShape(24.dp),
        color = if (primary) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.surface,
        modifier = Modifier.fillMaxWidth().height(72.dp).clickable { onClick() },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(text, style = MaterialTheme.typography.titleLarge,
                color = if (primary) MaterialTheme.colorScheme.onPrimary else MaterialTheme.colorScheme.onSurface)
        }
    }
}
