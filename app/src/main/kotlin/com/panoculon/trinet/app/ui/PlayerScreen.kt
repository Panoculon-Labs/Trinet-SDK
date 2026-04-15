package com.panoculon.trinet.app.ui

import android.app.Activity
import android.content.pm.ActivityInfo
import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.activity.compose.BackHandler
import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Fullscreen
import androidx.compose.material.icons.filled.FullscreenExit
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.panoculon.trinet.app.data.AppPaths
import com.panoculon.trinet.app.data.RecordingActions
import com.panoculon.trinet.app.viewmodel.PlayerViewModel
import com.panoculon.trinet.sdk.playback.RecordingFolder
import com.panoculon.trinet.sdk.ui.ImuOverlayPanel
import java.io.File

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerScreen(navController: NavController, recordingId: String) {
    val vm: PlayerViewModel = viewModel()
    val sample by vm.currentSample.collectAsState()
    val frame by vm.frame.collectAsState()
    val frameCount by vm.frameCount.collectAsState()
    val isPlaying by vm.isPlaying.collectAsState()
    val quat by vm.quat.collectAsState()
    // IMPORTANT: historyVersion is read in this scope so Compose knows to
    // recompose when the ring buffer mutates. We do NOT wrap the panel in
    // key(historyVersion) — that was recreating rememberScrollState() every
    // sample, which broke scrolling during playback.
    val historyVersion by vm.historyVersion.collectAsState()
    val context = LocalContext.current
    val view = LocalView.current

    var menuOpen by remember { mutableStateOf(false) }
    var pendingDelete by remember { mutableStateOf(false) }
    var pendingRename by remember { mutableStateOf(false) }
    var displayName by remember { mutableStateOf(recordingId) }
    var fullscreen by remember { mutableStateOf(false) }

    fun folder(): RecordingFolder =
        RecordingFolder(File(AppPaths.recordingsDir(context), displayName))

    // Fullscreen: rotate to landscape, hide system bars. Reversed on exit / dispose.
    DisposableEffect(fullscreen) {
        val activity = context as? Activity
        val window = activity?.window
        if (activity != null && window != null) {
            val controller = WindowCompat.getInsetsController(window, view)
            if (fullscreen) {
                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
                controller.systemBarsBehavior =
                    WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                controller.hide(WindowInsetsCompat.Type.systemBars())
            } else {
                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                controller.show(WindowInsetsCompat.Type.systemBars())
            }
        }
        onDispose {
            if (activity != null && window != null) {
                activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
                WindowCompat.getInsetsController(window, view)
                    .show(WindowInsetsCompat.Type.systemBars())
            }
        }
    }

    // Back exits fullscreen first, then pops.
    BackHandler(enabled = fullscreen) { fullscreen = false }

    // Touch historyVersion so Compose tracks the read — without a direct read
    // in the lambda scope that calls the panel, state flow changes wouldn't
    // trigger recomposition of the subtree reading history values.
    val _hv = historyVersion

    if (fullscreen) {
        FullscreenVideo(
            onExit = { fullscreen = false },
            isPlaying = isPlaying,
            frame = frame,
            frameCount = frameCount,
            onTogglePlayPause = { vm.togglePlayPause() },
            onScrubStart = { vm.beginScrub() },
            onScrubUpdate = { vm.scrubTo(it) },
            onScrubEnd = { f, resume -> vm.endScrub(f, resume) },
            onSurface = { vm.open(displayName, it) },
        )
        return
    }

    Column(modifier = Modifier
        .fillMaxSize()
        .background(MaterialTheme.colorScheme.background)
    ) {
        TopAppBar(
            title = { Text(displayName, style = MaterialTheme.typography.titleMedium, maxLines = 1) },
            navigationIcon = {
                IconButton(onClick = { navController.popBackStack() }) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
            actions = {
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = "More")
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Share") },
                            onClick = { menuOpen = false; RecordingActions.share(context, folder()) },
                        )
                        DropdownMenuItem(
                            text = { Text("Rename") },
                            onClick = { menuOpen = false; pendingRename = true },
                        )
                        DropdownMenuItem(
                            text = { Text("Delete") },
                            onClick = { menuOpen = false; pendingDelete = true },
                        )
                    }
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.background,
                titleContentColor = MaterialTheme.colorScheme.onBackground,
            ),
        )

        VideoSurface(
            modifier = Modifier.fillMaxWidth().aspectRatio(16f / 9f),
            onSurface = { vm.open(displayName, it) },
        )

        PlayerControlBar(
            isPlaying = isPlaying,
            frame = frame,
            frameCount = frameCount,
            fps = 30,
            onTogglePlayPause = { vm.togglePlayPause() },
            onScrubStart = { vm.beginScrub() },
            onScrubUpdate = { vm.scrubTo(it) },
            onScrubEnd = { f, resume -> vm.endScrub(f, resume) },
            onFullscreen = { fullscreen = true },
        )

        ImuOverlayPanel(
            history = vm.history,
            sample = sample,
            quatXyzw = quat,
            modifier = Modifier.fillMaxWidth().weight(1f),
        )
    }

    if (pendingDelete) {
        AlertDialog(
            onDismissRequest = { pendingDelete = false },
            title = { Text("Delete recording?") },
            text = { Text("\"$displayName\" will be permanently removed.") },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = false
                    folder().delete()
                    navController.popBackStack()
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = false }) { Text("Cancel") } },
        )
    }

    if (pendingRename) {
        RenameDialogInline(
            initial = displayName,
            onDismiss = { pendingRename = false },
            onConfirm = { newName ->
                pendingRename = false
                val renamed = folder().renameTo(newName)
                if (renamed != null) displayName = renamed.dir.name
            },
        )
    }
}

