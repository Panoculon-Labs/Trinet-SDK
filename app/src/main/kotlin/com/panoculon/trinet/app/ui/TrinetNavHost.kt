package com.panoculon.trinet.app.ui

import androidx.compose.runtime.Composable
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController

object Routes {
    const val HOME = "home"
    const val RECORD = "record"
    const val LIBRARY = "library"
    const val PLAYER = "player/{recordingId}"
    fun player(id: String) = "player/$id"
}

@Composable
fun TrinetNavHost() {
    val navController = rememberNavController()
    NavHost(navController = navController, startDestination = Routes.HOME) {
        composable(Routes.HOME) { HomeScreen(navController) }
        composable(Routes.RECORD) { RecordScreen(navController) }
        composable(Routes.LIBRARY) { LibraryScreen(navController) }
        composable(Routes.PLAYER) { backStack ->
            val id = backStack.arguments?.getString("recordingId").orEmpty()
            PlayerScreen(navController, recordingId = id)
        }
    }
}
