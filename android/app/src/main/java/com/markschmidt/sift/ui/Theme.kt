package com.markschmidt.sift.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/** Sift's teal (the Apple apps' accent color), on calm neutral surfaces. */
private val Teal = Color(0xFF1F6F7A)
private val TealLight = Color(0xFF6AC4CF)

private val LightColors = lightColorScheme(
    primary = Teal,
    onPrimary = Color.White,
    primaryContainer = Color(0xFFCDE9EC),
    onPrimaryContainer = Color(0xFF00363D),
    secondary = Color(0xFF4A6366),
    secondaryContainer = Color(0xFFDDE7E8),
    background = Color(0xFFF6F7F7),
    surface = Color(0xFFF6F7F7),
    surfaceContainerLowest = Color.White,
    surfaceContainerLow = Color(0xFFFFFFFF),
    surfaceContainer = Color(0xFFEFF1F1),
    surfaceContainerHigh = Color(0xFFE9ECEC),
    surfaceContainerHighest = Color(0xFFE3E6E6),
    inversePrimary = TealLight,
    error = Color(0xFFC62828),
)

private val DarkColors = darkColorScheme(
    primary = TealLight,
    onPrimary = Color(0xFF00363D),
    primaryContainer = Color(0xFF0E4F57),
    onPrimaryContainer = Color(0xFFCDE9EC),
    secondary = Color(0xFFB1CBCE),
    secondaryContainer = Color(0xFF334B4E),
    background = Color(0xFF111314),
    surface = Color(0xFF111314),
    surfaceContainerLowest = Color(0xFF0C0E0F),
    surfaceContainerLow = Color(0xFF1C1C1E),
    surfaceContainer = Color(0xFF1E2122),
    surfaceContainerHigh = Color(0xFF282B2C),
    surfaceContainerHighest = Color(0xFF333637),
    inversePrimary = Teal,
    error = Color(0xFFFF8A80),
)

@Composable
fun SiftTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (isSystemInDarkTheme()) DarkColors else LightColors, content = content)
}

/** For destructive choices (Screen Out, Trash). */
val Destructive: Color @Composable get() = MaterialTheme.colorScheme.error

/** The orange the Apple apps use for pins and blocked spy pixels. */
val Warning = Color(0xFFE8890C)
