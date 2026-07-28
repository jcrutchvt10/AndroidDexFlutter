package com.rewritedex.nativeagent

import android.app.ActivityOptions
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.util.Log
import android.view.Display
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.io.BufferedReader
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.concurrent.ExecutorService
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject

class DexAgentService : Service() {
    private data class ShellResult(val exitCode: Int, val output: String)

    private data class RequestHeaders(val contentLength: Int, val token: String?)

    private data class HostEvent(
        val sequence: Long,
        val type: String,
        val payload: JSONObject,
    )

    private data class DesktopTask(
        val rootTaskId: Int,
        val taskId: Int,
        val displayId: Int,
        val packageName: String,
        val component: String,
        val bounds: Rect,
        val visible: Boolean,
    )

    /** Active freeform edge/corner drag started from host pointer coordinates. */
    private data class EdgeResizeDrag(
        val taskId: Int,
        val packageName: String,
        val displayId: Int,
        val edges: Int,
        val startBounds: Rect,
        val startX: Int,
        val startY: Int,
    )

    private val preferences by lazy { getSharedPreferences("desktop_session", MODE_PRIVATE) }
    private val requestExecutor: ExecutorService = Executors.newFixedThreadPool(4) { runnable ->
        Thread(runnable, "rewritedex-request").apply { isDaemon = true }
    }
    private val controlExecutor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "rewritedex-control").apply { isDaemon = true }
    }
    private val cachedTasks = AtomicReference<List<DesktopTask>>(emptyList())
    private val lastDesktopInputAt = AtomicLong(0L)
    private val pendingDesktopDisplayId = AtomicInteger(Display.DEFAULT_DISPLAY)
    private val launchWatchGeneration = AtomicLong(0L)
    private val lastShellLaunchAt = AtomicLong(0L)
    private val lastShellLaunchPackage = AtomicReference<String?>(null)
    private val widgetForegroundTaskIds = ConcurrentHashMap<Int, Int>()
    private val widgetTaskIds = ConcurrentHashMap<Int, Int>()
    private val widgetShowDebounce = ConcurrentHashMap<Int, Long>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val preparedDisplays = mutableSetOf<Int>()
    @Volatile private var lastKnownDesktopDisplayId = Display.DEFAULT_DISPLAY
    @Volatile private var edgeResizeDrag: EdgeResizeDrag? = null
    @Volatile private var lastInputRequestAt = 0L
    private val hostEventLock = Object()
    private val hostEvents = ArrayDeque<HostEvent>()
    private val hostEventSequence = AtomicLong(0L)

    // Structured concurrency scope for async waits (replaces busy Thread.sleep polling loops)
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) {
            prepareDesktopDisplay(displayId)
            publishHostEvent("display-added", JSONObject().put("displayId", displayId))
        }
        override fun onDisplayChanged(displayId: Int) {
            prepareDesktopDisplay(displayId)
            publishHostEvent("display-changed", JSONObject().put("displayId", displayId))
            // On size change (maximize/resize on secondary), just resize the known
            // widget task instead of full re-show. This avoids dups and ANR from
            // repeated root commands + am starts.
            if (displayId != Display.DEFAULT_DISPLAY) {
                controlExecutor.execute { resizeExistingWidget(displayId) }
            }
        }
        override fun onDisplayRemoved(displayId: Int) {
            publishHostEvent("display-removed", JSONObject().put("displayId", displayId))
            synchronized(preparedDisplays) { preparedDisplays.remove(displayId) }
            widgetForegroundTaskIds.remove(displayId)
            widgetTaskIds.remove(displayId)
            widgetShowDebounce.remove(displayId)
            cachedTasks.set(emptyList())
            // Destroy desktop-only tasks so they never migrate onto the phone
            // when the virtual display disappears (scrcpy crash / close).
            if (displayId != Display.DEFAULT_DISPLAY) {
                controlExecutor.execute { destroyDesktopDisplayTasks(displayId) }
            }
            if (lastKnownDesktopDisplayId == displayId) {
                lastKnownDesktopDisplayId = Display.DEFAULT_DISPLAY
            }
        }
    }
    private var server: ServerSocket? = null
    private var taskEventProcess: Process? = null
    @Volatile private var sessionToken: String? = null
    @Volatile private var rootAvailable = false
    @Volatile private var rootCheckedAt = 0L
    @Volatile private var taskCacheAt = 0L
    private var logcatRestarts = 0

    private val securePrefs by lazy {
        val masterKey = MasterKey.Builder(this)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            this,
            "rewritedex_secure",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        val channel = NotificationChannel(
            CHANNEL_ID,
            "RewriteDEX desktop bridge",
            NotificationManager.IMPORTANCE_LOW,
        )
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        startForeground(
            NOTIFICATION_ID,
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("RewriteDEX")
                .setContentText("Pixel desktop bridge active")
                .setSmallIcon(android.R.drawable.ic_menu_compass)
                .setOngoing(true)
                .build(),
        )
        Thread(::serve, "rewritedex-agent").start()
        getSystemService(DisplayManager::class.java).registerDisplayListener(
            displayListener,
            Handler(Looper.getMainLooper()),
        )
        getSystemService(DisplayManager::class.java).displays.forEach { display ->
            prepareDesktopDisplay(display.displayId)
        }
        controlExecutor.execute { cleanupStaleDesktopTasks() }
        Thread(::watchTaskEvents, "rewritedex-task-events").start()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val token = intent?.getStringExtra("token")
            ?.takeIf(TOKEN_PATTERN::matches)
        if (token != null) {
            sessionToken = token
            securePrefs.edit().putString("session_token", token).apply()
        } else {
            // Restore token from encrypted storage on service restart.
            securePrefs.getString("session_token", null)?.let { sessionToken = it }
        }
        val action = intent?.action
        when (action) {
            ACTION_PHONE_CONTROL -> {
                controlExecutor.execute { handlePhoneControl(intent) }
            }
            ACTION_APPLY_SETTINGS -> {
                val qp = intent.getIntExtra("quality_profile", -1)
                if (qp >= 0) {
                    // Note: streaming quality is primarily controlled from the Windows host
                    // (via scrcpy spawn args). We persist here for any future agent-side use.
                    preferences.edit().putInt("quality_profile", qp).apply()
                    Log.i(TAG, "Applied quality profile hint from settings: $qp")
                }
            }
            ACTION_RESTART_AGENT -> {
                // Self-stop; the controller normally restarts the foreground service on demand
                Log.i(TAG, "Restart requested via settings")
                stopSelf()
            }
            ACTION_EXPORT_DIAGNOSTICS -> {
                controlExecutor.execute {
                    // Dump a bit of status into log and ensure export dir
                    val status = status()
                    Log.i(TAG, "Diagnostics export requested. Current status sample: ${status.toString().take(300)}")
                    // The host tray "Export diagnostics" is the richer path (includes scrcpy logs)
                }
            }
        }
        return START_NOT_STICKY
    }

    private fun serve() {
        try {
            server = ServerSocket(PORT, 16, InetAddress.getByName("127.0.0.1"))
            while (!Thread.currentThread().isInterrupted) {
                val connection = server?.accept() ?: break
                try {
                    requestExecutor.execute {
                        try {
                            handle(connection)
                        } catch (error: Exception) {
                            Log.e(TAG, "Agent request failed", error)
                            connection.close()
                        }
                    }
                } catch (error: Exception) {
                    Log.e(TAG, "Agent request rejected", error)
                    connection.close()
                }
            }
        } catch (error: Exception) {
            if (server?.isClosed != true) Log.e(TAG, "Agent server stopped", error)
        }
    }

    private fun handle(socket: Socket) {
        socket.use { connection ->
            connection.soTimeout = 5_000
            val input = connection.getInputStream().bufferedReader()
            val request = input.readLine() ?: return
            val requestParts = request.split(' ')
            val method = requestParts.getOrNull(0) ?: "GET"
            val requestTarget = requestParts.getOrNull(1) ?: "/"
            val path = requestTarget.substringBefore('?')
            val query = requestTarget.substringAfter('?', "")
            val headers = readHeaders(input)
            if (headers.contentLength < 0) {
                writeResponse(connection, 400, errorResponse("invalid content length"))
                return
            }
            if (headers.contentLength > MAX_BODY_BYTES) {
                if (headers.contentLength <= MAX_REJECTED_BODY_BYTES) {
                    discardBody(input, headers.contentLength)
                }
                writeResponse(connection, 413, errorResponse("request body too large", 413))
                return
            }
            val body = readBody(input, headers.contentLength)

            if (!validToken(headers.token)) {
                writeResponse(connection, 401, errorResponse("unauthorized", 401))
                return
            }

            val (status, response) = try {
                route(method, path, body, query)
            } catch (error: JSONException) {
                400 to errorResponse(error.message ?: "invalid JSON")
            } catch (error: IllegalArgumentException) {
                400 to errorResponse(error.message ?: "invalid request")
            } catch (error: Exception) {
                500 to errorResponse(error.message ?: "request failed", 500)
            }
            writeResponse(connection, status, response)
        }
    }

    private fun readHeaders(input: BufferedReader): RequestHeaders {
        var length = 0
        var token: String? = null
        while (true) {
            val header = input.readLine() ?: break
            if (header.isEmpty()) break
            if (header.startsWith("Content-Length", ignoreCase = true)) {
                length = header.substringAfter(':').trim().toIntOrNull() ?: -1
            } else if (header.startsWith("X-RewriteDEX-Token", ignoreCase = true)) {
                token = header.substringAfter(':').trim()
            }
        }
        return RequestHeaders(length, token)
    }

    private fun validToken(candidate: String?): Boolean {
        val expected = sessionToken ?: return false
        if (candidate == null) return false
        return MessageDigest.isEqual(
            expected.toByteArray(Charsets.US_ASCII),
            candidate.toByteArray(Charsets.US_ASCII),
        )
    }

    private fun readBody(input: BufferedReader, length: Int): String {
        if (length == 0) return ""
        val body = CharArray(length)
        var offset = 0
        while (offset < length) {
            val count = input.read(body, offset, length - offset)
            if (count < 0) break
            offset += count
        }
        return String(body, 0, offset)
    }

    private fun discardBody(input: BufferedReader, length: Int) {
        val buffer = CharArray(4096)
        var remaining = length
        while (remaining > 0) {
            val count = input.read(buffer, 0, minOf(buffer.size, remaining))
            if (count < 0) break
            remaining -= count
        }
    }

    private fun route(method: String, path: String, body: String, query: String = ""): Pair<Int, JSONObject> = when {
        method == "GET" && path == "/api/v1/apps" -> 200 to appInventoryResponse()
        method == "GET" && path == "/api/v1/events" -> 200 to hostEventsResponse(query)
        method == "GET" && path == "/status" -> 200 to status()
        method == "GET" && path == "/tasks" -> 200 to tasksResponse()
        method == "GET" && path == "/session" -> 200 to sessionResponse()
        method == "GET" && path == "/profiles" -> 200 to profilesResponse()
        method == "GET" && path == "/workspaces" -> 200 to WorkspaceStore.response(preferences)
        method == "GET" && path == "/notifications" -> 200 to notificationsResponse()
        method == "GET" && path == "/exports" -> 200 to exportsResponse()
        method == "GET" && path == "/wallpaper" -> 200 to wallpaperStatus()
        method == "POST" && path == "/launch" -> 200 to launch(JSONObject(body))
        method == "POST" && path == "/task" -> 200 to taskAction(JSONObject(body))
        method == "POST" && path == "/system" -> 200 to systemAction(JSONObject(body))
        method == "POST" && path == "/desktop/input" -> 200 to markDesktopInput(JSONObject(body))
        method == "POST" && path == "/root/request" -> 200 to requestRootAccess()
        method == "POST" && path == "/profiles" -> 200 to updateProfile(JSONObject(body))
        method == "POST" && path == "/wallpaper" -> 200 to wallpaperAction(JSONObject(body))
        method == "POST" && path == "/session/save" -> 200 to saveSession()
        method == "POST" && path == "/workspace/save" -> 200 to saveWorkspace(JSONObject(body))
        method == "POST" && path == "/workspace/restore" -> 200 to restoreWorkspace(JSONObject(body))
        method == "POST" && path == "/workspace/delete" -> 200 to deleteWorkspace(JSONObject(body))
        method == "POST" && path == "/notifications/clear" -> 200 to clearNotifications()
        method == "POST" && path == "/exports/ack" -> 200 to acknowledgeExport(JSONObject(body))
        else -> 404 to JSONObject().put("ok", false).put("error", "not found")
    }

    /**
     * Windows-first launcher inventory. This is intentionally launchable-app
     * metadata only: it does not expose Android package permissions, APK paths,
     * or phone-only system internals to the desktop shell.
     */
    private fun appInventoryResponse(): JSONObject {
        val launcherIntent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val apps = JSONArray()
        packageManager.queryIntentActivities(launcherIntent, PackageManager.MATCH_ALL)
            .asSequence()
            .filter { it.activityInfo.packageName !in SESSION_EXCLUDED_PACKAGES }
            .filter { (it.activityInfo.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) == 0 }
            .map { info ->
                JSONObject()
                    .put("package", info.activityInfo.packageName)
                    .put("component", info.activityInfo.name)
                    .put("label", info.loadLabel(packageManager)?.toString().orEmpty())
            }
            .distinctBy { it.getString("package") }
            .sortedBy { it.getString("label").lowercase() }
            .forEach { apps.put(it) }
        return JSONObject()
            .put("ok", true)
            .put("apiVersion", 1)
            .put("apps", apps)
    }

    /** A bounded long-poll event feed used by the Windows shell for fast reconciliation. */
    private fun hostEventsResponse(query: String): JSONObject {
        val cursor = query.substringAfter("cursor=", "0")
            .substringBefore('&')
            .toLongOrNull()
            ?.coerceAtLeast(0L)
            ?: 0L
        synchronized(hostEventLock) {
            if (hostEvents.none { it.sequence > cursor }) {
                try {
                    hostEventLock.wait(HOST_EVENT_LONG_POLL_MS)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
            val events = JSONArray()
            hostEvents.filter { it.sequence > cursor }.forEach { event ->
                events.put(
                    JSONObject()
                        .put("sequence", event.sequence)
                        .put("type", event.type)
                        .put("payload", event.payload),
                )
            }
            return JSONObject()
                .put("ok", true)
                .put("apiVersion", 1)
                .put("cursor", hostEventSequence.get())
                .put("events", events)
        }
    }

    fun publishHostEvent(type: String, payload: JSONObject = JSONObject()) {
        synchronized(hostEventLock) {
            hostEvents.addLast(HostEvent(hostEventSequence.incrementAndGet(), type, payload))
            while (hostEvents.size > MAX_HOST_EVENTS) hostEvents.removeFirst()
            hostEventLock.notifyAll()
        }
    }

    private fun status(): JSONObject {
        val displays = JSONArray()
        getSystemService(DisplayManager::class.java).displays.forEach { display ->
            val metrics = android.util.DisplayMetrics()
            @Suppress("DEPRECATION")
            display.getRealMetrics(metrics)
            displays.put(
                JSONObject()
                    .put("id", display.displayId)
                    .put("name", display.name)
                    .put("width", metrics.widthPixels)
                    .put("height", metrics.heightPixels)
                    .put("densityDpi", metrics.densityDpi)
                    .put(
                        "physical",
                        display.displayId != Display.DEFAULT_DISPLAY &&
                            !display.name.contains("scrcpy", true) &&
                            !isCompositorDisplay(display),
                    )
                    .put("state", display.state),
            )
        }
        return JSONObject()
            .put("ok", true)
            .put(
                "agentVersion",
                packageManager.getPackageInfo(packageName, 0).versionName ?: "unknown",
            )
            .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
            .put("sdk", Build.VERSION.SDK_INT)
            .put("running", true)
            .put("root", hasRoot())
            .put("readLogs", checkSelfPermission(android.Manifest.permission.READ_LOGS) == PackageManager.PERMISSION_GRANTED)
            .put("notificationAccess", notificationAccessEnabled())
            .put("desktopMode", desktopDisplayId() != Display.DEFAULT_DISPLAY)
            .put("desktopDisplayId", desktopDisplayId())
            .put("displays", displays)
            .put(
                "rememberedApps",
                preferences.all.keys.count {
                    !it.startsWith('_') && it !in SESSION_EXCLUDED_PACKAGES
                },
            )
            .put("taskTracking", taskEventProcess?.isAlive == true)
    }

    private fun desktopDisplayId(): Int {
        val cached = lastKnownDesktopDisplayId.takeIf { it != Display.DEFAULT_DISPLAY }
        val displays = getSystemService(DisplayManager::class.java).displays
        val live = displays.firstOrNull {
            it.displayId != Display.DEFAULT_DISPLAY && it.state == Display.STATE_ON &&
                !isCompositorDisplay(it) &&
                (it.name.contains("scrcpy", ignoreCase = true) ||
                    it.name.contains("external", ignoreCase = true))
        }?.displayId ?: displays.firstOrNull {
            it.displayId != Display.DEFAULT_DISPLAY && it.state == Display.STATE_ON &&
                !isCompositorDisplay(it)
        }?.displayId ?: Display.DEFAULT_DISPLAY
        val resolved = live.takeIf { it != Display.DEFAULT_DISPLAY } ?: cached ?: Display.DEFAULT_DISPLAY
        if (resolved != Display.DEFAULT_DISPLAY) {
            lastKnownDesktopDisplayId = resolved
        }
        return resolved
    }

    /** Ensure freeform windowing mode for the target display. Called before launches and resizes. */
    private fun ensureFreeformMode(displayId: Int) {
        if (displayId == Display.DEFAULT_DISPLAY) return
        runRoot("cmd window set-display-windowing-mode -d $displayId ${windowingModeFreeform}")
    }

    private fun prepareDesktopDisplay(displayId: Int) {
        if (displayId == Display.DEFAULT_DISPLAY) return
        val display = getSystemService(DisplayManager::class.java).getDisplay(displayId) ?: return
        if (isCompositorDisplay(display)) return
        if (display.state != Display.STATE_ON ||
            (!display.name.contains("scrcpy", true) && !display.name.contains("external", true))
        ) return
        val firstPreparation = synchronized(preparedDisplays) { preparedDisplays.add(displayId) }
        if (!firstPreparation) return
        lastKnownDesktopDisplayId = displayId
        controlExecutor.execute {
            // One freeform switch is enough. Hammering windowing mode can kill the
            // scrcpy virtual-display encoder session.
            ensureFreeformMode(displayId)
            // Brief settle for SystemUI to apply windowing mode before other desktop prep.
            Thread.sleep(300)
            // External/virtual displays only — freeform on the scrcpy display id.
            // Do not force phone (display 0) into desktop chrome.
            runRoot("settings put global force_desktop_mode_on_external_displays 1")
            runRoot("settings put global enable_freeform_support 1")
            // Prefer display-scoped freeform; global force_resizable changes phone UX.
            runRoot(
                "device_config put activity_manager_native_boot " +
                    "com.android.window.flags.enable_drawing_app_handle true",
            )
            runRoot("settings put secure show_ime_with_hard_keyboard 0")
            DesktopWallpaperService.rotateForSession(this)
            cleanupStaleDesktopTasks()
            preferences.edit().putInt("_last_desktop_display", displayId).apply()

            // Let SystemUI/Launcher own the shell. SECONDARY_HOME brings up the
            // desktop home + launcher taskbar on this virtual display.
            // Never auto-reopen last-session apps (Settings, Zetamod, etc.).
            // Workspaces can still be restored explicitly via /workspace/restore.
            preferences.edit()
                .putBoolean("_restore_session", false)
                .putString("_last_packages", "[]")
                .apply()

            val home = launchDesktopHome(displayId)
            if (home.exitCode != 0) {
                Log.w(TAG, "Could not launch desktop home on $displayId: ${home.output}")
            }
            Thread.sleep(500)
            refreshTaskCache()

            mainHandler.postDelayed({
                controlExecutor.execute {
                    // Keep SECONDARY_HOME focused; do not launch saved packages
                    // or chrome that steals focus.
                    launchDesktopHome(displayId)
                    showDesktopWidgetCards(displayId)
                }
            }, 800)
        }
    }

    private fun isCompositorDisplay(display: Display): Boolean =
        display.name.startsWith("RewriteDEX-broker-task-", ignoreCase = true)

    /**
     * Places clock/battery cards as a freeform window on the desktop display.
     * Avoids SYSTEM_ALERT_WINDOW — Android force-hides non-system overlays.
     */
    private fun showDesktopWidgetCards(displayId: Int) {
        val metrics = displayMetrics(displayId) ?: return

        // Debounce rapid calls (e.g. during window resize/maximize or multiple display events)
        val now = System.currentTimeMillis()
        if (now - widgetShowDebounce.getOrDefault(displayId, 0L) < 1500) {
            return
        }
        widgetShowDebounce[displayId] = now

        // Always remove any existing widget cards for this display FIRST.
        // This is the robust way to prevent old instances from lingering behind new ones.
        readTasksFromSystem()
            .filter { it.displayId == displayId && it.component.contains("DesktopWidgetActivity") }
            .forEach { runRoot("am task remove ${it.taskId}") }
        widgetTaskIds.remove(displayId)

        // Use a modest fraction of the desktop so freeform min-size clamps still
        // leave a small card cluster, not half the screen.
        // Small, non-intrusive panel in top-right corner (rich but minimal)
        val width = (metrics.widthPixels * 0.26f).roundToInt().coerceIn(380, 520)
        val height = (metrics.heightPixels * 0.16f).roundToInt().coerceIn(160, 220)
        val left = (metrics.widthPixels - width - 24).coerceAtLeast(8)
        val top = 16
        val right = left + width
        val bottom = top + height
        val component = "$packageName/.DesktopWidgetActivity"

        ensureFreeformMode(displayId)
        val started = runRoot(
            "am start --user current --display $displayId " +
                "--windowingMode ${windowingModeFreeform} " +
                "--activity-exclude-from-recents " +
                "-n ${shellQuote(component)}",
        )
        if (started.exitCode != 0) {
            Log.w(TAG, "Could not start desktop widget activity: ${started.output}")
            return
        }

        // Schedule the wait-for-task + resize work so showDesktopWidgetCards returns
        // immediately. This keeps the controlExecutor responsive and prevents ANR
        // from long poll loops during desktop resize or high event load.
        mainHandler.postDelayed({
            controlExecutor.execute {
                var foundTask: DesktopTask? = null
                for (attempt in 0 until 8) {
                    foundTask = readTasksFromSystem().firstOrNull {
                        it.displayId == displayId &&
                            it.packageName == packageName &&
                            it.component.contains("DesktopWidgetActivity")
                    }
                    if (foundTask != null) break
                    Thread.sleep(100)
                }
                val task = foundTask
                if (task == null) {
                    Log.w(TAG, "Desktop widget activity started but task was not found to resize")
                    return@execute
                }
                runRoot("am task resize ${task.taskId} $left $top $right $bottom")
                Thread.sleep(80)
                runRoot("am task resize ${task.taskId} $left $top $right $bottom")
                // Do NOT focus or reorder-to-front the widget here.
                // Focusing it would bring the panel on top of open apps.
                // Apps launched later will naturally be above in z-order.
                // Only resize to keep position on display changes.
                widgetTaskIds[displayId] = task.taskId
                Log.i(
                    TAG,
                    "Desktop widget cards on display $displayId task=${task.taskId} " +
                        "bounds=[$left,$top][$right,$bottom]",
                )
            }
        }, 250)
    }

    private fun resizeExistingWidget(displayId: Int) {
        val taskId = widgetTaskIds[displayId] ?: return
        val metrics = displayMetrics(displayId) ?: return
        // Small, non-intrusive panel in top-right corner (rich but minimal)
        val width = (metrics.widthPixels * 0.26f).roundToInt().coerceIn(380, 520)
        val height = (metrics.heightPixels * 0.16f).roundToInt().coerceIn(160, 220)
        val left = (metrics.widthPixels - width - 24).coerceAtLeast(8)
        val top = 16
        val right = left + width
        val bottom = top + height
        ensureFreeformMode(displayId)
        runRoot("am task resize $taskId $left $top $right $bottom")
        Log.i(TAG, "Resized widget task $taskId on display $displayId after size change")
    }

    private fun cleanupStaleDesktopTasks() {
        val liveDisplays = getSystemService(DisplayManager::class.java).displays
            .mapTo(mutableSetOf()) { it.displayId }
        readTasksFromSystem()
            .filter { it.displayId != Display.DEFAULT_DISPLAY && it.displayId !in liveDisplays }
            .forEach { runRoot("am task remove ${it.taskId}") }
    }

    /**
     * DeX isolation: when a virtual desktop display goes away, finish its tasks
     * instead of letting them reappear on the phone screen.
     */
    private fun destroyDesktopDisplayTasks(displayId: Int) {
        if (displayId == Display.DEFAULT_DISPLAY) return
        try {
            val tasks = readTasksFromSystem().filter {
                it.displayId == displayId && it.packageName !in SESSION_EXCLUDED_PACKAGES
            }
            for (task in tasks) {
                runRoot("am task remove ${task.taskId}")
            }
            Log.i(TAG, "Destroyed ${tasks.size} desktop tasks for removed display $displayId")
        } catch (error: Exception) {
            Log.w(TAG, "Could not destroy desktop tasks for display $displayId", error)
        }
    }

    /**
     * Optional reopen of previously open freeform apps. Disabled by default —
     * desktop start should show only the shell (home/widgets).
     * Explicit workspaces still use [restoreWorkspace].
     */
    private fun restoreSessionAppsBehindHome(displayId: Int) {
        if (!preferences.getBoolean("_restore_session", false)) {
            launchDesktopHome(displayId)
            return
        }
        val packages = try {
            JSONArray(preferences.getString("_last_packages", "[]"))
        } catch (_: JSONException) {
            launchDesktopHome(displayId)
            return
        }
        for (index in 0 until packages.length()) {
            val packageName = packages.optString(index)
            if (!PACKAGE_PATTERN.matches(packageName)) continue
            if (packageName in SESSION_EXCLUDED_PACKAGES) continue
            try {
                launch(JSONObject().put("package", packageName).put("displayId", displayId))
            } catch (error: Exception) {
                Log.w(TAG, "Could not restore $packageName", error)
            }
        }
        val home = launchDesktopHome(displayId)
        if (home.exitCode != 0) {
            Log.w(TAG, "Could not re-focus desktop home after restore: ${home.output}")
        }
    }

    private fun watchTaskEvents() {
        while (!Thread.currentThread().isInterrupted) {
            logcatRestarts = 0
            try {
                // App-uid logcat cannot see system_server events (wm_task_to_front)
                // even with READ_LOGS on modern Pixel builds. Root is required.
                val process = ProcessBuilder(
                    "su",
                    "-c",
                    "logcat -b main -b system -b events -v tag -T 1",
                )
                    .redirectErrorStream(true)
                    .start()
                taskEventProcess = process
                process.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        // Never do root/network work on the logcat reader thread —
                        // that delays later events and loses the desktop-click window.
                        TaskEventParser.desktopTargetComponent(line)?.let { component ->
                            controlExecutor.execute {
                                launchDesktopTargetFromShell(component, System.currentTimeMillis())
                            }
                        }
                        if (line.contains("wm_task_") || line.contains("wm_activity_")) {
                            TaskEventParser.taskToFront(line)?.let { event ->
                                publishHostEvent(
                                    "task-focused",
                                    JSONObject()
                                        .put("taskId", event.taskId)
                                        .put("displayId", event.displayId),
                                )
                                controlExecutor.execute {
                                    val eventNow = System.currentTimeMillis()
                                    val tasks = if (eventNow - taskCacheAt >= TASK_EVENT_DEBOUNCE_MS) {
                                        refreshTaskCache()
                                    } else {
                                        cachedTasks.get()
                                    }
                                    updateDesktopWidgetVisibility(event, tasks)
                                    dismissIme(event.displayId)
                                    redirectPhoneTaskFromDesktopClick(event, eventNow)
                                }
                            }
                        }
                    }
                }
                process.waitFor(1, TimeUnit.SECONDS)
            } catch (error: Exception) {
                if (!Thread.currentThread().isInterrupted) {
                    Log.w(TAG, "Task event stream stopped", error)
                    logcatRestarts++
                    val backoffMs = (TASK_EVENT_BACKOFF_BASE_MS *
                        minOf(1 shl logcatRestarts, 32)).coerceAtMost(30_000L)
                    if (logcatRestarts > MAX_LOGCAT_RESTARTS) {
                        Log.e(TAG, "logcat restarted too many times ($logcatRestarts), task tracking disabled")
                        break
                    }
                    Log.i(TAG, "logcat backoff ${backoffMs}ms after restart $logcatRestarts")
                    Thread.sleep(backoffMs)
                }
            } finally {
                taskEventProcess = null
            }
        }
    }

    private fun markDesktopInput(request: JSONObject): JSONObject {
        val now = System.currentTimeMillis()
        val action = request.optString("action", "down").ifBlank { "down" }
        // Simple rate limit for high-frequency pointer move events to avoid flooding root shell
        if (action == "move" && now - lastInputRequestAt < INPUT_RATE_LIMIT_MS) {
            return JSONObject().put("ok", true).put("rateLimited", true)
        }
        lastInputRequestAt = now

        // Host may send 0 before it has synced the virtual display id.
        val requested = request.optInt("displayId", Display.DEFAULT_DISPLAY)
        val displayId = requested.takeIf {
            it != Display.DEFAULT_DISPLAY && displayMetrics(it) != null
        } ?: desktopDisplayId()
        val x = request.optInt("x", -1)
        val y = request.optInt("y", -1)

        // Freeform edge/corner drag: host maps scrcpy client pixels → Android display.
        if (displayId != Display.DEFAULT_DISPLAY && x >= 0 && y >= 0) {
            when (action) {
                "down" -> {
                    val hit = findFreeformEdgeHit(displayId, x, y)
                    if (hit != null) {
                        edgeResizeDrag = hit
                        runRoot("am task resizeable ${hit.taskId} 2")
                        Log.i(
                            TAG,
                            "Edge resize start task=${hit.taskId} edges=${hit.edges} at $x,$y",
                        )
                        return JSONObject()
                            .put("ok", true)
                            .put("displayId", displayId)
                            .put("edgeResize", true)
                            .put("taskId", hit.taskId)
                    }
                    edgeResizeDrag = null
                }
                "move" -> {
                    val drag = edgeResizeDrag
                    if (drag != null && drag.displayId == displayId) {
                        applyEdgeResizeDrag(drag, x, y)
                        return JSONObject().put("ok", true).put("edgeResize", true)
                    }
                }
                "up" -> {
                    val drag = edgeResizeDrag
                    edgeResizeDrag = null
                    if (drag != null) {
                        Log.i(TAG, "Edge resize end task=${drag.taskId}")
                        refreshTaskCache()
                        return JSONObject().put("ok", true).put("edgeResize", true)
                    }
                }
            }
        }

        // Only arm drawer-launch redirect on primary button downs that are not edge resizes.
        if (action != "down") {
            return JSONObject().put("ok", true).put("displayId", displayId)
        }

        // Capture the phone task ids before the launcher can create a task for
        // the clicked app. Taking this snapshot after the watcher starts races
        // the launcher event and can classify the new phone task as pre-existing.
        val baselinePhoneTaskIds = if (displayId != Display.DEFAULT_DISPLAY) {
            readTasks()
                .filter {
                    it.displayId == Display.DEFAULT_DISPLAY &&
                        it.packageName !in SESSION_EXCLUDED_PACKAGES
                }
                .mapTo(mutableSetOf()) { it.taskId }
        } else {
            emptySet()
        }
        val markedAt = System.currentTimeMillis()
        pendingDesktopDisplayId.set(displayId)
        lastDesktopInputAt.set(markedAt)
        val generation = launchWatchGeneration.incrementAndGet()
        lastShellLaunchAt.set(0L)
        lastShellLaunchPackage.set(null)
        // Polling is the reliable path: app-uid logcat cannot see WM events.
        if (displayId != Display.DEFAULT_DISPLAY) {
            serviceScope.launch {
                watchDesktopClickLaunches(
                    displayId,
                    markedAt,
                    generation,
                    baselinePhoneTaskIds,
                )
            }
        }
        Log.i(TAG, "Desktop input marked displayId=$displayId gen=$generation x=$x y=$y")
        // Prevent IME from appearing when interacting with desktop (including text fields).
        dismissIme(displayId)
        return JSONObject().put("ok", true).put("displayId", displayId)
    }

    private fun freeformDesktopApps(displayId: Int): List<DesktopTask> =
        readTasksFromSystem()
            .filter { it.displayId == displayId && it.visible }
            .filter { it.packageName !in SESSION_EXCLUDED_PACKAGES }
            .filter { it.packageName != PIXEL_LAUNCHER_PACKAGE }
            .filter { !it.component.contains("DesktopWidgetActivity") }
    /**
     * Hit-test freeform window edges/corners. Margin is large enough to click from
     * scrcpy without perfect freeform chrome.
     */
    private fun findFreeformEdgeHit(displayId: Int, x: Int, y: Int): EdgeResizeDrag? {
        val margin = EDGE_RESIZE_MARGIN_PX
        // Prefer the topmost freeform app that contains the point near an edge.
        for (task in freeformDesktopApps(displayId)) {
            val b = task.bounds
            val nearLeft = x in (b.left - margin)..(b.left + margin) &&
                y in (b.top - margin)..(b.bottom + margin)
            val nearRight = x in (b.right - margin)..(b.right + margin) &&
                y in (b.top - margin)..(b.bottom + margin)
            val nearTop = y in (b.top - margin)..(b.top + margin) &&
                x in (b.left - margin)..(b.right + margin)
            val nearBottom = y in (b.bottom - margin)..(b.bottom + margin) &&
                x in (b.left - margin)..(b.right + margin)
            // Interior top strip = move (all edges relative)
            val inTopBar = y in b.top..(b.top + EDGE_MOVE_BAR_PX) &&
                x in b.left..b.right && !nearLeft && !nearRight
            if (!nearLeft && !nearRight && !nearTop && !nearBottom && !inTopBar) continue

            var edges = 0
            if (inTopBar) {
                edges = EDGE_MOVE
            } else {
                if (nearLeft) edges = edges or EDGE_LEFT
                if (nearRight) edges = edges or EDGE_RIGHT
                if (nearTop) edges = edges or EDGE_TOP
                if (nearBottom) edges = edges or EDGE_BOTTOM
            }
            if (edges == 0) continue
            return EdgeResizeDrag(
                taskId = task.taskId,
                packageName = task.packageName,
                displayId = displayId,
                edges = edges,
                startBounds = Rect(b),
                startX = x,
                startY = y,
            )
        }
        return null
    }

    private fun applyEdgeResizeDrag(drag: EdgeResizeDrag, x: Int, y: Int) {
        val metrics = displayMetrics(drag.displayId) ?: return
        val dx = x - drag.startX
        val dy = y - drag.startY
        val b = drag.startBounds
        var left = b.left
        var top = b.top
        var right = b.right
        var bottom = b.bottom
        val minW = (metrics.widthPixels * 0.18f).roundToInt().coerceAtLeast(280)
        val minH = (metrics.heightPixels * 0.18f).roundToInt().coerceAtLeast(240)

        when {
            drag.edges == EDGE_MOVE -> {
                val w = right - left
                val h = bottom - top
                left = (b.left + dx).coerceIn(0, metrics.widthPixels - w)
                top = (b.top + dy).coerceIn(0, metrics.heightPixels - h)
                right = left + w
                bottom = top + h
            }
            else -> {
                if (drag.edges and EDGE_LEFT != 0) {
                    left = (b.left + dx).coerceIn(0, right - minW)
                }
                if (drag.edges and EDGE_RIGHT != 0) {
                    right = (b.right + dx).coerceIn(left + minW, metrics.widthPixels)
                }
                if (drag.edges and EDGE_TOP != 0) {
                    top = (b.top + dy).coerceIn(0, bottom - minH)
                }
                if (drag.edges and EDGE_BOTTOM != 0) {
                    bottom = (b.bottom + dy).coerceIn(top + minH, metrics.heightPixels)
                }
            }
        }
        runRoot("am task resize ${drag.taskId} $left $top $right $bottom")
        rememberBounds(drag.packageName, Rect(left, top, right, bottom), drag.displayId)
    }

    /** Resolved desktop display if a recent host click marked a launch window. */
    private fun desktopLaunchDisplayId(now: Long): Int? {
        val markedAt = lastDesktopInputAt.get()
        if (markedAt == 0L || now - markedAt !in 0..DESKTOP_LAUNCH_WINDOW_MS) return null
        val requested = pendingDesktopDisplayId.get()
        val resolved = requested.takeIf {
            it != Display.DEFAULT_DISPLAY && displayMetrics(it) != null
        } ?: desktopDisplayId()
        return resolved.takeIf { it != Display.DEFAULT_DISPLAY }
    }

    /**
     * After a desktop-window click, if Android wrongly starts the app on the
     * phone, open a freeform copy on the virtual desktop and remove only the
     * **new** phone task — never steal a pre-existing phone app.
     */
    private suspend fun watchDesktopClickLaunches(
        displayId: Int,
        markedAt: Long,
        generation: Long,
        baselineTaskIds: Set<Int>,
    ) {
        val excluded = SESSION_EXCLUDED_PACKAGES
        // Snapshot ALL phone-display taskIds before the watcher is armed. On
        // Android 12+ a freshly-launched task can stay visible=false through
        // the WM transition for >2s; task birth, not visibility, is the signal.
        Log.i(
            TAG,
            "Launch watcher armed display=$displayId baseline=${baselineTaskIds.size} gen=$generation",
        )
        val deadline = markedAt + DESKTOP_LAUNCH_WINDOW_MS
        while (System.currentTimeMillis() < deadline) {
            if (launchWatchGeneration.get() != generation) return
            if (lastDesktopInputAt.get() != markedAt) return
            delay(DESKTOP_LAUNCH_POLL_MS)
            if (launchWatchGeneration.get() != generation) return
            if (lastDesktopInputAt.get() != markedAt) return

            val phoneTasks = try {
                readTasksFromSystem().filter {
                    it.displayId == Display.DEFAULT_DISPLAY &&
                        it.packageName !in excluded
                }
            } catch (error: Exception) {
                Log.w(TAG, "Launch watcher poll failed", error)
                continue
            }

            val candidate = phoneTasks.firstOrNull { it.taskId !in baselineTaskIds }
            if (candidate != null) {
                if (!lastDesktopInputAt.compareAndSet(markedAt, 0L)) return
                pendingDesktopDisplayId.compareAndSet(displayId, Display.DEFAULT_DISPLAY)
                mirrorDesktopLaunchWithoutStealingPhone(candidate, displayId)
                return
            }
        }
        Log.i(TAG, "Launch watcher timed out gen=$generation")
    }

    /**
     * DeX isolation for mis-routed drawer launches:
     * 1) start/focus freeform on the virtual desktop
     * 2) remove only the new phone task (never move-stack a pre-existing phone app)
     */
    private fun mirrorDesktopLaunchWithoutStealingPhone(task: DesktopTask, displayId: Int) {
        Log.i(
            TAG,
            "Desktop mirror ${task.packageName} phoneTask=${task.taskId} -> display $displayId",
        )
        ensureFreeformMode(displayId)
        // Resolve to canonical launch component (drawer clicks may log non-main activities).
        val launchIntent = packageManager.getLaunchIntentForPackage(task.packageName) ?: run {
            Log.w(TAG, "No launch intent for spilled task ${task.packageName}")
            // still remove the phone spill so it doesn't stay on handset
            runRoot("am task remove ${task.taskId}")
            return
        }
        val launchComponent = launchIntent.component?.flattenToShortString() ?: task.component

        val bounds = (rememberedBounds(task.packageName, displayId) ?:
            boundsForProfile(profileFor(task.packageName), displayId) ?:
            defaultFreeformBounds(displayId))
            ?.takeIf { validBoundsForDisplay(it, displayId) }
            ?: defaultFreeformBounds(displayId)
        val focused = launchFromShell(launchComponent, displayId, bounds, newInstance = true)
        if (focused.exitCode != 0) {
            Log.w(TAG, "Could not open ${task.packageName} on display $displayId: ${focused.output}")
            // Do not touch the phone task if the desktop launch failed.
            return
        }
        // Drop the phone-side task that was created by the mis-routed launch so
        // the handset UI stays undisturbed.
        val removed = runRoot("am task remove ${task.taskId}")
        if (removed.exitCode != 0) {
            Log.w(TAG, "Could not remove phone spill task ${task.taskId}: ${removed.output}")
        }
        refreshTaskCache()
        Log.i(
            TAG,
            "Desktop mirror complete for ${task.packageName} on $displayId " +
                "(removed phone task ${task.taskId})",
        )
    }

    @Deprecated("Use mirrorDesktopLaunchWithoutStealingPhone for DeX isolation")
    private fun redirectTaskToDesktop(task: DesktopTask, displayId: Int) {
        mirrorDesktopLaunchWithoutStealingPhone(task, displayId)
    }

    private fun updateDesktopWidgetVisibility(
        event: TaskToFrontEvent,
        tasks: List<DesktopTask>,
    ) {
        // The clock/battery panel is hosted by the freeform `DesktopWidgetActivity`
        // launched once from `showDesktopWidgetCards`. It sits in the normal
        // activity/window stack (NOT a SYSTEM_ALERT_WINDOW overlay), so newly
        // launched apps naturally render on top. No work is needed on the
        // task-to-front path anymore.
        if (event.displayId == Display.DEFAULT_DISPLAY) return
        widgetForegroundTaskIds[event.displayId] = event.taskId
        val task = tasks.firstOrNull { it.taskId == event.taskId }
        if (task != null) {
            if (task.packageName == PIXEL_LAUNCHER_PACKAGE) {
                dismissIme(event.displayId)
            }
            return
        }
        // wm_task_created can refresh the cache just before wm_task_to_front arrives.
        // Re-read after ActivityManager has published the new task details.
        controlExecutor.execute {
            Thread.sleep(TASK_REPARENT_SETTLE_MS)
            if (widgetForegroundTaskIds[event.displayId] != event.taskId) return@execute
            val settledTask = refreshTaskCache().firstOrNull { it.taskId == event.taskId }
                ?: return@execute
            if (settledTask.packageName == PIXEL_LAUNCHER_PACKAGE) {
                dismissIme(event.displayId)
            }
        }
    }

    private fun launchDesktopTargetFromShell(component: String, now: Long) {
        val markedAt = lastDesktopInputAt.get()
        val displayId = desktopLaunchDisplayId(now) ?: return
        if (!COMPONENT_PATTERN.matches(component)) return
        val packageName = component.substringBefore('/')
        if (packageName in SESSION_EXCLUDED_PACKAGES) return
        // ActivityTaskManager emits several targetComponent records for one
        // launcher click, including records generated by our own am start.
        // Do not recursively relaunch the same package within this click's
        // launch window.
        if (lastShellLaunchPackage.get() == packageName &&
            now - lastShellLaunchAt.get() in 0..DESKTOP_LAUNCH_WINDOW_MS) {
            return
        }

        // Resolve to proper launch intent/component (like tray launches do).
        // The logged cmp= may be an internal activity; getLaunchIntent ensures the main launcher entrypoint.
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName) ?: run {
            Log.w(TAG, "No launch intent for $packageName from drawer click")
            return
        }
        val launchComponent = launchIntent.component?.flattenToShortString() ?: run {
            Log.w(TAG, "No component in launch intent for $packageName")
            return
        }

        val bounds = (rememberedBounds(packageName, displayId) ?:
            boundsForProfile(profileFor(packageName), displayId))
            ?.takeIf { validBoundsForDisplay(it, displayId) }
        val launched = launchFromShell(launchComponent, displayId, bounds)
        if (launched.exitCode != 0) {
            Log.w(TAG, "Could not launch $packageName on display $displayId: ${launched.output}")
            return
        }
        // Do NOT consume the click mark here. The launcher fires its own
        // startActivity from the Pixel launcher task (displayId=0) at the same
        // moment, and on modern Android releases ActivityManager often coalesces
        // both intents onto a single task on the phone display. Our am start
        // exits 0 without us knowing which display the result actually landed on.
        // watchDesktopClickLaunches, armed in markDesktopInput, is the safety
        // net: it polls for any new phone-display task in this package and, if
        // found, runs mirrorDesktopLaunchWithoutStealingPhone to remove the
        // phone task and re-create it on the desktop. Consuming the mark here
        // would abort that loop before it could clean up the mis-routed task
        // and the app would stay on the phone.
        if (bounds != null) {
            rememberBounds(packageName, bounds, displayId)
        }
        if (packageName == PIXEL_LAUNCHER_PACKAGE) {
            dismissIme(displayId)
        }
        lastShellLaunchPackage.set(packageName)
        lastShellLaunchAt.set(now)
        Log.i(TAG, "Launched $packageName on desktop display $displayId from shell target")
    }

    private fun redirectPhoneTaskFromDesktopClick(event: TaskToFrontEvent, now: Long) {
        val markedAt = lastDesktopInputAt.get()
        val displayId = desktopLaunchDisplayId(now) ?: return
        if (event.displayId != Display.DEFAULT_DISPLAY) return

        Thread.sleep(TASK_REPARENT_SETTLE_MS)
        // Mark may have been consumed by the poll watcher or shell-target launch.
        if (lastDesktopInputAt.get() != markedAt) return
        val task = readTasksFromSystem().firstOrNull {
            it.taskId == event.taskId &&
                it.displayId == Display.DEFAULT_DISPLAY &&
                it.packageName !in SESSION_EXCLUDED_PACKAGES
        } ?: return
        // Drawer noise can surface launcher/phone chrome first. Keep the mark
        // until a real app task appears on the phone display.
        if (task.packageName == PIXEL_LAUNCHER_PACKAGE) return
        if (!lastDesktopInputAt.compareAndSet(markedAt, 0L)) return
        pendingDesktopDisplayId.compareAndSet(displayId, Display.DEFAULT_DISPLAY)
        mirrorDesktopLaunchWithoutStealingPhone(task, displayId)
    }

    private fun refreshTaskCache(): List<DesktopTask> {
        val tasks = readTasksFromSystem()
        cachedTasks.set(tasks)
        taskCacheAt = System.currentTimeMillis()
        return tasks
    }

    private fun handlePhoneControl(intent: Intent) {
        val displayId = desktopDisplayId()
        if (displayId == Display.DEFAULT_DISPLAY) return
        val display = getSystemService(DisplayManager::class.java).getDisplay(displayId) ?: return
        val metrics = android.util.DisplayMetrics()
        @Suppress("DEPRECATION")
        display.getRealMetrics(metrics)
        val x = (intent.getFloatExtra("x", 0f).coerceIn(0f, 1f) * metrics.widthPixels).toInt()
        val y = (intent.getFloatExtra("y", 0f).coerceIn(0f, 1f) * metrics.heightPixels).toInt()
        val command = when (intent.getStringExtra("control")) {
            "move" -> "input mouse -d $displayId motionevent MOVE $x $y"
            "click" -> "input mouse -d $displayId tap $x $y"
            "scroll" -> {
                val delta = intent.getFloatExtra("delta", 0f).coerceIn(-8f, 8f)
                "input mouse -d $displayId scroll $x $y --axis VSCROLL,$delta"
            }
            "back" -> "input -d $displayId keyevent KEYCODE_BACK"
            "home" -> {
                launchDesktopHome(displayId)
                return
            }
            "recents" -> "input -d $displayId keyevent KEYCODE_APP_SWITCH"
            "keyboard" -> "settings put secure show_ime_with_hard_keyboard 1; cmd input_method show"
            "media-play-pause" -> "input keyevent KEYCODE_MEDIA_PLAY_PAUSE"
            "presentation-next" -> "input -d $displayId keyevent KEYCODE_PAGE_DOWN"
            "presentation-previous" -> "input -d $displayId keyevent KEYCODE_PAGE_UP"
            "workspace-next" -> {
                cycleWorkspace(displayId)
                return
            }
            "text" -> {
                val value = intent.getStringExtra("text")?.take(MAX_CONTROL_TEXT_LENGTH) ?: return
                "input -d $displayId text ${shellQuote(value.replace(" ", "%s"))}"
            }
            else -> return
        }
        runRoot(command)
    }

    private fun launch(request: JSONObject): JSONObject {
        val packageName = requirePackage(request.getString("package"))
        val displayId = request.optInt("displayId", desktopDisplayId())
        if (displayId == Display.DEFAULT_DISPLAY) {
            return errorResponse("desktop display unavailable; refusing to launch on the phone", 404)
        }
        val newInstance = request.optBoolean("newInstance", false)
        val requestedBounds = request.optJSONObject("bounds")?.toRect()
        val bounds = (requestedBounds ?: rememberedBounds(packageName, displayId) ?:
            boundsForProfile(profileFor(packageName), displayId))
            ?.takeIf { validBoundsForDisplay(it, displayId) }
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: return errorResponse("no launch intent")
        val component = intent.component?.flattenToShortString()
            ?: return errorResponse("launch component missing")

        // DeX isolation: only reuse tasks already on the virtual desktop.
        // Never move-stack a phone task onto the PC desktop (that steals the
        // handset UI). Open a separate freeform instance on the desktop instead.
        val existingOnDesktop = readTasks()
            .firstOrNull { it.packageName == packageName && it.displayId == displayId }
            .takeUnless { newInstance }
        if (existingOnDesktop != null) {
            val focused = launchFromShell(component, displayId, bounds)
            if (focused.exitCode == 0 && bounds != null) {
                val resized = runRoot(
                    "am task resize ${existingOnDesktop.taskId} ${bounds.left} ${bounds.top} " +
                        "${bounds.right} ${bounds.bottom}",
                )
                if (resized.exitCode == 0) rememberBounds(packageName, bounds, displayId)
                runRoot("am task focus ${existingOnDesktop.taskId}")
            }
            return focused.toJson()
                .put("package", packageName)
                .put("displayId", displayId)
                .put("bounds", bounds?.toJson())
                .put("movedExisting", false)
        }

        // Always create on the requested virtual display — never via startActivity()
        // (which resolves against the phone display first on some Pixel builds).
        val launched = launchFromShell(component, displayId, bounds, newInstance = true)
        if (launched.exitCode != 0) {
            return launched.toJson()
                .put("package", packageName)
                .put("displayId", displayId)
        }

        if (bounds != null) rememberBounds(packageName, bounds, displayId)
        return JSONObject()
            .put("ok", true)
            .put("package", packageName)
            .put("displayId", displayId)
            .put("bounds", bounds?.toJson())
            .put("newInstance", true)
    }

    private fun taskAction(request: JSONObject): JSONObject {
        val action = request.getString("action")
        val packageName = request.optString("package").takeIf { it.isNotEmpty() }
        val taskId = request.optInt("taskId", -1)
        val displayId = request.optInt("displayId", desktopDisplayId())

        val result = when (action) {
            "focus" -> {
                require(packageName != null) { "focus requires package" }
                return launch(JSONObject().put("package", packageName).put("displayId", displayId))
            }
            "close" -> {
                if (taskId >= 0) {
                    runRoot("am task remove $taskId")
                } else {
                    require(packageName != null) { "close requires taskId or package" }
                    runRoot("am force-stop --user current ${shellQuote(requirePackage(packageName))}")
                }
            }
            "minimize" -> launchDesktopHome(displayId)
            "move-phone" -> {
                require(taskId >= 0) { "move-phone requires taskId" }
                val task = readTasks().firstOrNull { it.taskId == taskId }
                    ?: throw IllegalArgumentException("task not found")
                runRoot("am display move-stack ${task.rootTaskId} ${Display.DEFAULT_DISPLAY}")
            }
            "new-window" -> {
                require(packageName != null) { "new-window requires package" }
                return launch(
                    JSONObject()
                        .put("package", packageName)
                        .put("displayId", displayId)
                        .put("newInstance", true),
                )
            }
            "resize" -> {
                require(taskId >= 0) { "resize requires taskId" }
                val bounds = request.getJSONObject("bounds").toRect()
                require(validBoundsForDisplay(bounds, displayId)) { "bounds are outside the target display" }
                runRoot("am task resize $taskId ${bounds.left} ${bounds.top} ${bounds.right} ${bounds.bottom}")
                    .also {
                        if (it.exitCode == 0 && packageName != null) {
                            rememberBounds(packageName, bounds, displayId)
                        }
                    }
            }
            "preset" -> {
                require(taskId >= 0) { "preset requires taskId" }
                val metrics = displayMetrics(displayId) ?: error("target display is unavailable")
                val bounds = DesktopBounds.preset(request.getString("preset"), metrics.widthPixels, metrics.heightPixels)
                runRoot("am task resize $taskId ${bounds.left} ${bounds.top} ${bounds.right} ${bounds.bottom}")
                    .also {
                        if (it.exitCode == 0 && packageName != null) {
                            rememberBounds(packageName, bounds, displayId)
                        }
                    }
            }
            else -> throw IllegalArgumentException("unknown task action")
        }
        return result.toJson()
    }

    private fun systemAction(request: JSONObject): JSONObject {
        val displayId = request.optInt("displayId", desktopDisplayId())
        val command = when (request.getString("action")) {
            "home" -> return launchDesktopHome(displayId).toJson()
            "recents" -> "input -d $displayId keyevent KEYCODE_APP_SWITCH"
            "back" -> "input -d $displayId keyevent KEYCODE_BACK"
            // Status bar / sleep without -d hit the phone. Keep them off the
            // DeX path so tray actions do not alter the handset UI.
            "notifications" -> return errorResponse("phone status bar is not controlled from desktop", 403)
            "quick-settings" -> return errorResponse("phone quick settings are not controlled from desktop", 403)
            "collapse-panels" -> return errorResponse("phone status bar is not controlled from desktop", 403)
            "lock" -> return JSONObject()
                .put("ok", false)
                .put("error", "phone lock is not controlled from desktop")
            "audio-output" ->
                "am broadcast -a com.android.systemui.action.LAUNCH_SYSTEM_MEDIA_OUTPUT_DIALOG " +
                    "-p com.android.systemui"
            "keyboard-desktop" -> "settings put secure show_ime_with_hard_keyboard 1"
            "keyboard-physical" -> "settings put secure show_ime_with_hard_keyboard 0"
            "notification-access" ->
                "am start --user current --display ${Display.DEFAULT_DISPLAY} " +
                    "-a android.settings.ACTION_NOTIFICATION_LISTENER_SETTINGS"
            "phone-screen-off" -> "input -d ${Display.DEFAULT_DISPLAY} keyevent KEYCODE_SLEEP"
            "phone-screen-on" -> "input -d ${Display.DEFAULT_DISPLAY} keyevent KEYCODE_WAKEUP"
            "media-play-pause" -> "input keyevent KEYCODE_MEDIA_PLAY_PAUSE"
            "presentation-next" -> "input -d $displayId keyevent KEYCODE_PAGE_DOWN"
            "presentation-previous" -> "input -d $displayId keyevent KEYCODE_PAGE_UP"
            "touchpad" -> return openPhoneControl()
            "workspace-next" -> return cycleWorkspace(displayId)
            "snap-left" -> return snapFocusedTask(displayId, "left")
            "snap-right" -> return snapFocusedTask(displayId, "right")
            "maximize" -> return snapFocusedTask(displayId, "maximize")
            "restore" -> return snapFocusedTask(displayId, "restore")
            "smaller" -> return snapFocusedTask(displayId, "smaller")
            "larger" -> return snapFocusedTask(displayId, "larger")
            "phone" -> return snapFocusedTask(displayId, "phone")
            "tablet" -> return snapFocusedTask(displayId, "tablet")
            "close-focused" -> return closeFocusedDesktopApp(displayId)
            "agent-settings" -> {
                val start = runRoot(
                    "am start --user current -n com.rewritedex.nativeagent/.SettingsActivity"
                )
                return start.toJson()
            }
            "widgets-show" -> {
                controlExecutor.execute { showDesktopWidgetCards(displayId) }
                return JSONObject().put("ok", true).put("action", "widgets-show")
            }
            "widgets-hide" -> {
                readTasksFromSystem()
                    .filter { it.displayId == displayId && it.component.contains("DesktopWidgetActivity") }
                    .forEach { runRoot("am task remove ${it.taskId}") }
                widgetTaskIds.remove(displayId)
                return JSONObject().put("ok", true).put("action", "widgets-hide")
            }
            else -> throw IllegalArgumentException("unknown system action")
        }
        return runRoot(command).toJson()
    }

    /**
     * Closes the topmost freeform app on the virtual desktop (not the launcher
     * shell or widget cards). Used by Win+W / Ctrl+W / tray "Close focused app".
     */
    private fun closeFocusedDesktopApp(displayId: Int): JSONObject {
        if (displayId == Display.DEFAULT_DISPLAY) {
            return JSONObject().put("ok", false).put("error", "desktop display unavailable")
        }
        val target = readTasksFromSystem()
            .filter { it.displayId == displayId && it.visible }
            .filter { it.packageName !in SESSION_EXCLUDED_PACKAGES }
            .filter { !it.component.contains("DesktopWidgetActivity") }
            .filter { it.packageName != PIXEL_LAUNCHER_PACKAGE }
            .firstOrNull()
            ?: return JSONObject().put("ok", false).put("error", "no focused desktop app")
        val removed = runRoot("am task remove ${target.taskId}")
        if (removed.exitCode != 0) {
            Log.w(TAG, "Could not close ${target.packageName}: ${removed.output}")
            return removed.toJson().put("package", target.packageName).put("taskId", target.taskId)
        }
        Log.i(TAG, "Closed focused desktop app ${target.packageName} task=${target.taskId}")
        refreshTaskCache()
        return JSONObject()
            .put("ok", true)
            .put("package", target.packageName)
            .put("taskId", target.taskId)
    }

    private fun openPhoneControl(): JSONObject {
        val intent = Intent(this, DesktopControlActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
        }
        startActivity(
            intent,
            ActivityOptions.makeBasic().apply { launchDisplayId = Display.DEFAULT_DISPLAY }.toBundle(),
        )
        return JSONObject().put("ok", true)
    }

    private fun cycleWorkspace(displayId: Int): JSONObject {
        val names = WorkspaceStore.names(preferences)
        if (names.isEmpty()) return JSONObject().put("ok", false).put("error", "no saved workspaces")
        val current = preferences.getInt("_workspace_current", -1)
        val next = (current + 1).mod(names.size)
        preferences.edit().putInt("_workspace_current", next).apply()
        return restoreWorkspace(
            JSONObject()
                .put("name", names[next])
                .put("displayId", displayId)
                .put("replace", true),
        )
    }

    private fun focusedDesktopApp(displayId: Int): DesktopTask? =
        readTasks()
            .filter { it.displayId == displayId && it.visible }
            .filter { it.packageName !in SESSION_EXCLUDED_PACKAGES }
            .filter { it.packageName != PIXEL_LAUNCHER_PACKAGE }
            .filter { !it.component.contains("DesktopWidgetActivity") }
            .firstOrNull()

    private fun snapFocusedTask(displayId: Int, preset: String): JSONObject {
        val task = focusedDesktopApp(displayId)
            ?: return JSONObject().put("ok", false).put("error", "no focused desktop app")
        val metrics = displayMetrics(displayId)
            ?: return JSONObject().put("ok", false).put("error", "desktop display unavailable")
        runRoot("am task resizeable ${task.taskId} 2")
        val bounds = when (preset) {
            "smaller" -> DesktopBounds.scaleAboutCenter(
                task.bounds, metrics.widthPixels, metrics.heightPixels, 0.82f,
            )
            "larger" -> DesktopBounds.scaleAboutCenter(
                task.bounds, metrics.widthPixels, metrics.heightPixels, 1.22f,
            )
            else -> DesktopBounds.preset(preset, metrics.widthPixels, metrics.heightPixels)
        }
        val resized = runRoot(
            "am task resize ${task.taskId} ${bounds.left} ${bounds.top} ${bounds.right} ${bounds.bottom}",
        )
        if (resized.exitCode == 0) {
            rememberBounds(task.packageName, bounds, displayId)
            refreshTaskCache()
        }
        return resized.toJson()
            .put("package", task.packageName)
            .put("taskId", task.taskId)
            .put("preset", preset)
            .put("bounds", bounds.toJson())
    }

    private fun tasksResponse(): JSONObject {
        val tasks = JSONArray()
        readTasks().forEach { task ->
            val label = runCatching {
                packageManager.getApplicationLabel(packageManager.getApplicationInfo(task.packageName, 0)).toString()
            }.getOrDefault(task.packageName)
            tasks.put(
                JSONObject()
                    .put("rootTaskId", task.rootTaskId)
                    .put("taskId", task.taskId)
                    .put("displayId", task.displayId)
                    .put("package", task.packageName)
                    .put("label", label)
                    .put("component", task.component)
                    .put("bounds", task.bounds.toJson())
                    .put("visible", task.visible),
            )
        }
        return JSONObject().put("ok", true).put("tasks", tasks)
    }

    private fun readTasks(): List<DesktopTask> {
        val cached = cachedTasks.get()
        if (cached.isNotEmpty() && System.currentTimeMillis() - taskCacheAt < TASK_CACHE_MAX_AGE_MS) {
            return cached
        }
        return refreshTaskCache()
    }

    private fun readTasksFromSystem(): List<DesktopTask> {
        val output = runRoot("am stack list").output
        if (output.isNotBlank() && output.contains("RootTask")) {
            return DesktopTaskParser.parse(output).map { task ->
                DesktopTask(
                    rootTaskId = task.rootTaskId,
                    taskId = task.taskId,
                    displayId = task.displayId,
                    packageName = task.packageName,
                    component = task.component,
                    bounds = Rect(
                        task.bounds.left,
                        task.bounds.top,
                        task.bounds.right,
                        task.bounds.bottom,
                    ),
                    visible = task.visible,
                )
            }
        }
        // Fallback for Android releases where `am stack list` has been removed.
        val dumpsysOutput = runRoot("dumpsys activity activities").output
        return DumpsysActivitiesParser.parse(dumpsysOutput).map { task ->
            DesktopTask(
                rootTaskId = task.rootTaskId,
                taskId = task.taskId,
                displayId = task.displayId,
                packageName = task.packageName,
                component = task.component,
                bounds = Rect(
                    task.bounds.left,
                    task.bounds.top,
                    task.bounds.right,
                    task.bounds.bottom,
                ),
                visible = task.visible,
            )
        }
    }

    private fun saveSession(): JSONObject {
        val desktopId = desktopDisplayId()
        val saved = JSONArray()
        if (desktopId == Display.DEFAULT_DISPLAY) {
            return JSONObject().put("ok", true).put("saved", saved)
        }
        // Remember freeform window bounds for next manual launch, but do not
        // persist a package list for auto-restore (that was reopening apps
        // like Settings / Zetamod on every desktop start).
        val desktopApps = readTasks()
            .filter { it.displayId == desktopId && it.packageName !in SESSION_EXCLUDED_PACKAGES }
            .distinctBy { it.packageName }
        for (task in desktopApps) {
            rememberBounds(task.packageName, task.bounds, desktopId)
        }
        preferences.edit().putString("_last_packages", "[]").apply()
        return JSONObject().put("ok", true).put("saved", saved)
    }

    private fun sessionResponse(): JSONObject {
        val apps = JSONArray()
        preferences.all.entries
            .filter { !it.key.startsWith('_') }
            .filter { it.key !in SESSION_EXCLUDED_PACKAGES }
            .sortedBy { it.key }
            .forEach { (packageName, value) ->
                val bounds = rememberedBounds(packageName, desktopDisplayId())
                apps.put(JSONObject().put("package", packageName).put("bounds", bounds?.toJson()))
            }
        return JSONObject()
            .put("ok", true)
            .put("apps", apps)
            .put("lastPackages", JSONArray(preferences.getString("_last_packages", "[]")))
    }

    private fun saveWorkspace(request: JSONObject): JSONObject {
        val name = WorkspaceStore.requireName(request.getString("name"))
        val displayId = request.optInt("displayId", desktopDisplayId())
        require(displayId != Display.DEFAULT_DISPLAY) { "desktop display is unavailable" }
        val metrics = displayMetrics(displayId) ?: error("desktop display is unavailable")
        val apps = JSONArray()
        readTasksFromSystem()
            .filter { it.displayId == displayId && it.packageName !in SESSION_EXCLUDED_PACKAGES }
            .distinctBy { it.packageName }
            .forEach { task ->
                apps.put(
                    JSONObject()
                        .put("package", task.packageName)
                        .put("profile", profileFor(task.packageName).wireName)
                        .put(
                            "bounds",
                            DesktopBounds.encodeNormalized(
                                task.bounds,
                                metrics.widthPixels,
                                metrics.heightPixels,
                            ),
                        ),
                )
            }
        WorkspaceStore.save(preferences, name, apps)
        return JSONObject().put("ok", true).put("name", name).put("apps", apps.length())
    }

    private fun restoreWorkspace(request: JSONObject): JSONObject {
        val name = WorkspaceStore.requireName(request.getString("name"))
        val displayId = request.optInt("displayId", desktopDisplayId())
        require(displayId != Display.DEFAULT_DISPLAY) { "desktop display is unavailable" }
        if (request.optBoolean("replace", true)) {
            readTasksFromSystem()
                .filter { it.displayId == displayId && it.packageName !in SESSION_EXCLUDED_PACKAGES }
                .forEach { runRoot("am task remove ${it.taskId}") }
        }
        val metrics = displayMetrics(displayId) ?: error("desktop display is unavailable")
        val apps = WorkspaceStore.load(preferences, name)
            ?: throw IllegalArgumentException("workspace not found")
        val restored = JSONArray()
        for (index in 0 until apps.length()) {
            val item = apps.optJSONObject(index) ?: continue
            val packageName = item.optString("package")
            if (!PACKAGE_PATTERN.matches(packageName)) continue
            val bounds = DesktopBounds.decodeNormalized(
                item.optString("bounds"),
                metrics.widthPixels,
                metrics.heightPixels,
            )
            val launchRequest = JSONObject().put("package", packageName).put("displayId", displayId)
            bounds?.let { launchRequest.put("bounds", it.toJson()) }
            if (launch(launchRequest).optBoolean("ok")) restored.put(packageName)
        }
        return JSONObject().put("ok", true).put("name", name).put("restored", restored)
    }

    private fun deleteWorkspace(request: JSONObject): JSONObject {
        val name = WorkspaceStore.requireName(request.getString("name"))
        WorkspaceStore.delete(preferences, name)
        return JSONObject().put("ok", true).put("name", name)
    }

    private fun notificationAccessEnabled(): Boolean {
        val enabled = android.provider.Settings.Secure.getString(
            contentResolver,
            "enabled_notification_listeners",
        ).orEmpty()
        val component = ComponentName(this, DesktopNotificationListenerService::class.java)
        return enabled.split(':').any { ComponentName.unflattenFromString(it) == component }
    }

    private fun notificationsResponse(): JSONObject {
        val storage = getSharedPreferences(DesktopNotificationListenerService.PREFERENCES, MODE_PRIVATE)
        val notifications = try {
            JSONArray(storage.getString(DesktopNotificationListenerService.KEY_ENTRIES, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        return JSONObject()
            .put("ok", true)
            .put("enabled", notificationAccessEnabled())
            .put("notifications", notifications)
    }

    private fun clearNotifications(): JSONObject {
        getSharedPreferences(DesktopNotificationListenerService.PREFERENCES, MODE_PRIVATE)
            .edit().remove(DesktopNotificationListenerService.KEY_ENTRIES).apply()
        return JSONObject().put("ok", true)
    }

    private fun exportsDirectory(): java.io.File =
        java.io.File(getExternalFilesDir(null), "Exports").apply { mkdirs() }

    private fun exportsResponse(): JSONObject {
        val exports = JSONArray()
        exportsDirectory().listFiles()?.filter { it.isFile }?.sortedBy { it.lastModified() }?.forEach { file ->
            exports.put(
                JSONObject()
                    .put("name", file.name)
                    .put("path", file.absolutePath)
                    .put("size", file.length())
                    .put("modified", file.lastModified()),
            )
        }
        return JSONObject().put("ok", true).put("exports", exports)
    }

    private fun acknowledgeExport(request: JSONObject): JSONObject {
        val name = request.getString("name")
        require(name == java.io.File(name).name) { "invalid export name" }
        val file = java.io.File(exportsDirectory(), name).canonicalFile
        require(file.parentFile == exportsDirectory().canonicalFile) { "invalid export path" }
        return JSONObject().put("ok", file.delete() || !file.exists()).put("name", name)
    }

    private fun profilesResponse(): JSONObject {
        val profiles = JSONObject()
        preferences.all.entries
            .filter { it.key.startsWith("_profile_") }
            .forEach { (key, value) -> profiles.put(key.removePrefix("_profile_"), value) }
        return JSONObject()
            .put("ok", true)
            .put("profiles", profiles)
            .put("available", JSONArray(DesktopProfile.entries.map { it.wireName }))
    }

    private fun updateProfile(request: JSONObject): JSONObject {
        val packageName = requirePackage(request.getString("package"))
        val profile = DesktopProfile.fromWireName(request.getString("profile"))
        require(profile.wireName == request.getString("profile")) { "unknown desktop profile" }
        preferences.edit().putString("_profile_$packageName", profile.wireName).apply()
        if (request.optBoolean("clearRememberedBounds", true)) {
            preferences.edit().remove(packageName).apply()
        }
        return JSONObject().put("ok", true).put("package", packageName).put("profile", profile.wireName)
    }

    private fun wallpaperPreferences(): android.content.SharedPreferences =
        createDeviceProtectedStorageContext().getSharedPreferences(
            DesktopWallpaperService.PREFERENCES,
            MODE_PRIVATE,
        )

    private fun wallpaperStatus(): JSONObject {
        val preferences = wallpaperPreferences()
        val index = DesktopWallpaperService.currentIndex(preferences)
        return JSONObject()
            .put("ok", true)
            .put("index", index)
            .put("name", DesktopWallpaperService.THEMES[index].name)
            .put("themes", JSONArray(DesktopWallpaperService.THEMES.map { it.name }))
            .put(
                "intervalMinutes",
                preferences.getInt(
                    DesktopWallpaperService.KEY_INTERVAL_MINUTES,
                    DesktopWallpaperService.DEFAULT_INTERVAL_MINUTES,
                ),
            )
            .put(
                "dim",
                preferences.getFloat(DesktopWallpaperService.KEY_DIM, DesktopWallpaperService.DEFAULT_DIM),
            )
    }

    private fun wallpaperAction(request: JSONObject): JSONObject {
        val preferences = wallpaperPreferences()
        when (request.getString("action")) {
            "next" -> DesktopWallpaperService.selectNext(preferences)
            "select" -> {
                val index = request.getInt("index")
                require(index in DesktopWallpaperService.THEMES.indices) { "invalid wallpaper index" }
                preferences.edit().putInt(DesktopWallpaperService.KEY_INDEX, index).apply()
            }
            "configure" -> {
                val interval = request.optInt(
                    "intervalMinutes",
                    preferences.getInt(
                        DesktopWallpaperService.KEY_INTERVAL_MINUTES,
                        DesktopWallpaperService.DEFAULT_INTERVAL_MINUTES,
                    ),
                )
                val dim = request.optDouble(
                    "dim",
                    preferences.getFloat(
                        DesktopWallpaperService.KEY_DIM,
                        DesktopWallpaperService.DEFAULT_DIM,
                    ).toDouble(),
                ).toFloat()
                require(interval == 0 || interval in 15..1440) { "interval must be 0 or between 15 and 1440" }
                require(dim in 0f..0.65f) { "dim must be between 0 and 0.65" }
                preferences.edit()
                    .putInt(DesktopWallpaperService.KEY_INTERVAL_MINUTES, interval)
                    .putFloat(DesktopWallpaperService.KEY_DIM, dim)
                    .apply()
            }
            else -> throw IllegalArgumentException("unknown wallpaper action")
        }
        return wallpaperStatus()
    }

    private fun rememberBounds(packageName: String, bounds: Rect, displayId: Int) {
        val metrics = displayMetrics(displayId) ?: return
        preferences.edit().putString(
            packageName,
            "n:" + DesktopBounds.encodeNormalized(bounds, metrics.widthPixels, metrics.heightPixels),
        ).apply()
    }

    private fun rememberedBounds(packageName: String, displayId: Int): Rect? {
        val value = preferences.getString(packageName, null) ?: return null
        val metrics = displayMetrics(displayId) ?: return null
        return if (value.startsWith("n:")) {
            DesktopBounds.decodeNormalized(value.removePrefix("n:"), metrics.widthPixels, metrics.heightPixels)
        } else {
            parseBounds(value)
        }
    }

    private fun displayMetrics(displayId: Int): android.util.DisplayMetrics? {
        val display = getSystemService(DisplayManager::class.java).getDisplay(displayId) ?: return null
        return android.util.DisplayMetrics().also {
            @Suppress("DEPRECATION")
            display.getRealMetrics(it)
        }
    }

    private fun profileFor(packageName: String): DesktopProfile = DesktopProfile.fromWireName(
        preferences.getString("_profile_$packageName", DesktopProfile.AUTO.wireName),
    )

    private fun boundsForProfile(profile: DesktopProfile, displayId: Int): Rect? {
        val metrics = displayMetrics(displayId) ?: return null
        return DesktopBounds.forProfile(
            profile,
            metrics.widthPixels,
            metrics.heightPixels,
            metrics.densityDpi,
        )
    }

    private fun validBoundsForDisplay(bounds: Rect, displayId: Int): Boolean {
        val metrics = displayMetrics(displayId) ?: return false
        return bounds.left >= 0 && bounds.top >= 0 &&
            bounds.right <= metrics.widthPixels && bounds.bottom <= metrics.heightPixels
    }

    private fun parseBounds(value: String?): Rect? {
        val parts = value?.split(',')?.mapNotNull(String::toIntOrNull) ?: return null
        return if (parts.size == 4) Rect(parts[0], parts[1], parts[2], parts[3]) else null
    }

    private fun hasRoot(): Boolean {
        val now = System.currentTimeMillis()
        if (now - rootCheckedAt < ROOT_CACHE_MS) return rootAvailable
        val result = runRoot("id -u")
        rootAvailable = result.exitCode == 0 && result.output.trim() == "0"
        rootCheckedAt = now
        return rootAvailable
    }

    private fun requestRootAccess(): JSONObject {
        val result = runRoot("id -u", ROOT_APPROVAL_TIMEOUT_SECONDS)
        rootAvailable = result.exitCode == 0 && result.output.trim() == "0"
        rootCheckedAt = System.currentTimeMillis()
        return JSONObject()
            .put("ok", rootAvailable)
            .put("root", rootAvailable)
            .put("output", result.output.trim())
    }

    private fun launchFromShell(
        component: String,
        displayId: Int,
        bounds: Rect? = null,
        newInstance: Boolean = false,
    ): ShellResult {
        // Keep the display in freeform so SystemUI draws freeform captions/handles.
        ensureFreeformMode(displayId)
        val launchFlags = if (newInstance) {
            // Android 37 removed the old am-start alias --activity-new-document;
            // multiple-task is the supported way to create a desktop copy.
            "--activity-multiple-task"
        } else {
            "--activity-reorder-to-front --activity-single-top"
        }
        val packageName = component.substringBefore('/')
        val freeformBounds = bounds
            ?: rememberedBounds(packageName, displayId)
            ?: boundsForProfile(profileFor(packageName), displayId)
            ?: defaultFreeformBounds(displayId)
        val result = runRoot(
            "am start --user current --display $displayId --windowingMode ${windowingModeFreeform} $launchFlags " +
                "-n ${shellQuote(component)}",
        )
        if (result.exitCode != 0) return result
        publishHostEvent(
            "app-launched",
            JSONObject().put("package", packageName).put("displayId", displayId),
        )

        // Fire-and-forget post-launch resize/resizeable using coroutines + delay
        // so caller (HTTP response) returns quickly. This replaces the previous
        // blocking 8x sleep loop.
        serviceScope.launch {
            waitForTaskAndConfigure(displayId, packageName, freeformBounds)
        }
        return result
    }

    private suspend fun waitForTaskAndConfigure(displayId: Int, packageName: String, freeformBounds: Rect?) {
        var foundTask: DesktopTask? = null
        repeat(8) {
            delay(90)
            foundTask = readTasksFromSystem().firstOrNull {
                it.displayId == displayId &&
                    it.packageName == packageName &&
                    !it.component.contains("DesktopWidgetActivity")
            }
            if (foundTask != null) return@repeat
        }
        val task = foundTask ?: return
        // 2 = RESIZE_MODE_RESIZEABLE — required for freeform drag/edge resize.
        runRoot("am task resizeable ${task.taskId} 2")
        if (freeformBounds != null) {
            runRoot(
                "am task resize ${task.taskId} ${freeformBounds.left} ${freeformBounds.top} " +
                    "${freeformBounds.right} ${freeformBounds.bottom}",
            )
            // Freeform often ignores the first resize until the caption attaches.
            delay(80)
            runRoot(
                "am task resize ${task.taskId} ${freeformBounds.left} ${freeformBounds.top} " +
                    "${freeformBounds.right} ${freeformBounds.bottom}",
            )
            rememberBounds(packageName, freeformBounds, displayId)
        }
        // Bring the newly launched app to the front (over any info widgets/panels).
        runRoot("am task focus ${task.taskId}")
        // Ensure soft IME does not pop up for text fields in the app (host keyboard via scrcpy is used instead).
        dismissIme(displayId)
        refreshTaskCache()
    }

    /** Default freeform window that is clearly movable (not full-screen freeform). */
    private fun defaultFreeformBounds(displayId: Int): Rect? {
        val metrics = displayMetrics(displayId) ?: return null
        val w = metrics.widthPixels
        val h = metrics.heightPixels
        val width = (w * 0.52f).roundToInt().coerceAtLeast(480)
        val height = (h * 0.62f).roundToInt().coerceAtLeast(360)
        val left = ((w - width) / 2).coerceAtLeast(40)
        val top = ((h - height) / 5).coerceAtLeast(48)
        return Rect(left, top, left + width, top + height)
    }

    private fun launchDesktopHome(displayId: Int): ShellResult {
        val result = runRoot(
            "am start --user current --display $displayId -a android.intent.action.MAIN " +
                "-c android.intent.category.SECONDARY_HOME",
        )
        // Dismiss any on-screen keyboard that the launcher drawer/search may have triggered.
        if (displayId != Display.DEFAULT_DISPLAY) {
            Thread.sleep(150)
            dismissIme(displayId)
        }
        return result
    }

    private fun dismissIme(displayId: Int) {
        if (displayId == Display.DEFAULT_DISPLAY) return
        runRoot("input -d $displayId keyevent 111")  // KEYCODE_ESCAPE
        runRoot("cmd input_method hide")
    }

    private fun runRoot(command: String, timeoutSeconds: Long = ROOT_COMMAND_TIMEOUT_SECONDS): ShellResult {
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

    private fun requirePackage(packageName: String): String {
        require(PACKAGE_PATTERN.matches(packageName)) { "invalid package name" }
        return packageName
    }

    private fun shellQuote(value: String): String = "'${value.replace("'", "'\\''")}'"

    private fun JSONObject.toRect(): Rect {
        val rect = Rect(getInt("left"), getInt("top"), getInt("right"), getInt("bottom"))
        require(rect.width() > 0 && rect.height() > 0) { "invalid bounds" }
        return rect
    }

    private fun Rect.toJson(): JSONObject = JSONObject()
        .put("left", left)
        .put("top", top)
        .put("right", right)
        .put("bottom", bottom)

    private fun ShellResult.toJson(): JSONObject = JSONObject()
        .put("ok", exitCode == 0)
        .put("exitCode", exitCode)
        .put("output", output.trim())

    /** Standardized error response for consistent client handling. */
    private fun errorResponse(msg: String, code: Int = 400): JSONObject =
        JSONObject().put("ok", false).put("error", msg).put("code", code)

    private fun writeResponse(socket: Socket, status: Int, body: JSONObject) {
        val bytes = body.toString().toByteArray(Charsets.UTF_8)
        val reason = when (status) {
            200 -> "OK"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            404 -> "Not Found"
            413 -> "Payload Too Large"
            else -> "Internal Server Error"
        }
        socket.getOutputStream().apply {
            write(
                "HTTP/1.1 $status $reason\r\n".toByteArray() +
                    "Content-Type: application/json\r\n".toByteArray() +
                    "Content-Length: ${bytes.size}\r\n".toByteArray() +
                    "Connection: close\r\n\r\n".toByteArray(),
            )
            write(bytes)
            flush()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        server?.close()
        server = null
        taskEventProcess?.destroyForcibly()
        taskEventProcess = null
        getSystemService(DisplayManager::class.java).unregisterDisplayListener(displayListener)
        requestExecutor.shutdownNow()
        controlExecutor.shutdownNow()
        serviceScope.cancel()
        securePrefs.edit().remove("session_token").apply()
        if (instance === this) instance = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        var instance: DexAgentService? = null
            private set

        private const val CHANNEL_ID = "rewritedex"
        private const val TAG = "RewriteDEXAgent"
        private const val EDGE_RESIZE_MARGIN_PX = 36
        private const val EDGE_MOVE_BAR_PX = 48
        private const val EDGE_LEFT = 1
        private const val EDGE_RIGHT = 2
        private const val EDGE_TOP = 4
        private const val EDGE_BOTTOM = 8
        private const val EDGE_MOVE = 16
        private const val NOTIFICATION_ID = 1
        private const val PORT = 8792
        private const val MAX_BODY_BYTES = 64 * 1024
        private const val MAX_REJECTED_BODY_BYTES = 1024 * 1024
        private const val MAX_SHELL_OUTPUT_BYTES = 256 * 1024
        private const val ROOT_COMMAND_TIMEOUT_SECONDS = 5L
        private const val ROOT_APPROVAL_TIMEOUT_SECONDS = 60L
        private const val ROOT_CACHE_MS = 30_000L
        private const val TASK_EVENT_DEBOUNCE_MS = 120L
        // Give launcher animations and task creation a little more breathing
        // room so app-drawer launches are still caught on current Pixel builds.
        // Pixel's secondary-launcher targetComponent event can arrive several
        // seconds after the host click, especially while the app drawer is
        // animating. Keep the marker alive long enough for that event and the
        // task-polling fallback to see the same launch.
        private const val DESKTOP_LAUNCH_WINDOW_MS = 8_000L
        private const val DESKTOP_LAUNCH_POLL_MS = 80L
        private const val TASK_REPARENT_SETTLE_MS = 120L
        private const val TASK_CACHE_MAX_AGE_MS = 5_000L
        private const val WIDGET_OVERLAY_RETRY_MS = 1_000L
        private const val MAX_CONTROL_TEXT_LENGTH = 1_000
        private const val TASK_EVENT_BACKOFF_BASE_MS = 1_000L
        private const val MAX_LOGCAT_RESTARTS = 5
        private const val INPUT_RATE_LIMIT_MS = 30L  // Throttle rapid desktop pointer events from host
        private const val MAX_HOST_EVENTS = 96
        private const val HOST_EVENT_LONG_POLL_MS = 3_500L
        const val ACTION_PHONE_CONTROL = "com.rewritedex.nativeagent.PHONE_CONTROL"
        const val ACTION_APPLY_SETTINGS = "com.rewritedex.nativeagent.ACTION_APPLY_SETTINGS"
        const val ACTION_RESTART_AGENT = "com.rewritedex.nativeagent.ACTION_RESTART_AGENT"
        const val ACTION_EXPORT_DIAGNOSTICS = "com.rewritedex.nativeagent.ACTION_EXPORT_DIAGNOSTICS"
        private val SESSION_EXCLUDED_PACKAGES = setOf(
            "com.android.systemui",
            PIXEL_LAUNCHER_PACKAGE,
            "com.rewritedex.nativeagent",
        )
        private const val PIXEL_LAUNCHER_PACKAGE = "com.google.android.apps.nexuslauncher"
        private val PACKAGE_PATTERN = Regex("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+")
        private val COMPONENT_PATTERN = Regex(
            "[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+/[A-Za-z0-9_.$]+",
        )
        private val TOKEN_PATTERN = Regex("[A-Fa-f0-9]{64}")

        /**
         * Resolves WINDOWING_MODE_FREEFORM via reflection. Android hardcodes this as 5,
         * but AOSP may reassign the constant in future releases. Falls back to 5 if
         * reflection fails (all supported Pixel builds use 5).
         */
        private val windowingModeFreeform: Int by lazy {
            try {
                val wmClass = Class.forName("android.app.WindowConfiguration")
                val field = wmClass.getDeclaredField("WINDOWING_MODE_FREEFORM")
                field.getInt(null)
            } catch (_: Exception) {
                Log.w(TAG, "Could not resolve WINDOWING_MODE_FREEFORM via reflection, falling back to 5")
                5
            }
        }
    }
}
