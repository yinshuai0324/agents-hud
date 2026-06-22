package com.ooimi.agents.status.ui.components

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.LocalOverscrollConfiguration
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ooimi.agents.status.data.LightState
import com.ooimi.agents.status.data.Session
import com.ooimi.agents.status.ui.theme.CCColors
import com.ooimi.agents.status.ui.theme.stateColor
import com.ooimi.agents.status.ui.theme.stateLabel

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun SessionList(sessions: List<Session>, modifier: Modifier = Modifier) {
    val listState = rememberLazyListState()
    // Keep the list pinned to the top so the newest session is always in view as
    // updates stream in — but only while the user is already at the top. Once
    // they scroll down to look at older sessions we leave their position alone.
    val pinnedToTop by remember {
        derivedStateOf {
            listState.firstVisibleItemIndex == 0 && listState.firstVisibleItemScrollOffset == 0
        }
    }
    val topId = sessions.firstOrNull()?.id
    LaunchedEffect(topId, sessions.size) {
        if (pinnedToTop) listState.scrollToItem(0)
    }

    // Disable the edge overscroll glow/stretch when the list hits top/bottom.
    CompositionLocalProvider(LocalOverscrollConfiguration provides null) {
        LazyColumn(
            modifier.fillMaxWidth(),
            state = listState,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items(sessions, key = { it.id }) { s ->
                SessionRow(s)
            }
        }
    }
}

@Composable
private fun SessionRow(session: Session) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(CCColors.Card.copy(alpha = 0.5f))
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val state = LightState.from(session.state)
        StatusDot(state)
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(
                text = session.project.ifEmpty { "…" },
                color = CCColors.TextPrimary,
                fontSize = 13.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            // Lead callout: the live tool while working, else the states that
            // need you (出错/审批). Everything else is clear from the dot.
            val lead: Pair<String, androidx.compose.ui.graphics.Color>? = when {
                state == LightState.WORKING && session.currentTool.isNotEmpty() ->
                    session.currentTool to stateColor(LightState.WORKING)
                state == LightState.ERROR || state == LightState.NOTIFY ->
                    stateLabel(state) to stateColor(state)
                else -> null
            }
            val meta = buildList {
                if (session.tokens > 0) add(formatTokens(session.tokens) + " tokens")
                if (session.contextTokens > 0) {
                    add("上下文 ${formatTokens(session.contextTokens)} · 剩 ${session.contextLeftPercent}%")
                }
            }
            // Token/context line stays intact; the tool call gets its own line below.
            if (meta.isNotEmpty()) {
                Text(
                    text = meta.joinToString(" · "),
                    color = CCColors.TextFaint,
                    fontSize = 9.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (lead != null) {
                Text(
                    text = lead.first,
                    color = lead.second,
                    fontSize = 9.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Text(
            text = relativeTime(session.lastActivity),
            color = CCColors.TextSecondary,
            fontSize = 14.sp,
        )
    }
}

@Composable
private fun StatusDot(state: LightState) {
    val color = stateColor(state)
    Box(
        Modifier
            .size(10.dp)
            .clip(CircleShape)
            .background(if (state == LightState.QUIET) color.copy(alpha = 0.55f) else color),
    )
}

private fun formatTokens(t: Long): String = when {
    t >= 1_000_000 -> String.format("%.1fM", t / 1_000_000.0)
    t >= 1_000 -> String.format("%.1fk", t / 1_000.0)
    else -> t.toString()
}

private fun relativeTime(epochMs: Long): String {
    if (epochMs <= 0) return ""
    val diff = System.currentTimeMillis() - epochMs
    val min = diff / 60_000
    return when {
        min < 1 -> "刚刚"
        min < 60 -> "$min 分前"
        min < 60 * 24 -> "${min / 60} 小时前"
        else -> "${min / (60 * 24)} 天前"
    }
}
