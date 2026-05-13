package com.panoculon.trinet.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.panoculon.trinet.app.data.RecordingActions
import com.panoculon.trinet.app.viewmodel.LibraryViewModel
import com.panoculon.trinet.sdk.playback.RecordingFolder
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun LibraryScreen(navController: NavController) {
    val vm: LibraryViewModel = viewModel()
    val items by vm.items.collectAsState()

    var pendingDelete by remember { mutableStateOf<RecordingFolder?>(null) }
    var pendingRename by remember { mutableStateOf<RecordingFolder?>(null) }
    var pendingBulkDelete by remember { mutableStateOf(false) }
    val selected = remember { mutableStateListOf<String>() }
    val inSelectionMode = selected.isNotEmpty()

    LaunchedEffect(Unit) { vm.refresh() }

    // Back exits selection mode first
    BackHandler(enabled = inSelectionMode) { selected.clear() }

    Scaffold(
        topBar = {
            if (inSelectionMode) {
                SelectionTopBar(
                    count = selected.size,
                    onClear = { selected.clear() },
                    onDelete = { pendingBulkDelete = true },
                )
            } else {
                TopAppBar(
                    title = {
                        Column {
                            Text("Library", style = MaterialTheme.typography.titleLarge)
                            Text(
                                "${items.size} recording${if (items.size == 1) "" else "s"}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    },
                    navigationIcon = {
                        IconButton(onClick = { navController.popBackStack() }) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                        }
                    },
                    colors = TopAppBarDefaults.topAppBarColors(
                        containerColor = MaterialTheme.colorScheme.background,
                        titleContentColor = MaterialTheme.colorScheme.onBackground,
                    ),
                )
            }
        },
        containerColor = MaterialTheme.colorScheme.background,
    ) { padding ->
        if (items.isEmpty()) {
            Box(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("No recordings yet",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface)
                    Spacer(Modifier.height(6.dp))
                    Text("Capture one from the Record screen.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        } else {
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(items, key = { it.dir.name }) { folder ->
                    LibraryRow(
                        folder = folder,
                        selected = selected.contains(folder.dir.name),
                        selectionActive = inSelectionMode,
                        onOpen = {
                            if (inSelectionMode) {
                                toggleSelection(selected, folder.dir.name)
                            } else {
                                navController.navigate(Routes.player(folder.dir.name))
                            }
                        },
                        onLongPress = { toggleSelection(selected, folder.dir.name) },
                        onRename = { pendingRename = folder },
                        onDelete = { pendingDelete = folder },
                    )
                }
            }
        }
    }

    pendingDelete?.let { folder ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete recording?") },
            text = { Text("\"${folder.dir.name}\" will be permanently removed.") },
            confirmButton = {
                TextButton(onClick = { vm.delete(folder); pendingDelete = null }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Cancel") } },
        )
    }

    pendingRename?.let { folder ->
        RenameDialog(
            initial = folder.dir.name,
            onDismiss = { pendingRename = null },
            onConfirm = { newName -> vm.rename(folder, newName); pendingRename = null },
        )
    }

    if (pendingBulkDelete) {
        val n = selected.size
        AlertDialog(
            onDismissRequest = { pendingBulkDelete = false },
            title = { Text("Delete $n recording${if (n == 1) "" else "s"}?") },
            text = { Text("This cannot be undone.") },
            confirmButton = {
                TextButton(onClick = {
                    // Snapshot then clear so deletion doesn't mutate the iterated list.
                    val names = selected.toList()
                    selected.clear()
                    val all = items.associateBy { it.dir.name }
                    for (n2 in names) all[n2]?.let { vm.delete(it) }
                    pendingBulkDelete = false
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { pendingBulkDelete = false }) { Text("Cancel") } },
        )
    }
}

private fun toggleSelection(selected: MutableList<String>, name: String) {
    if (selected.contains(name)) selected.remove(name) else selected.add(name)
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SelectionTopBar(count: Int, onClear: () -> Unit, onDelete: () -> Unit) {
    TopAppBar(
        title = { Text("$count selected", style = MaterialTheme.typography.titleMedium) },
        navigationIcon = {
            IconButton(onClick = onClear) {
                Icon(Icons.Default.Close, contentDescription = "Cancel selection")
            }
        },
        actions = {
            IconButton(onClick = onDelete) {
                Icon(Icons.Default.Delete, contentDescription = "Delete selected",
                    tint = MaterialTheme.colorScheme.error)
            }
        },
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = MaterialTheme.colorScheme.primary.copy(alpha = 0.15f),
            titleContentColor = MaterialTheme.colorScheme.onBackground,
        ),
    )
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun LibraryRow(
    folder: RecordingFolder,
    selected: Boolean,
    selectionActive: Boolean,
    onOpen: () -> Unit,
    onLongPress: () -> Unit,
    onRename: () -> Unit,
    onDelete: () -> Unit,
) {
    val context = LocalContext.current
    val sizeBytes = folder.video.length()
    val sizeLabel = formatSize(sizeBytes)
    val ts = folder.video.lastModified()
    val relative = relativeTime(ts)
    val absolute = SimpleDateFormat("MMM d, HH:mm", Locale.US).format(Date(ts))
    var menuOpen by remember { mutableStateOf(false) }

    val surfaceColor =
        if (selected) MaterialTheme.colorScheme.primary.copy(alpha = 0.18f)
        else MaterialTheme.colorScheme.surface

    Surface(
        shape = RoundedCornerShape(18.dp),
        color = surfaceColor,
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                onClick = onOpen,
                onLongClick = onLongPress,
            ),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(start = 14.dp, end = 4.dp, top = 12.dp, bottom = 12.dp),
        ) {
            // Leading: checkmark badge if selected; else play-badge.
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .background(
                        if (selected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.primary.copy(alpha = 0.15f)
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = if (selected) Icons.Default.Check else Icons.Default.PlayArrow,
                    contentDescription = null,
                    tint = if (selected) MaterialTheme.colorScheme.onPrimary
                           else MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(22.dp),
                )
            }

            Spacer(Modifier.width(14.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(folder.dir.name,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1)
                Text("$relative · $absolute · $sizeLabel",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1)
            }

            // Overflow menu hidden while selection is active (use top bar delete).
            if (!selectionActive) {
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(Icons.Default.MoreVert, contentDescription = "More",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text("Share") },
                            onClick = { menuOpen = false; RecordingActions.share(context, folder) },
                        )
                        DropdownMenuItem(
                            text = { Text("Rename") },
                            onClick = { menuOpen = false; onRename() },
                        )
                        DropdownMenuItem(
                            text = { Text("Delete") },
                            onClick = { menuOpen = false; onDelete() },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun RenameDialog(
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

private fun formatSize(bytes: Long): String {
    val kb = bytes / 1024.0
    val mb = kb / 1024.0
    val gb = mb / 1024.0
    return when {
        gb >= 1 -> "%.2f GB".format(gb)
        mb >= 1 -> "%.1f MB".format(mb)
        else -> "%d KB".format(kb.toLong())
    }
}

private fun relativeTime(epochMs: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - epochMs
    if (diff < 0) return "just now"
    val sec = TimeUnit.MILLISECONDS.toSeconds(diff)
    val min = TimeUnit.MILLISECONDS.toMinutes(diff)
    val hr = TimeUnit.MILLISECONDS.toHours(diff)
    val day = TimeUnit.MILLISECONDS.toDays(diff)
    return when {
        sec < 60 -> "just now"
        min < 60 -> "${min}m ago"
        hr < 24 -> "${hr}h ago"
        day < 7 -> "${day}d ago"
        else -> SimpleDateFormat("MMM d", Locale.US).format(Date(epochMs))
    }
}
