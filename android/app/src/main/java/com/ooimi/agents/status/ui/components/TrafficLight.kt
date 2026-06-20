package com.ooimi.agents.status.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.lerp
import com.ooimi.agents.status.data.LightState
import com.ooimi.agents.status.ui.theme.CCColors
import com.ooimi.agents.status.ui.theme.stateColor
import kotlin.math.min

/** Lamp order, top to bottom: attention-first, matching the counter row. */
private val LAMPS = listOf(
    LightState.ERROR,
    LightState.NOTIFY,
    LightState.WAITING,
    LightState.WORKING,
    LightState.QUIET,
)

/**
 * Vertical five-lamp traffic light — one lamp per state (出错/审批/等候/工作/空闲),
 * each in its own color. The lamp for the [dominant] state is lit with a glossy
 * highlight and an outer glow. On a state change it breathes a few times and
 * then holds steady; the rest stay dimmed. When [dominant] is null (e.g. not
 * connected) every lamp stays dark. Fills its parent.
 */
@Composable
fun TrafficLight(dominant: LightState?, modifier: Modifier = Modifier) {
    // Glow multiplier for the lit lamp: breathe on a state change, then stay at 1.
    val breath = remember { Animatable(1f) }
    LaunchedEffect(dominant) {
        breath.snapTo(1f)
        repeat(3) {
            breath.animateTo(0.35f, tween(620))
            breath.animateTo(1f, tween(620))
        }
    }

    Box(modifier.fillMaxSize()) {
        Canvas(Modifier.fillMaxSize()) {
            val w = size.width
            val h = size.height
            val count = LAMPS.size
            val padY = h * 0.04f
            val padX = w * 0.16f
            val maxByW = w - padX * 2
            // Fill the full column height: lamp diameter is capped by width, then
            // the leftover height is spread as gaps so the stack spans top→bottom,
            // lining the light up with the info column beside it.
            val avail = h - padY * 2
            val diameter = min(maxByW, avail / count).coerceAtLeast(1f)
            val radius = diameter / 2f
            val cx = w / 2f
            val gap = if (count > 1) ((avail - diameter * count) / (count - 1)).coerceAtLeast(0f) else 0f
            val stackH = diameter * count + gap * (count - 1)
            val top = (h - stackH) / 2f
            val innerPad = radius * 0.45f

            // Vertical housing around the lamp stack.
            drawHousingVertical(cx, radius, top, stackH, innerPad)

            LAMPS.forEachIndexed { i, state ->
                val cy = top + radius + i * (diameter + gap)
                val center = Offset(cx, cy)
                val lit = state == dominant
                drawLamp(center, radius, stateColor(state), lit, if (lit) breath.value else 1f)
            }
        }
    }
}

private fun DrawScope.drawHousingVertical(
    cx: Float,
    radius: Float,
    top: Float,
    stackH: Float,
    innerPad: Float,
) {
    val left = cx - radius - innerPad
    val width = (radius + innerPad) * 2f
    val topY = top - innerPad
    val height = stackH + innerPad * 2f
    drawRoundRect(
        brush = Brush.verticalGradient(
            listOf(Color(0xFF20262F), Color(0xFF12161C)),
            startY = topY,
            endY = topY + height,
        ),
        topLeft = Offset(left, topY),
        size = Size(width, height),
        cornerRadius = CornerRadius(radius * 0.7f),
    )
}

private fun DrawScope.drawLamp(
    center: Offset,
    radius: Float,
    onColor: Color,
    lit: Boolean,
    glow: Float,
) {
    if (lit) {
        // `glow` (0..1) drives the whole lamp's brightness so the body itself
        // breathes, not just the halo. A floor keeps it visibly colored at the
        // dimmest point.
        val bright = glow.coerceIn(0f, 1f)
        val floor = lerp(CCColors.LampOff, onColor, 0.35f)
        val body = lerp(floor, onColor, bright)
        val edge = lerp(floor, onColor, bright * 0.8f)
        // Outer glow halo
        drawCircle(
            brush = Brush.radialGradient(
                listOf(onColor.copy(alpha = 0.55f * bright), Color.Transparent),
                center = center,
                radius = radius * 1.9f,
            ),
            radius = radius * 1.9f,
            center = center,
        )
        // Lit body with bright top-left highlight (glossy)
        drawCircle(
            brush = Brush.radialGradient(
                listOf(
                    Color.White.copy(alpha = 0.95f * bright),
                    body,
                    edge,
                ),
                center = Offset(center.x - radius * 0.32f, center.y - radius * 0.34f),
                radius = radius * 1.5f,
            ),
            radius = radius,
            center = center,
        )
    } else {
        // Dim, recessed lamp
        drawCircle(
            brush = Brush.radialGradient(
                listOf(CCColors.LampOff, Color(0xFF0C0F15)),
                center = Offset(center.x - radius * 0.25f, center.y - radius * 0.25f),
                radius = radius * 1.4f,
            ),
            radius = radius,
            center = center,
        )
        // faint tint of the lamp's color so you can tell which is which
        drawCircle(color = onColor.copy(alpha = 0.06f), radius = radius, center = center)
    }
    // Specular dot
    if (lit) {
        drawCircle(
            color = Color.White.copy(alpha = 0.5f * glow.coerceIn(0f, 1f)),
            radius = radius * 0.16f,
            center = Offset(center.x - radius * 0.34f, center.y - radius * 0.38f),
        )
    }
}
