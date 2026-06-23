package com.ooimi.agents.status.data

import kotlinx.serialization.Serializable

/**
 * Wire models mirroring the server's Snapshot (see server/src/state.ts).
 * Unknown fields are ignored by the configured Json instance, so the server can
 * add fields without breaking older app builds.
 */
@Serializable
data class Snapshot(
    val provider: String = "claude",
    /** Subscription plan display name, e.g. "Max (5x)". Empty if unknown. */
    val plan: String = "",
    /** Model of the most recently active session, e.g. "Opus 4.8 (1M)". */
    val model: String = "",
    val status: Status = Status(),
    val usage5h: Usage5h = Usage5h(),
    /** Weekly (7-day) limit, present only when Claude provides it. */
    val usage7d: UsageWindow? = null,
    /** Today's total spend across all sessions (local day): tokens + equiv. USD. */
    val today: TodayUsage = TodayUsage(),
    val sessions: List<Session> = emptyList(),
    /** Live output generation speed (tokens/sec) of the fastest streaming session. */
    val outputTokensPerSec: Int = 0,
    val ts: String = "",
)

@Serializable
data class UsageWindow(
    val percent: Int = 0,
    val resetInMinutes: Int = 0,
)

@Serializable
data class TodayUsage(
    /** Conversation tokens today: input + output (the "real work"). */
    val tokens: Long = 0,
    /** Cache-write tokens today (prompt caching); usually dwarfs [tokens]. */
    val cacheWriteTokens: Long = 0,
    /** Equivalent pay-as-you-go cost in USD (billing-accurate; includes cache read). */
    val costUSD: Double = 0.0,
)

@Serializable
data class Status(
    val waiting: Int = 0,
    val working: Int = 0,
    val quiet: Int = 0,
    val notify: Int = 0,
    val error: Int = 0,
    val dominant: String = "quiet",
    val total: Int = 0,
)

@Serializable
data class Usage5h(
    val percent: Int = 0,
    val tokensUsed: Long = 0,
    val tokenBudget: Long = 0,
    val resetInMinutes: Int = 0,
    val blockStart: String? = null,
    val blockEnd: String? = null,
    val burnRatePerMin: Long = 0,
    /** "live" = real numbers from Claude; "estimate" = local approximation. */
    val source: String = "estimate",
)

@Serializable
data class Session(
    val id: String = "",
    val project: String = "",
    val cwd: String = "",
    val state: String = "quiet",
    val model: String = "",
    val lastActivity: Long = 0,
    val tokens: Long = 0,
    val contextTokens: Long = 0,
    val contextLeftPercent: Int = 0,
    val currentTool: String = "",
)

/** Session state shared by sessions and the dominant indicator. */
enum class LightState { ERROR, NOTIFY, WAITING, WORKING, QUIET;
    companion object {
        fun from(s: String): LightState = when (s) {
            "working" -> WORKING
            "waiting" -> WAITING
            "notify" -> NOTIFY
            "error" -> ERROR
            else -> QUIET
        }
    }
}
