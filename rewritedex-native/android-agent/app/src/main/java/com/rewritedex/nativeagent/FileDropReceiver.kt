package com.rewritedex.nativeagent

import android.app.ActivityOptions
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.widget.Toast
import androidx.core.content.FileProvider
import java.io.File
import java.net.URLConnection
import java.util.concurrent.Executors

class FileDropReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val requested = intent.getStringExtra(EXTRA_PATH) ?: return
        val downloads = File("/sdcard/Download").canonicalFile
        val source = File(requested).canonicalFile
        if (!source.exists() || source.parentFile != downloads) return
        if (source.isDirectory) {
            Toast.makeText(context, "${source.name} copied to Downloads", Toast.LENGTH_SHORT).show()
            return
        }

        val result = goAsync()
        executor.execute {
            try {
                val dropDirectory = File(context.filesDir, "drops").apply { mkdirs() }
                dropDirectory.listFiles()
                    ?.filter { System.currentTimeMillis() - it.lastModified() > DROP_RETENTION_MS }
                    ?.forEach { it.delete() }
                val safeName = source.name.replace(Regex("[^A-Za-z0-9._ -]"), "_")
                val readableFile = File(dropDirectory, "${System.currentTimeMillis()}-$safeName")
                val uid = android.os.Process.myUid()
                val copied = ProcessBuilder(
                    "su", "-c",
                    "cp -- ${shellQuote(source.path)} ${shellQuote(readableFile.path)} && " +
                        "chown $uid:$uid ${shellQuote(readableFile.path)} && chmod 600 ${shellQuote(readableFile.path)}",
                ).redirectErrorStream(true).start().let { process ->
                    process.inputStream.bufferedReader().use { it.readText() }
                    process.waitFor() == 0
                }
                if (copied && readableFile.isFile) enqueue(context.applicationContext, readableFile, source.name)
            } finally {
                result.finish()
            }
        }
    }

    companion object {
        const val ACTION_OPEN = "com.rewritedex.nativeagent.OPEN_DROPPED_FILE"
        const val EXTRA_PATH = "path"
        const val AUTHORITY = "com.rewritedex.nativeagent.files"
        private const val DROP_RETENTION_MS = 24 * 60 * 60 * 1000L
        private const val BATCH_DELAY_MS = 450L
        private val executor = Executors.newSingleThreadExecutor()
        private val handler = Handler(Looper.getMainLooper())
        private val pending = mutableListOf<Pair<File, String>>()
        private val flush = Runnable { flushPending() }
        private var appContext: Context? = null

        private fun enqueue(context: Context, file: File, originalName: String) {
            handler.post {
                appContext = context
                pending += file to originalName
                handler.removeCallbacks(flush)
                handler.postDelayed(flush, BATCH_DELAY_MS)
            }
        }

        private fun flushPending() {
            val context = appContext ?: return
            val files = pending.toList()
            pending.clear()
            if (files.isEmpty()) return
            val displayId = context.getSystemService(DisplayManager::class.java).displays.firstOrNull {
                it.displayId != Display.DEFAULT_DISPLAY && it.state == Display.STATE_ON &&
                    (it.name.contains("scrcpy", true) || it.name.contains("external", true))
            }?.displayId ?: return
            val uris = ArrayList<Uri>(files.map { FileProvider.getUriForFile(context, AUTHORITY, it.first) })
            val isApk = uris.size == 1 && files.single().second.endsWith(".apk", true)
            val open = if (isApk) {
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uris.single(), "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    if (context.packageManager.getPackageInfoOrNull("com.google.android.packageinstaller") != null) {
                        setPackage("com.google.android.packageinstaller")
                    }
                }
            } else if (uris.size > 1) {
                Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                    type = commonMime(files.map { mimeFor(it.second) })
                    putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            } else {
                Intent(Intent.ACTION_SEND).apply {
                    type = mimeFor(files.single().second)
                    putExtra(Intent.EXTRA_STREAM, uris.single())
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
            }
            val focusedPackage = if (isApk) null else foregroundPackage(displayId)
            if (focusedPackage != null && context.packageManager.resolveActivity(Intent(open).setPackage(focusedPackage), 0) != null) {
                open.setPackage(focusedPackage)
            }
            val launch = if (isApk || open.`package` != null) open else Intent.createChooser(
                open,
                if (files.size == 1) "Send ${files.single().second}" else "Send ${files.size} files",
            ).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(launch, ActivityOptions.makeBasic().apply { launchDisplayId = displayId }.toBundle())
        }

        private fun foregroundPackage(displayId: Int): String? = runCatching {
            val process = ProcessBuilder("su", "-c", "am stack list").redirectErrorStream(true).start()
            val output = process.inputStream.bufferedReader().use { it.readText() }
            process.waitFor()
            DesktopTaskParser.parse(output).firstOrNull {
                it.displayId == displayId && it.visible &&
                    it.packageName !in setOf("com.android.launcher3", "com.android.systemui")
            }?.packageName
        }.getOrNull()

        private fun android.content.pm.PackageManager.getPackageInfoOrNull(packageName: String) =
            runCatching { getPackageInfo(packageName, 0) }.getOrNull()

        private fun mimeFor(name: String): String =
            if (name.endsWith(".apk", true)) "application/vnd.android.package-archive"
            else URLConnection.guessContentTypeFromName(name) ?: "application/octet-stream"

        private fun commonMime(types: List<String>): String =
            types.distinct().singleOrNull() ?: types.map { it.substringBefore('/') }.distinct().singleOrNull()?.plus("/*") ?: "*/*"

        private fun shellQuote(value: String): String = "'${value.replace("'", "'\\''")}'"
    }
}
