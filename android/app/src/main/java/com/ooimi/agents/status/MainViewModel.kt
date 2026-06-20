package com.ooimi.agents.status

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ooimi.agents.status.data.Pairing
import com.ooimi.agents.status.data.PairingStore
import com.ooimi.agents.status.data.Snapshot
import com.ooimi.agents.status.net.ConnectionState
import com.ooimi.agents.status.net.SignalClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

enum class Screen { LOADING, SCAN, DASHBOARD }

class MainViewModel(app: Application) : AndroidViewModel(app) {
    private val store = PairingStore(app)
    private val client = SignalClient()

    val snapshot: StateFlow<Snapshot?> = client.snapshot
    val connection: StateFlow<ConnectionState> = client.state

    private val _screen = MutableStateFlow(Screen.LOADING)
    val screen: StateFlow<Screen> = _screen.asStateFlow()

    private val _pairing = MutableStateFlow<Pairing?>(null)
    val pairing: StateFlow<Pairing?> = _pairing.asStateFlow()

    init {
        // On launch, decide the start screen from the saved pairing (first emission).
        viewModelScope.launch {
            val saved = store.pairing.first()
            if (saved != null) {
                _pairing.value = saved
                client.connect(saved)
                _screen.value = Screen.DASHBOARD
            } else {
                _screen.value = Screen.SCAN
            }
        }
    }

    /** Called when a QR code is successfully scanned. */
    fun onPaired(pairing: Pairing) {
        viewModelScope.launch {
            store.save(pairing)
            _pairing.value = pairing
            client.connect(pairing)
            _screen.value = Screen.DASHBOARD
        }
    }

    /** Disconnect and return to the scanner. */
    fun rescan() {
        client.close()
        _screen.value = Screen.SCAN
    }

    fun forget() {
        viewModelScope.launch {
            client.close()
            store.clear()
            _pairing.value = null
            _screen.value = Screen.SCAN
        }
    }

    override fun onCleared() {
        client.close()
        super.onCleared()
    }
}
