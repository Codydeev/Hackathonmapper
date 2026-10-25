package com.hackathonmapper.meshmapper.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** iOS system blue, the SwiftUI accent color the app uses everywhere. */
private val SystemBlue = Color(0xFF007AFF)
private val SystemBlueDark = Color(0xFF0A84FF)

// Grouped-form colors of iOS (systemGroupedBackground / secondarySystemGroupedBackground), so the
// settings sections read like the SwiftUI Form.
private val LightColors = lightColorScheme(
    primary = SystemBlue,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFD6E6FF),
    onPrimaryContainer = Color(0xFF001B3D),
    secondary = Color(0xFF5B6472),
    error = Color(0xFFFF3B30),
    background = Color(0xFFF2F2F7),
    onBackground = Color.Black,
    surface = Color(0xFFF2F2F7),
    onSurface = Color.Black,
    surfaceVariant = Color(0xFFE5E5EA),
    onSurfaceVariant = Color(0xFF6C6C70),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color.White,
    surfaceContainer = Color(0xFFF9F9FB),
    surfaceContainerHigh = Color.White,
    surfaceContainerHighest = Color(0xFFE5E5EA),
    outlineVariant = Color(0xFFD1D1D6),
)

private val DarkColors = darkColorScheme(
    primary = SystemBlueDark,
    onPrimary = Color.White,
    primaryContainer = Color(0xFF0B3A73),
    onPrimaryContainer = Color(0xFFD6E6FF),
    secondary = Color(0xFFAEB6C2),
    error = Color(0xFFFF453A),
    background = Color.Black,
    onBackground = Color.White,
    surface = Color.Black,
    onSurface = Color.White,
    surfaceVariant = Color(0xFF2C2C2E),
    onSurfaceVariant = Color(0xFF98989F),
    surfaceContainerLowest = Color(0xFF1C1C1E),
    surfaceContainerLow = Color(0xFF1C1C1E),
    surfaceContainer = Color(0xFF161618),
    surfaceContainerHigh = Color(0xFF1C1C1E),
    surfaceContainerHighest = Color(0xFF2C2C2E),
    outlineVariant = Color(0xFF38383A),
)

/** Light and dark like the iOS app; dynamic (wallpaper) colors are off so every phone looks the same. */
@Composable
fun MeshMapperTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (darkTheme) DarkColors else LightColors, content = content)
}
