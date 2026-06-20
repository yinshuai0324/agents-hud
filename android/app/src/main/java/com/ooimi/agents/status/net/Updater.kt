package com.ooimi.agents.status.net

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.util.concurrent.TimeUnit

/**
 * Self-update via GitHub Releases: check the latest tag, download its APK, and
 * hand it to the system installer. Works because every release is signed with
 * the same committed key (see android/app/agentshud-release.jks).
 */
object Updater {
    private const val LATEST =
        "https://api.github.com/repos/yinshuai0324/agents-hud/releases/latest"

    private val json = Json { ignoreUnknownKeys = true }
    private val http = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    data class UpdateInfo(val version: String, val apkUrl: String, val notes: String)

    @Serializable
    private data class GhRelease(
        val tag_name: String = "",
        val name: String = "",
        val body: String = "",
        val assets: List<GhAsset> = emptyList(),
    )

    @Serializable
    private data class GhAsset(val name: String = "", val browser_download_url: String = "")

    /** Returns the latest release if it is newer than [currentVersion] and ships an APK. */
    suspend fun check(currentVersion: String): UpdateInfo? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder()
                .url(LATEST)
                .header("Accept", "application/vnd.github+json")
                .build()
            http.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                val rel = json.decodeFromString<GhRelease>(resp.body?.string() ?: return@withContext null)
                val version = rel.tag_name.removePrefix("v").trim()
                val apk = rel.assets.firstOrNull { it.name.endsWith(".apk") } ?: return@withContext null
                if (version.isEmpty() || !isNewer(version, currentVersion)) return@withContext null
                UpdateInfo(version, apk.browser_download_url, rel.body)
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Streams the APK to [dest], reporting 0f..1f progress. Returns success. */
    suspend fun download(url: String, dest: File, onProgress: (Float) -> Unit): Boolean =
        withContext(Dispatchers.IO) {
            try {
                http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                    val body = resp.body
                    if (!resp.isSuccessful || body == null) return@withContext false
                    val total = body.contentLength()
                    dest.parentFile?.mkdirs()
                    body.byteStream().use { input ->
                        dest.outputStream().use { out ->
                            val buf = ByteArray(64 * 1024)
                            var read = 0L
                            while (true) {
                                val n = input.read(buf)
                                if (n < 0) break
                                out.write(buf, 0, n)
                                read += n
                                if (total > 0) onProgress((read.toFloat() / total).coerceIn(0f, 1f))
                            }
                        }
                    }
                    true
                }
            } catch (_: Exception) {
                false
            }
        }

    /** True if the app is allowed to install APKs (needed on API 26+). */
    fun canInstall(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || ctx.packageManager.canRequestPackageInstalls()

    /** Open the per-app "install unknown apps" settings so the user can grant permission. */
    fun openInstallPermission(ctx: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    /** Launch the system package installer for [apk]. */
    fun install(ctx: Context, apk: File) {
        val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", apk)
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            },
        )
    }

    /** Numeric semver compare: is [remote] > [local]? */
    private fun isNewer(remote: String, local: String): Boolean {
        val r = parts(remote)
        val l = parts(local)
        for (i in 0 until maxOf(r.size, l.size)) {
            val rv = r.getOrElse(i) { 0 }
            val lv = l.getOrElse(i) { 0 }
            if (rv != lv) return rv > lv
        }
        return false
    }

    private fun parts(v: String): List<Int> =
        v.split(".").map { it.takeWhile(Char::isDigit).toIntOrNull() ?: 0 }
}
