package com.panoculon.trinet.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.RestartAlt
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.NavController
import com.panoculon.trinet.app.viewmodel.TrajectoryUiState
import com.panoculon.trinet.app.viewmodel.TrajectoryViewModel
import com.panoculon.trinet.sdk.ui.trajectory.TrajectoryPanel

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrajectoryScreen(navController: NavController) {
    val vm: TrajectoryViewModel = viewModel()
    val ui by vm.ui.collectAsState()
    val historyVersion by vm.historyVersion.collectAsState()

    LaunchedEffect(Unit) { if (ui is TrajectoryUiState.Idle) vm.connect() }

    Column(modifier = Modifier
        .fillMaxSize()
        .background(MaterialTheme.colorScheme.background)
    ) {
        TopAppBar(
            title = {
                Column {
                    Text("Trajectory", style = MaterialTheme.typography.titleMedium)
                    Text(
                        statusLabel(ui),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
            navigationIcon = {
                IconButton(onClick = { navController.popBackStack() }) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                }
            },
            actions = {
                IconButton(onClick = { vm.reset() }) {
                    Icon(Icons.Default.RestartAlt, contentDescription = "Reset trajectory")
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = MaterialTheme.colorScheme.background,
                titleContentColor = MaterialTheme.colorScheme.onBackground,
            ),
        )

        when (ui) {
            is TrajectoryUiState.Idle, TrajectoryUiState.Connecting -> {
                PlaceholderState(label = "Connecting to camera…",
                    detail = "Make sure the Trinet camera is plugged in over USB-C")
            }
            is TrajectoryUiState.Error -> {
                val msg = (ui as TrajectoryUiState.Error).message
                PlaceholderState(label = "Couldn't start streaming",
                    detail = msg, error = true)
            }
            is TrajectoryUiState.Streaming -> {
                TrajectoryPanel(
                    history = vm.history,
                    historyVersion = historyVersion,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                )
            }
        }
    }
}

@Composable
private fun PlaceholderState(label: String, detail: String, error: Boolean = false) {
    Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(32.dp)
        ) {
            if (error) {
                Text("⚠", color = Color(0xFFB85C5C),
                    style = MaterialTheme.typography.displayMedium)
                Spacer(Modifier.height(12.dp))
            }
            Text(label,
                color = MaterialTheme.colorScheme.onBackground,
                style = MaterialTheme.typography.titleMedium)
            Spacer(Modifier.height(4.dp))
            Text(detail,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall)
        }
    }
}

private fun statusLabel(ui: TrajectoryUiState): String = when (ui) {
    TrajectoryUiState.Idle -> "idle"
    TrajectoryUiState.Connecting -> "connecting"
    is TrajectoryUiState.Streaming -> "live · ${ui.samplesSeen} samples"
    is TrajectoryUiState.Error -> "error"
}
