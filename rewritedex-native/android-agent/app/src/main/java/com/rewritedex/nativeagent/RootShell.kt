package com.rewritedex.nativeagent

import android.util.Log
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

data class ShellResult(val exitCode: Int, val output: String)

/**
 * Root shell executor. Every privileged Android operation flows through this
 * single choke point so command dispatch, output capture, and timeout policy
 * stay consistent, bounded, and testable.
 */
object RootShell {
    private const val TAG = "RewriteDEXAgent"
    const val MAX_SHELL_OUTPUT_BYTES = 256 * 1024
    const val DEFAULT_TIMEOUT_SECONDS = 5L
    const val APPROVAL_TIMEOUT_SECONDS = 60L

    fun run(command: String, timeoutSeconds: Long = DEFAULT_TIMEOUT_SECONDS): ShellResult {
        val process = ProcessBuilder("su", "-c", command)
            .redirectErrorStream(true)
            .start()
        val output = ByteArrayOutputStream()
        val reader = Thread({
            try {
                process.inputStream.use { input ->
                    val buffer = ByteArray(4096)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.size() < MAX_SHELL_OUTPUT_BYTES) {
                            output.write(buffer, 0, minOf(count, MAX_SHELL_OUTPUT_BYTES - output.size()))
                        }
                    }
                }
            } catch (error: Exception) {
                // A timed-out root command closes its stream from the caller
                // thread. Do not let that expected interruption crash the FGS.
                Log.w(TAG, "Root command output reader stopped", error)
            }
        }, "rewritedex-shell-output").apply {
            isDaemon = true
            start()
        }
        if (!process.waitFor(timeoutSeconds, TimeUnit.SECONDS)) {
            process.destroyForcibly()
            process.waitFor(1, TimeUnit.SECONDS)
            process.inputStream.close()
            reader.join(1_000)
            return ShellResult(-1, "command timed out")
        }
        reader.join(1_000)
        return ShellResult(process.exitValue(), output.toString(Charsets.UTF_8.name()))
    }

    fun quote(value: String): String = "'${value.replace("'", "'\\''")}'"
}
