package com.ooimi.agents.status.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ooimi.agents.status.data.LightState
import com.ooimi.agents.status.data.Snapshot
import com.ooimi.agents.status.net.ConnectionState
import com.ooimi.agents.status.ui.components.Counters
import com.ooimi.agents.status.ui.components.SessionList
import com.ooimi.agents.status.ui.components.TrafficLight
import com.ooimi.agents.status.ui.components.UsageBar
import com.ooimi.agents.status.ui.theme.CCColors
import com.ooimi.agents.status.ui.theme.stateColor

@Composable
fun DashboardScreen(
    snapshot: Snapshot?,
    connection: ConnectionState,
    hostName: String,
    onRescan: () -> Unit,
    update: com.ooimi.agents.status.net.Updater.UpdateInfo? = null,
    updateProgress: Float? = null,
    onUpdate: () -> Unit = {},
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(CCColors.BgTop, CCColors.BgBottom))),
    ) {
        val connected = connection == ConnectionState.CONNECTED
        // Live status only counts while connected; otherwise the light goes dark,
        // the tallies reset to zero, and the rest of the (now stale) data is dimmed.
        val dominant = if (connected) {
            LightState.from(snapshot?.status?.dominant ?: "quiet")
        } else {
            null
        }
        val dataAlpha = if (connected) 1f else 0.35f
        Row(
            Modifier
                .fillMaxSize()
                .safeDrawingPadding()
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            // Far-left column: the vertical traffic light, standing on its own.
            TrafficLight(
                dominant = dominant,
                modifier = Modifier.width(72.dp).fillMaxHeight().alpha(dataAlpha),
            )

            Spacer(Modifier.width(16.dp))

            // Middle column: device header (always bright) + the dimmable data.
            Column(Modifier.weight(1f).fillMaxHeight()) {
                DeviceHeader(
                    hostName = hostName,
                    connection = connection,
                    onRescan = onRescan,
                    staleLabel = if (!connected) lastUpdatedLabel(snapshot?.ts) else null,
                )

                Column(Modifier.weight(1f).fillMaxWidth().alpha(dataAlpha)) {
                    Spacer(Modifier.height(14.dp))
                    UsageBar(
                        plan = snapshot?.plan ?: "",
                        fivePercent = snapshot?.usage5h?.percent ?: 0,
                        fiveResetMin = snapshot?.usage5h?.resetInMinutes ?: 0,
                        live = snapshot?.usage5h?.source == "live",
                        sevenPercent = snapshot?.usage7d?.percent,
                        sevenResetMin = snapshot?.usage7d?.resetInMinutes ?: 0,
                        todayTokens = snapshot?.totals?.todayTokens ?: 0,
                        sevenDayTokens = snapshot?.totals?.sevenDayTokens ?: 0,
                        currentModel = snapshot?.model ?: "",
                    )

                    Spacer(Modifier.weight(1f))
                    Counters(
                        waiting = if (connected) snapshot?.status?.waiting ?: 0 else 0,
                        working = if (connected) snapshot?.status?.working ?: 0 else 0,
                        quiet = if (connected) snapshot?.status?.quiet ?: 0 else 0,
                        notify = if (connected) snapshot?.status?.notify ?: 0 else 0,
                        error = if (connected) snapshot?.status?.error ?: 0 else 0,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            Spacer(Modifier.width(18.dp))

            // Right column: the session list — kept narrower so the light has room.
            Column(Modifier.weight(1.15f).fillMaxHeight().alpha(dataAlpha)) {
                val sessions = snapshot?.sessions ?: emptyList()
                if (sessions.isEmpty()) {
                    EmptyState(connection)
                } else {
                    SessionList(sessions = sessions, modifier = Modifier.fillMaxSize())
                }
            }
        }

        // A full-screen color "breath" that washes in from the edges — only for
        // the states that want your attention (审批 / 等候).
        StatusChangeBreath(dominant)

        UpdateBanner(update, updateProgress, onUpdate)
    }
}

@Composable
private fun BoxScope.UpdateBanner(
    update: com.ooimi.agents.status.net.Updater.UpdateInfo?,
    progress: Float?,
    onUpdate: () -> Unit,
) {
    if (update == null) return
    val text = if (progress != null) {
        "下载更新中 ${(progress * 100).toInt()}%"
    } else {
        "新版本 ${update.version} · 点此更新"
    }
    Row(
        Modifier
            .align(Alignment.TopCenter)
            .safeDrawingPadding()
            .padding(top = 6.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(CCColors.GreenDim)
            .clickable(enabled = progress == null, onClick = onUpdate)
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text = "⬆", color = CCColors.Green, fontSize = 12.sp)
        Spacer(Modifier.width(6.dp))
        Text(
            text = text,
            color = CCColors.Green,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun BoxScope.StatusChangeBreath(dominant: LightState?) {
    val alpha = remember { Animatable(0f) }
    LaunchedEffect(dominant) {
        alpha.snapTo(0f)
        if (dominant == LightState.NOTIFY || dominant == LightState.WAITING) {
            repeat(2) {
                alpha.animateTo(0.28f, tween(520))
                alpha.animateTo(0f, tween(520))
            }
        }
    }
    if (alpha.value > 0f) {
        Box(
            Modifier
                .matchParentSize()
                .background(
                    Brush.radialGradient(
                        listOf(
                            Color.Transparent,
                            stateColor(dominant ?: LightState.WAITING).copy(alpha = alpha.value),
                        ),
                    )
                ),
        )
    }
}

@Composable
private fun DeviceHeader(
    hostName: String,
    connection: ConnectionState,
    onRescan: () -> Unit,
    staleLabel: String?,
) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
            Text(
                text = hostName.ifEmpty { "本机设备" },
                color = CCColors.TextPrimary,
                fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            Spacer(Modifier.width(6.dp))
            ConnectionTag(connection)
            if (!staleLabel.isNullOrEmpty()) {
                Spacer(Modifier.width(6.dp))
                Text(
                    text = "更新于 $staleLabel",
                    color = CCColors.TextFaint,
                    fontSize = 9.sp,
                    maxLines = 1,
                )
            }
        }
        Spacer(Modifier.width(8.dp))
        Text(
            text = "重扫",
            color = CCColors.TextSecondary,
            fontSize = 12.sp,
            modifier = Modifier
                .clip(RoundedCornerShape(7.dp))
                .background(CCColors.Card)
                .clickable(onClick = onRescan)
                .padding(horizontal = 10.dp, vertical = 5.dp),
        )
    }
}

@Composable
private fun ConnectionTag(connection: ConnectionState) {
    val (text, fg, bg) = when (connection) {
        ConnectionState.CONNECTED -> Triple("已连接", CCColors.Green, CCColors.GreenDim)
        ConnectionState.CONNECTING -> Triple("连接中", CCColors.Yellow, CCColors.YellowDim)
        ConnectionState.DISCONNECTED -> Triple("已断开", CCColors.Red, CCColors.RedDim)
    }
    Text(
        text = text,
        color = fg,
        fontSize = 8.sp,
        lineHeight = 8.sp,
        fontWeight = FontWeight.SemiBold,
        modifier = Modifier
            .clip(RoundedCornerShape(4.dp))
            .background(bg)
            .padding(horizontal = 4.dp, vertical = 2.dp),
    )
}

/** Relative "X 前" from a snapshot ISO timestamp; "" if unparseable. */
private fun lastUpdatedLabel(ts: String?): String {
    if (ts.isNullOrEmpty()) return ""
    return try {
        val min = java.time.Duration
            .between(java.time.Instant.parse(ts), java.time.Instant.now())
            .toMinutes()
        when {
            min < 1 -> "刚刚"
            min < 60 -> "$min 分钟前"
            min < 60 * 24 -> "${min / 60} 小时前"
            else -> "${min / (60 * 24)} 天前"
        }
    } catch (_: Exception) {
        ""
    }
}

@Composable
private fun EmptyState(connection: ConnectionState) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(
            text = when (connection) {
                ConnectionState.CONNECTED -> "暂无活动会话"
                ConnectionState.CONNECTING -> "正在连接服务器…"
                ConnectionState.DISCONNECTED -> "连接已断开，正在重连…"
            },
            color = CCColors.TextSecondary,
            fontSize = 14.sp,
        )
    }
}
