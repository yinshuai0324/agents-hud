package com.ooimi.agents.status.ui.components

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ooimi.agents.status.ui.theme.CCColors

/**
 * Plan usage panel: a plan badge + the 5-hour session limit, plus the weekly
 * limit when Claude provides it. Percentages are Claude's real numbers when
 * [live] is true; otherwise a local estimate (tagged accordingly).
 */
@Composable
fun UsageBar(
    plan: String,
    fivePercent: Int,
    fiveResetMin: Int,
    live: Boolean,
    sevenPercent: Int?,
    sevenResetMin: Int,
    todayTokens: Long,
    sevenDayTokens: Long,
    currentModel: String,
    modifier: Modifier = Modifier,
) {
    Column(modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        // Header: "您的套餐信息" + the plan as a tag + a live/estimate tag.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "您的套餐信息",
                color = CCColors.TextSecondary,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
            )
            if (plan.isNotEmpty()) {
                Spacer(Modifier.width(8.dp))
                Pill(text = plan, fg = CCColors.TextPrimary, bg = CCColors.Card)
            }
            Spacer(Modifier.weight(1f))
            Pill(
                text = if (live) "实时" else "等待上报",
                fg = if (live) CCColors.Green else CCColors.TextFaint,
                bg = if (live) CCColors.GreenDim else CCColors.Card,
            )
        }

        if (live) {
            Spacer(Modifier.height(10.dp))
            UsageRow(label = "5 小时", percent = fivePercent, resetMin = fiveResetMin, big = true)
            if (sevenPercent != null) {
                Spacer(Modifier.height(10.dp))
                UsageRow(label = "7 天", percent = sevenPercent, resetMin = sevenResetMin, big = false)
            }
        } else {
            // No real usage yet — show a placeholder instead of a bogus local estimate.
            Spacer(Modifier.height(10.dp))
            Text(
                text = "5 小时 / 7 天用量 · 等待 statusLine 上报…",
                color = CCColors.TextFaint,
                fontSize = 13.sp,
            )
        }

        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "今日消耗",
                color = CCColors.TextSecondary,
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = formatTokens(todayTokens) + " tokens",
                color = CCColors.TextPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }

        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = "近 7 天",
                color = CCColors.TextSecondary,
                fontSize = 13.sp,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = formatTokens(sevenDayTokens) + " tokens",
                color = CCColors.TextPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }

        if (currentModel.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "当前模型",
                    color = CCColors.TextSecondary,
                    fontSize = 13.sp,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    text = currentModel,
                    color = CCColors.TextPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}

private fun formatTokens(t: Long): String = when {
    t >= 1_000_000 -> String.format("%.1fM", t / 1_000_000.0)
    t >= 1_000 -> String.format("%.1fk", t / 1_000.0)
    else -> t.toString()
}

@Composable
private fun UsageRow(label: String, percent: Int, resetMin: Int, big: Boolean) {
    val pct = percent.coerceIn(0, 100)
    val animPct by animateFloatAsState(pct / 100f, tween(600), label = "pct-$label")
    val barColor by animateColorAsState(
        when {
            pct >= 85 -> CCColors.Red
            pct >= 60 -> CCColors.Yellow
            else -> CCColors.Green
        },
        label = "barColor-$label",
    )
    val titleSize = if (big) 16.sp else 13.sp
    val barH = 7.dp

    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(
            buildString { append(label); append(" · "); append(pct); append("%") },
            color = CCColors.TextPrimary,
            fontSize = titleSize,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = remainingText(resetMin),
            color = CCColors.TextSecondary,
            fontSize = if (big) 13.sp else 12.sp,
            fontWeight = FontWeight.Medium,
        )
    }
    Box(
        Modifier
            .padding(top = 8.dp)
            .fillMaxWidth()
            .height(barH)
            .clip(RoundedCornerShape(barH / 2))
            .background(CCColors.TrackBg),
    ) {
        Box(
            Modifier
                .fillMaxWidth(animPct)
                .fillMaxHeight()
                .clip(RoundedCornerShape(barH / 2))
                .background(Brush.horizontalGradient(listOf(barColor.copy(alpha = 0.85f), barColor))),
        )
    }
}

@Composable
private fun Pill(text: String, fg: Color, bg: Color) {
    Text(
        text = text,
        color = fg,
        fontSize = 12.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .clip(RoundedCornerShape(6.dp))
            .background(bg)
            .padding(horizontal = 8.dp, vertical = 3.dp),
    )
}

private fun remainingText(minutes: Int): String {
    if (minutes <= 0) return "已刷新"
    val h = minutes / 60
    val m = minutes % 60
    return if (h > 0) "$h 小时 $m 分后刷新" else "$m 分后刷新"
}