@Composable
private fun VideoSurface(
    modifier: Modifier,
    onSurface: (android.view.Surface) -> Unit,
) {
    Box(modifier = modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(h: SurfaceHolder) { onSurface(h.surface) }
                        override fun surfaceChanged(h: SurfaceHolder, format: Int, w: Int, hgt: Int) {}
                        override fun surfaceDestroyed(h: SurfaceHolder) {}
                    })
                }
            },
        )
    }
}

@Composable
private fun PlayerControlBar(
    isPlaying: Boolean,
    frame: Int,
    frameCount: Int,
    fps: Int,
    onTogglePlayPause: () -> Unit,
    onScrubStart: () -> Unit,
    onScrubUpdate: (Int) -> Unit,
    onScrubEnd: (Int, Boolean) -> Unit,
    onFullscreen: () -> Unit,
) {
    // VLC-style live scrubbing: while dragging, we call scrubTo on the player
    // on each update — it decodes + renders exactly one frame at the target
    // synchronously, so the video follows the thumb. On release we run the
    // full seek path (IMU history backfill) and resume playback if we were
    // playing before.
    var dragValue by remember { mutableStateOf<Float?>(null) }
    var wasPlayingAtDragStart by remember { mutableStateOf(false) }
    val liveValue = if (frameCount > 0) frame.toFloat() / frameCount else 0f
    val sliderValue = dragValue ?: liveValue
    val displayedFrame = if (dragValue != null && frameCount > 0)
        (dragValue!! * frameCount).toInt().coerceIn(0, frameCount - 1)
    else frame
    val position = formatTimecode(displayedFrame, fps)
    val total = formatTimecode((frameCount - 1).coerceAtLeast(0), fps)

    Surface(
        color = MaterialTheme.colorScheme.surface,
        shape = RoundedCornerShape(topStart = 0.dp, topEnd = 0.dp, bottomStart = 22.dp, bottomEnd = 22.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
            Slider(
                value = sliderValue,
                onValueChange = { v ->
                    if (dragValue == null) {
                        wasPlayingAtDragStart = isPlaying
                        onScrubStart()
                    }
                    dragValue = v
                    if (frameCount > 0) {
                        onScrubUpdate((v * frameCount).toInt().coerceIn(0, frameCount - 1))
                    }
                },
                onValueChangeFinished = {
                    val finalFrame = dragValue?.let { v ->
                        (v * frameCount).toInt().coerceIn(0, frameCount - 1)
                    } ?: frame
                    dragValue = null
                    onScrubEnd(finalFrame, wasPlayingAtDragStart)
                },
                colors = SliderDefaults.colors(
                    thumbColor = MaterialTheme.colorScheme.primary,
                    activeTrackColor = MaterialTheme.colorScheme.primary,
                    inactiveTrackColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.3f),
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                PlayPauseButton(isPlaying = isPlaying, onClick = onTogglePlayPause)
                Spacer(Modifier.width(12.dp))
                Text(
                    "$position / $total",
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Spacer(Modifier.weight(1f))
                Text(
                    "frame $displayedFrame",
                    style = MaterialTheme.typography.labelSmall.copy(fontFamily = FontFamily.Monospace),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(end = 8.dp),
                )
                IconButton(onClick = onFullscreen) {
                    Icon(Icons.Default.Fullscreen, contentDescription = "Fullscreen",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }
}

@Composable
private fun PlayPauseButton(isPlaying: Boolean, onClick: () -> Unit) {
    val bg by animateColorAsState(
        targetValue = MaterialTheme.colorScheme.primary,
        label = "playpause-bg",
    )
    Box(
        modifier = Modifier
            .size(48.dp)
            .clip(CircleShape)
            .background(bg)
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
            contentDescription = if (isPlaying) "Pause" else "Play",
            tint = MaterialTheme.colorScheme.onPrimary,
        )
    }
}

@Composable
private fun FullscreenVideo(
    onExit: () -> Unit,
    isPlaying: Boolean,
    frame: Int,
    frameCount: Int,
    onTogglePlayPause: () -> Unit,
    onScrubStart: () -> Unit,
    onScrubUpdate: (Int) -> Unit,
    onScrubEnd: (Int, Boolean) -> Unit,
    onSurface: (android.view.Surface) -> Unit,
) {
    var controlsVisible by remember { mutableStateOf(true) }
    Box(modifier = Modifier.fillMaxSize().background(Color.Black).clickable { controlsVisible = !controlsVisible }) {
        AndroidView(
            modifier = Modifier.fillMaxSize(),
            factory = { ctx ->
                SurfaceView(ctx).apply {
                    holder.addCallback(object : SurfaceHolder.Callback {
                        override fun surfaceCreated(h: SurfaceHolder) { onSurface(h.surface) }
                        override fun surfaceChanged(h: SurfaceHolder, format: Int, w: Int, hgt: Int) {}
                        override fun surfaceDestroyed(h: SurfaceHolder) {}
                    })
                }
            },
        )
        if (controlsVisible) {
            // Top overlay — exit button
            Row(
                modifier = Modifier.align(Alignment.TopStart).padding(12.dp),
            ) {
                Surface(
                    shape = CircleShape,
                    color = Color(0x99000000),
                    modifier = Modifier.size(42.dp).clickable { onExit() },
                ) {
                    Box(contentAlignment = Alignment.Center) {
                        Icon(Icons.Default.FullscreenExit, contentDescription = "Exit fullscreen",
                            tint = Color.White)
                    }
                }
            }
            // Bottom overlay — slider + play/pause + time
            var dragValue by remember { mutableStateOf<Float?>(null) }
            var wasPlayingAtDragStart by remember { mutableStateOf(false) }
            val liveValue = if (frameCount > 0) frame.toFloat() / frameCount else 0f
            val sliderValue = dragValue ?: liveValue
            val displayedFrame = if (dragValue != null && frameCount > 0)
                (dragValue!! * frameCount).toInt().coerceIn(0, frameCount - 1)
            else frame
            Column(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .background(Color(0xAA000000))
                    .padding(horizontal = 16.dp, vertical = 10.dp),
            ) {
                Slider(
                    value = sliderValue,
                    onValueChange = { v ->
                        if (dragValue == null) {
                            wasPlayingAtDragStart = isPlaying
                            onScrubStart()
                        }
                        dragValue = v
                        if (frameCount > 0) {
                            onScrubUpdate((v * frameCount).toInt().coerceIn(0, frameCount - 1))
                        }
                    },
                    onValueChangeFinished = {
                        val finalFrame = dragValue?.let { v ->
                            (v * frameCount).toInt().coerceIn(0, frameCount - 1)
                        } ?: frame
                        dragValue = null
                        onScrubEnd(finalFrame, wasPlayingAtDragStart)
                    },
                    colors = SliderDefaults.colors(
                        thumbColor = Color.White,
                        activeTrackColor = Color.White,
                        inactiveTrackColor = Color.White.copy(alpha = 0.3f),
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    PlayPauseButton(isPlaying = isPlaying, onClick = onTogglePlayPause)
                    Spacer(Modifier.width(12.dp))
                    Text("${formatTimecode(displayedFrame, 30)} / ${formatTimecode((frameCount - 1).coerceAtLeast(0), 30)}",
                        style = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                        color = Color.White)
                }
            }
        }
    }
}

@Composable
private fun RenameDialogInline(
    initial: String,
    onDismiss: () -> Unit,
    onConfirm: (String) -> Unit,
) {
    var text by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Rename recording") },
        text = {
            OutlinedTextField(
                value = text,
                onValueChange = { text = it },
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onConfirm(text) },
                enabled = text.isNotBlank() && text != initial,
            ) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

private fun formatTimecode(frame: Int, fps: Int): String {
    if (fps <= 0) return "0:00"
    val totalSec = frame / fps
    val m = totalSec / 60
    val s = totalSec % 60
    return "%d:%02d".format(m, s)
}
