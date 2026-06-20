package com.ooimi.agents.status.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ooimi.agents.status.data.LightState
import com.ooimi.agents.status.ui.theme.CCColors
import com.ooimi.agents.status.ui.theme.stateColor
import com.ooimi.agents.status.ui.theme.stateLabel

/**
 * Fixed per-state tally row: 出错 · 审批 · 等候 · 工作 · 空闲, attention-first.
 * A state with sessions shows its count in the state color; an empty state is
 * dimmed so the active ones stand out.
 */
@Composable
fun Counters(
    waiting: Int,
    working: Int,
    quiet: Int,
    notify: Int,
    error: Int,
    modifier: Modifier = Modifier,
) {
    // SpaceBetween so the first cell sits flush-left under the panel and the last
    // cell is flush-right, matching the content above.
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Top,
    ) {
        CounterCell(LightState.NOTIFY, notify)
        CounterCell(LightState.WORKING, working)
        CounterCell(LightState.WAITING, waiting)
        CounterCell(LightState.QUIET, quiet)
        CounterCell(LightState.ERROR, error)
    }
}

@Composable
private fun CounterCell(state: LightState, count: Int, modifier: Modifier = Modifier) {
    val active = count > 0
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = count.toString(),
            color = if (active) stateColor(state) else CCColors.TextFaint,
            fontSize = 28.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            text = stateLabel(state),
            color = if (active) CCColors.TextSecondary else CCColors.TextFaint,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 1.dp),
        )
    }
}
