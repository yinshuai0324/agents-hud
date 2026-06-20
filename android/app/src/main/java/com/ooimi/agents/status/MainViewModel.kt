package com.ooimi.agents.status

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.ooimi.agents.status.data.Pairing
import com.ooimi.agents.status.data.PairingStore
import com.ooimi.agents.status.data.Snapshot
import com.ooimi.agents.status.net.ConnectionState
import com.ooimi.agents.status.net.SignalClient
import com.ooimi.agents.status.net.Updater
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.io.File

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

    /** Newer release if one is available, else null. */
    private val _update = MutableStateFlow<Updater.UpdateInfo?>(null)
    val update: StateFlow<Updater.UpdateInfo?> = _update.asStateFlow()

    /** Download progress 0f..1f while updating, null otherwise. */
    private val _updateProgress = MutableStateFlow<Float?>(null)
    val updateProgress: StateFlow<Float?> = _updateProgress.asStateFlow()

    private val currentVersion: String = runCatching {
        app.packageManager.getPackageInfo(app.packageName, 0).versionName
    }.getOrNull() ?: "0.0.0"

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
        checkForUpdate()
    }

    /** Check GitHub for a newer release (silent; populates [update] if found). */
    fun checkForUpdate() {
        viewModelScope.launch {
            _update.value = Updater.check(currentVersion)
        }
    }

    /**
     * Download the available update and launch the installer. If the app lacks
     * the "install unknown apps" permission, send the user to grant it first.
     */
    fun startUpdate() {
        val info = _update.value ?: return
        if (_updateProgress.value != null) return // already running
        val app = getApplication<Application>()
        if (!Updater.canInstall(app)) {
            Updater.openInstallPermission(app)
            return
        }
        viewModelScope.launch {
            _updateProgress.value = 0f
            val apk = File(app.cacheDir, "updates/agents-hud-${info.version}.apk")
            val ok = Updater.download(info.apkUrl, apk) { p -> _updateProgress.value = p }
            _updateProgress.value = null
            if (ok) Updater.install(app, apk)
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
