package com.ooimi.agents.status.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** Pairing payload encoded in the QR code printed by the server (see qr.ts). */
@Serializable
data class Pairing(
    val v: Int = 1,
    val url: String = "",
    val token: String = "",
    val name: String = "",
) {
    val isValid: Boolean get() = url.startsWith("ws://") || url.startsWith("wss://")

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        /** Parse a scanned QR string. Accepts the JSON payload or a bare ws:// URL. */
        fun parse(raw: String): Pairing? {
            val text = raw.trim()
            return try {
                when {
                    text.startsWith("{") -> json.decodeFromString<Pairing>(text).takeIf { it.isValid }
                    text.startsWith("ws://") || text.startsWith("wss://") -> Pairing(url = text)
                    else -> null
                }
            } catch (_: Exception) {
                null
            }
        }
    }
}

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "cc_signal")

/** Persists the last successful pairing so the app auto-reconnects on launch. */
class PairingStore(private val context: Context) {
    private val urlKey = stringPreferencesKey("url")
    private val tokenKey = stringPreferencesKey("token")
    private val nameKey = stringPreferencesKey("name")

    val pairing: Flow<Pairing?> = context.dataStore.data.map { prefs ->
        val url = prefs[urlKey] ?: return@map null
        Pairing(url = url, token = prefs[tokenKey] ?: "", name = prefs[nameKey] ?: "")
            .takeIf { it.isValid }
    }

    suspend fun save(pairing: Pairing) {
        context.dataStore.edit { prefs ->
            prefs[urlKey] = pairing.url
            prefs[tokenKey] = pairing.token
            prefs[nameKey] = pairing.name
        }
    }

    suspend fun clear() {
        context.dataStore.edit { it.clear() }
    }
}
