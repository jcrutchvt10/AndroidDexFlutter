package com.rewritedex.nativeagent

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import java.io.File

class ExportToWindowsActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> emptyList()
        }
        val directory = File(getExternalFilesDir(null), "Exports").apply { mkdirs() }
        var copied = 0
        uris.take(MAX_EXPORTS).forEach { uri ->
            val name = displayName(uri).replace(Regex("[^A-Za-z0-9._ -]"), "_").ifBlank { "export" }
            val target = uniqueFile(directory, name)
            runCatching {
                contentResolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use(input::copyTo)
                } ?: error("unreadable content")
            }.onSuccess { copied++ }
        }
        Toast.makeText(this, "$copied item${if (copied == 1) "" else "s"} queued for Windows", Toast.LENGTH_SHORT).show()
        finish()
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0) ?: "export"
        }
        return uri.lastPathSegment ?: "export"
    }

    private fun uniqueFile(directory: File, name: String): File {
        var target = File(directory, name)
        var suffix = 2
        while (target.exists()) target = File(directory, "${name.substringBeforeLast('.', name)}-$suffix.${name.substringAfterLast('.', "bin")}").also { suffix++ }
        return target
    }

    companion object { private const val MAX_EXPORTS = 32 }
}
