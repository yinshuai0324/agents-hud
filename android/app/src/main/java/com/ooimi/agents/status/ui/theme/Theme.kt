package com.ooimi.agents.status.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import com.ooimi.agents.status.data.LightState

// Palette tuned to the reference screenshot (deep navy background, vivid lamps).
object CCColors {
    val BgTop = Color(0xFF0A0E1A)
    val BgBottom = Color(0xFF05070D)
    val Card = Color(0xFF121826)
    val CardBorder = Color(0xFF1E2636)
    val Red = Color(0xFFFF453A)      // 出错 error
    val Orange = Color(0xFFFF9F0A)   // 待批准 notify
    val Blue = Color(0xFF3B9EFF)     // 等候 waiting (your turn)
    val Yellow = Color(0xFFFFC42E)   // 工作 working
    val Green = Color(0xFF34C759)    // 沉寂 quiet
    val RedDim = Color(0xFF2A1416)
    val YellowDim = Color(0xFF2A2410)
    val GreenDim = Color(0xFF11241A)
    val LampOff = Color(0xFF161B26)
    val TextPrimary = Color(0xFFEAF0FF)
    val TextSecondary = Color(0xFF8C97AD)
    val TextFaint = Color(0xFF5A6478)
    val TrackBg = Color(0xFF1B2230)
}

/** The signal color for each session state. Single source of truth for the UI. */
fun stateColor(state: LightState): Color = when (state) {
    LightState.ERROR -> CCColors.Red
    LightState.NOTIFY -> CCColors.Orange
    LightState.WAITING -> CCColors.Blue
    LightState.WORKING -> CCColors.Yellow
    LightState.QUIET -> CCColors.Green
}

/** Short Chinese label for each state. */
fun stateLabel(state: LightState): String = when (state) {
    LightState.ERROR -> "出错"
    LightState.NOTIFY -> "审批"
    LightState.WAITING -> "等候"
    LightState.WORKING -> "工作"
    LightState.QUIET -> "空闲"
}

private val DarkScheme = darkColorScheme(
    primary = CCColors.Green,
    background = CCColors.BgBottom,
    surface = CCColors.Card,
    onBackground = CCColors.TextPrimary,
    onSurface = CCColors.TextPrimary,
)

@Composable
fun CCSignalTheme(content: @Composable () -> Unit) {
    // Always dark by design — matches the reference panel.
    MaterialTheme(colorScheme = DarkScheme, content = content)
}
