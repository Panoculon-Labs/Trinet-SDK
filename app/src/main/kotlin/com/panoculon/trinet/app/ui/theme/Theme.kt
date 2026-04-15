package com.panoculon.trinet.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable

private val LightColors = lightColorScheme(
    primary = SageLight,
    onPrimary = PaperLight,
    background = PaperLight,
    onBackground = InkLight,
    surface = SurfaceLight,
    onSurface = InkLight,
    onSurfaceVariant = MutedLight,
)

private val DarkColors = darkColorScheme(
    primary = SageDark,
    onPrimary = PaperDark,
    background = PaperDark,
    onBackground = InkDark,
    surface = SurfaceDark,
    onSurface = InkDark,
    onSurfaceVariant = MutedDark,
)

@Composable
fun TrinetTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = TrinetTypography,
        content = content,
    )
}
