package com.ooimi.agents.status

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import com.ooimi.agents.status.ui.DashboardScreen
import com.ooimi.agents.status.ui.ScanScreen
import com.ooimi.agents.status.ui.theme.CCColors
import com.ooimi.agents.status.ui.theme.CCSignalTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Keep the screen awake — this is a glanceable always-on dashboard.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        enableEdgeToEdge()
        // Let the window draw into the camera cutout area; the UI then pads itself
        // away from it via safeDrawingPadding() so nothing is hidden behind it.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
        hideSystemBars()
        // Kiosk-style: swallow the back gesture/button so the app can't be exited.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { /* no-op — stay in the app */ }
        })
        setContent {
            CCSignalTheme {
                ProportionalScale {
                    AppRoot()
                }
            }
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Re-hide the bars after a transient swipe-in or a focus change.
        if (hasFocus) hideSystemBars()
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }
}

/**
 * Render the whole UI as if the screen were [DESIGN_WIDTH_DP] dp wide, scaling
 * every dp/sp uniformly to fill the real width. Keeps proportions identical across
 * resolutions / DPIs / screen sizes (the layout was tuned at 800dp landscape).
 * fontScale is pinned to 1 so the kiosk looks the same regardless of the system
 * font-size setting.
 */
private const val DESIGN_WIDTH_DP = 800f

@Composable
private fun ProportionalScale(content: @Composable () -> Unit) {
    val cfg = LocalConfiguration.current
    val base = LocalDensity.current
    val scale = (cfg.screenWidthDp / DESIGN_WIDTH_DP).coerceIn(0.6f, 3f)
    CompositionLocalProvider(
        LocalDensity provides Density(density = base.density * scale, fontScale = 1f),
    ) {
        content()
    }
}

@Composable
private fun AppRoot(vm: MainViewModel = viewModel()) {
    val screen by vm.screen.collectAsStateWithLifecycle()
    val snapshot by vm.snapshot.collectAsStateWithLifecycle()
    val connection by vm.connection.collectAsStateWithLifecycle()
    val pairing by vm.pairing.collectAsStateWithLifecycle()
    val update by vm.update.collectAsStateWithLifecycle()
    val updateProgress by vm.updateProgress.collectAsStateWithLifecycle()
    val showUpdateDialog by vm.showUpdateDialog.collectAsStateWithLifecycle()

    when (screen) {
        Screen.LOADING -> Box(Modifier.fillMaxSize().background(CCColors.BgBottom))
        Screen.SCAN -> ScanScreen(onScanned = vm::onPaired)
        Screen.DASHBOARD -> DashboardScreen(
            snapshot = snapshot,
            connection = connection,
            hostName = pairing?.name ?: "",
            onRescan = vm::rescan,
            update = update,
            updateProgress = updateProgress,
            onUpdate = vm::startUpdate,
        )
    }

    val u = update
    if (showUpdateDialog && u != null) {
        AlertDialog(
            onDismissRequest = vm::dismissUpdate,
            title = { Text("发现新版本 ${u.version}") },
            text = {
                Text(u.notes.ifBlank { "有可用更新，是否现在更新？" }.take(300))
            },
            confirmButton = { TextButton(onClick = vm::startUpdate) { Text("立即更新") } },
            dismissButton = { TextButton(onClick = vm::dismissUpdate) { Text("稍后") } },
        )
    }
}
