package com.panoculon.trinet.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// Phase 1: system fonts. Phase 6 swaps in Lora (display) + Inter (body).
val TrinetTypography = Typography(
    displayLarge = TextStyle(fontWeight = FontWeight.Light, fontSize = 48.sp, letterSpacing = (-0.5).sp),
    displayMedium = TextStyle(fontWeight = FontWeight.Light, fontSize = 36.sp, letterSpacing = (-0.25).sp),
    headlineMedium = TextStyle(fontWeight = FontWeight.Normal, fontSize = 24.sp),
    titleLarge = TextStyle(fontWeight = FontWeight.Medium, fontSize = 20.sp),
    bodyLarge = TextStyle(fontWeight = FontWeight.Normal, fontSize = 16.sp, lineHeight = 24.sp),
    bodyMedium = TextStyle(fontWeight = FontWeight.Normal, fontSize = 14.sp, lineHeight = 20.sp),
    labelLarge = TextStyle(fontWeight = FontWeight.Medium, fontSize = 14.sp, letterSpacing = 0.5.sp),
)
