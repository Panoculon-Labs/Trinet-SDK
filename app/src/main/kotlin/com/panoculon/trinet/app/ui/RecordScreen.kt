package com.panoculon.trinet.app.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.panoculon.trinet.app.viewmodel.RecordUiState
import com.panoculon.trinet.app.viewmodel.RecordViewModel
import com.panoculon.trinet.sdk.ui.LivePreview

/**
 * Full-bleed camera view with a minimalist HUD, a modern record shutter, and
 * frosted status chips. The live preview fills the screen; chrome sits on top
 * with just enough contrast to stay legible against arbitrary video content.
 */
@Composable
fun RecordScreen(navController: NavController) {
    val vm: RecordViewModel = viewModel()
    val ui by vm.ui.collectAsState()
    val session = vm.activeSession

    LaunchedEffect(Unit) { if (ui is RecordUiState.Idle) vm.connect() }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        when {
            session != null && (ui is RecordUiState.Streaming || ui is RecordUiState.Recording) -> {
                LivePreview(
                    frames = session.frames,
                    width = vm.sessionConfig.width,
                    height = vm.sessionConfig.height,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            else -> StatePlaceholder(ui = ui)
        }

        // Top HUD: back button + centered recording pill
        Row(
            modifier = Modifier
                .align(Alignment.TopCenter)
                .fillMaxWidth()
                .padding(top = 14.dp, start = 10.dp, end = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            FrostedIconButton(
                onClick = { navController.popBackStack() },
                icon = { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back",
                    tint = Color.White) },
            )
            Spacer(Modifier.weight(1f))
            RecordingPill(ui)
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(42.dp))   // symmetric gutter
        }

        // Stats card (bottom-left)
        AnimatedVisibility(
            visible = ui is RecordUiState.Streaming || ui is RecordUiState.Recording,
            modifier = Modifier.align(Alignment.BottomStart).padding(24.dp),
            enter = fadeIn(), exit = fadeOut(),
        ) {
            StatsCard(ui)
        }

        // Shutter (bottom-center)
        RecordShutter(
            ui = ui,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(bottom = 36.dp),
            onToggle = {
                when (ui) {
                    is RecordUiState.Streaming -> vm.startRecording()
                    is RecordUiState.Recording -> vm.stopRecording()
                    else -> Unit
                }
            },
        )
    }
}

@Composable
private fun StatePlaceholder(ui: RecordUiState) {
    Box(
        modifier = Modifier.fillMaxSize().background(Color(0xFF101114)),
        contentAlignment = Alignment.Center,
    ) {
        when (ui) {
            RecordUiState.Idle, RecordUiState.Connecting -> {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    ConnectingOrb()
                    Spacer(Modifier.height(18.dp))
                    Text(
                        if (ui is RecordUiState.Connecting) "Connecting to device…" else "Preparing…",
                        color = Color(0xFFE8E5DE),
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text("Make sure the Trinet camera is plugged in over USB-C",
                        color = Color(0xFF8E8B82),
                        style = MaterialTheme.typography.bodySmall)
                }
            }
            is RecordUiState.Error -> {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = 32.dp),
                ) {
                    Text("⚠", color = Color(0xFFB85C5C),
                        style = MaterialTheme.typography.displayMedium)
                    Spacer(Modifier.height(12.dp))
                    Text("Couldn't start streaming",
                        color = Color(0xFFE8E5DE),
                        style = MaterialTheme.typography.titleMedium)
                    Spacer(Modifier.height(6.dp))
                    Text(ui.message,
                        color = Color(0xFF8E8B82),
                        style = MaterialTheme.typography.bodySmall)
                }
            }
            else -> Unit
        }
    }
}

@Composable
private fun ConnectingOrb() {
    val t = rememberInfiniteTransition(label = "orb")
    val s by t.animateFloat(
        initialValue = 0.9f, targetValue = 1.15f,
        animationSpec = infiniteRepeatable(tween(1100), RepeatMode.Reverse),
        label = "scale",
    )
    Box(
        modifier = Modifier
            .size(48.dp)
            .scale(s)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.4f)),
    )
}

