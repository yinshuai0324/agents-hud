package com.ooimi.agents.status.net

import com.ooimi.agents.status.data.Pairing
import com.ooimi.agents.status.data.Snapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.TimeUnit
import kotlin.math.min

enum class ConnectionState { CONNECTING, CONNECTED, DISCONNECTED }

/**
 * Maintains a single WebSocket connection to the server and exposes the latest
 * snapshot + connection state as flows. Reconnects automatically with capped
 * exponential backoff. Call [connect] to (re)point at a server and [close] to
 * stop entirely.
 */
class SignalClient {
    private val json = Json { ignoreUnknownKeys = true }
    private val http = OkHttpClient.Builder()
        .pingInterval(20, TimeUnit.SECONDS)
        .connectTimeout(8, TimeUnit.SECONDS)
        .readTimeout(0, TimeUnit.MILLISECONDS) // long-lived stream
        .build()

    private val _snapshot = MutableStateFlow<Snapshot?>(null)
    val snapshot: StateFlow<Snapshot?> = _snapshot.asStateFlow()

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    private var ws: WebSocket? = null
    private var pairing: Pairing? = null
    private var attempt = 0
    private var closed = false

    @Volatile private var generation = 0

    fun connect(pairing: Pairing) {
        this.pairing = pairing
        this.closed = false
        this.attempt = 0
        generation++
        openSocket(generation)
    }

    private fun openSocket(gen: Int) {
        val p = pairing ?: return
        if (closed || gen != generation) return
        _state.value = ConnectionState.CONNECTING
        val url = buildString {
            append(p.url.trimEnd('/'))
            if (p.token.isNotEmpty()) append("?token=").append(p.token)
        }
        val request = Request.Builder().url(url.replace("ws://", "http://").replace("wss://", "https://")).build()
        ws = http.newWebSocket(request, Listener(gen))
    }

    private inner class Listener(private val gen: Int) : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            if (gen != generation) return
            attempt = 0
            _state.value = ConnectionState.CONNECTED
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            if (gen != generation) return
            try {
                _snapshot.value = json.decodeFromString<Snapshot>(text)
            } catch (_: Exception) {
                // ignore malformed frame
            }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            scheduleReconnect(gen)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            scheduleReconnect(gen)
        }
    }

    private fun scheduleReconnect(gen: Int) {
        if (closed || gen != generation) return
        _state.value = ConnectionState.DISCONNECTED
        attempt++
        val delayMs = min(15_000L, 500L * (1L shl min(attempt, 5)))
        Thread {
            Thread.sleep(delayMs)
            openSocket(gen)
        }.apply { isDaemon = true }.start()
    }

    fun close() {
        closed = true
        generation++
        ws?.close(1000, "bye")
        ws = null
        _state.value = ConnectionState.DISCONNECTED
    }
}