@Composable
private fun RecordingPill(ui: RecordUiState) {
    val isRecording = ui is RecordUiState.Recording
    val (label, dotColor) = when {
        isRecording -> "REC  ${formatDuration((ui as RecordUiState.Recording).durationMs)}" to Color(0xFFE05454)
        ui is RecordUiState.Streaming -> "LIVE" to Color(0xFF6DB16D)
        ui is RecordUiState.Connecting -> "CONNECTING" to Color(0xFFD9A441)
        ui is RecordUiState.Error -> "ERROR" to Color(0xFFB85C5C)
        else -> return
    }
    val t = rememberInfiniteTransition(label = "rec-dot")
    val alpha by t.animateFloat(
        initialValue = 0.5f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(700), RepeatMode.Reverse),
        label = "dot-alpha",
    )
    Surface(
        shape = RoundedCornerShape(999.dp),
        color = Color(0x66000000),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(if (isRecording) dotColor.copy(alpha = alpha) else dotColor),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                label,
                color = Color.White,
                style = MaterialTheme.typography.labelLarge.copy(
                    fontWeight = FontWeight.SemiBold,
                    fontFamily = if (isRecording) FontFamily.Monospace else FontFamily.Default,
                ),
            )
        }
    }
}

@Composable
private fun StatsCard(ui: RecordUiState) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = Color(0x66000000),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            when (ui) {
                is RecordUiState.Streaming -> {
                    StatRow("IMU", "${ui.sampleRateHz} Hz")
                    StatRow("Video", "1080p · 30 fps")
                }
                is RecordUiState.Recording -> {
                    StatRow("Frames", "${ui.frameCount}")
                    StatRow("Samples", "${ui.sampleCount}")
                    StatRow("IMU rate",
                        if (ui.durationMs > 0)
                            "%.0f Hz".format(ui.sampleCount * 1000.0 / ui.durationMs)
                        else "—")
                }
                else -> Unit
            }
        }
    }
}

@Composable
private fun StatRow(label: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(vertical = 1.dp)) {
        Text(label, color = Color(0xFF8E8B82),
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.width(62.dp))
        Text(value, color = Color.White,
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Medium,
            ))
    }
}

@Composable
private fun RecordShutter(ui: RecordUiState, modifier: Modifier, onToggle: () -> Unit) {
    val isRecording = ui is RecordUiState.Recording
    val enabled = ui is RecordUiState.Streaming || isRecording

    val t = rememberInfiniteTransition(label = "shutter-pulse")
    val pulse by t.animateFloat(
        initialValue = 1f, targetValue = 1.08f,
        animationSpec = infiniteRepeatable(tween(900), RepeatMode.Reverse),
        label = "scale",
    )
    val outerScale = if (isRecording) pulse else 1f

    Box(
        modifier = modifier.size(80.dp).scale(outerScale),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .fillMaxSize()
                .clip(CircleShape)
                .background(Color(0x33FFFFFF))
                .clickable(enabled = enabled) { onToggle() },
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier
                    .size(68.dp)
                    .clip(CircleShape)
                    .background(Color(0x22FFFFFF)),
                contentAlignment = Alignment.Center,
            ) {
                val innerSize = if (isRecording) 28.dp else 58.dp
                val innerShape = if (isRecording) RoundedCornerShape(6.dp) else CircleShape
                Box(
                    modifier = Modifier
                        .size(innerSize)
                        .clip(innerShape)
                        .background(Color(0xFFE05454)),
                )
            }
        }
    }
}

@Composable
private fun FrostedIconButton(onClick: () -> Unit, icon: @Composable () -> Unit) {
    Surface(
        shape = CircleShape,
        color = Color(0x66000000),
        modifier = Modifier.size(42.dp).clickable { onClick() },
    ) { Box(contentAlignment = Alignment.Center) { icon() } }
}

internal fun formatDuration(ms: Long): String {
    val total = ms / 1000
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    val cs = (ms % 1000) / 10
    return if (h > 0) "%d:%02d:%02d.%02d".format(h, m, s, cs)
           else "%02d:%02d.%02d".format(m, s, cs)
}
