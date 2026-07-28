package com.rewritedex.nativeagent

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.BatteryManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import java.text.DateFormat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

/**
 * Freeform clock/battery cards on the virtual desktop.
 *
 * TYPE_APPLICATION_OVERLAY widgets are force-hidden by Android
 * (mIsForceHiddenNonSystemOverlayWindow) when SystemUI sets
 * HIDE_NON_SYSTEM_OVERLAY_WINDOWS. A normal freeform Activity on the
 * desktop display is not subject to that hide, so it stays visible.
 */
class DesktopWidgetActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var timeView: TextView
    private lateinit var dateView: TextView
    private lateinit var batteryPctView: TextView
    private lateinit var batteryStatusView: TextView
    private lateinit var networkView: TextView
    private lateinit var statusView: TextView

    private val refresh = object : Runnable {
        override fun run() {
            updateTexts()
            scheduleRefresh()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Stay out of the way of the desktop shell and taskbar.
        window.addFlags(
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
        )
        setFinishOnTouchOutside(false)

        val density = resources.displayMetrics.density
        // One compact, non-intrusive vertical info panel (rich but minimal)
        val root = card(density).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12, density), dp(8, density), dp(12, density), dp(8, density))
        }

        // Time - prominent but small
        timeView = value("--:--", 28f, density)
        root.addView(timeView)

        // Date
        dateView = caption("—", density)
        root.addView(dateView)

        // Battery row
        val batteryRow = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        batteryPctView = value("100%", 18f, density)
        batteryStatusView = caption("On battery", density)
        batteryRow.addView(batteryPctView)
        batteryRow.addView(batteryStatusView)
        root.addView(batteryRow)

        // Network - useful info
        networkView = caption("📶 --", density)
        root.addView(networkView)

        // PC connection status (non-intrusive indicator)
        statusView = caption("RewriteDEX • Desktop", density)
        root.addView(statusView)

        setContentView(root)

        updateTexts()
    }

    override fun onResume() {
        super.onResume()
        scheduleRefresh()
    }

    override fun onPause() {
        handler.removeCallbacks(refresh)
        super.onPause()
    }

    override fun onDestroy() {
        handler.removeCallbacks(refresh)
        super.onDestroy()
    }

    private fun scheduleRefresh() {
        handler.removeCallbacks(refresh)
        val minute = TimeUnit.MINUTES.toMillis(1)
        val delay = minute - System.currentTimeMillis() % minute + 250
        handler.postDelayed(refresh, delay)
    }

    private fun updateTexts() {
        val now = Date()
        timeView.text = DateFormat.getTimeInstance(DateFormat.SHORT).format(now)
        dateView.text = SimpleDateFormat("EEEE, MMMM d", Locale.getDefault()).format(now)
        val battery = readBattery()
        batteryPctView.text = battery.first
        batteryStatusView.text = battery.second
        updateNetwork()
    }

    private fun readBattery(): Pair<String, String> {
        val state = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val rawLevel = state?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = state?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val level = if (rawLevel >= 0 && scale > 0) {
            (rawLevel * 100f / scale).roundToInt().coerceIn(0, 100)
        } else {
            -1
        }
        val batteryStatus = state?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = batteryStatus == BatteryManager.BATTERY_STATUS_CHARGING ||
            batteryStatus == BatteryManager.BATTERY_STATUS_FULL
        val plugged = state?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val status = when {
            level < 0 -> "Battery unavailable"
            batteryStatus == BatteryManager.BATTERY_STATUS_FULL -> "Fully charged"
            charging && plugged == BatteryManager.BATTERY_PLUGGED_USB -> "Charging by USB"
            charging && plugged == BatteryManager.BATTERY_PLUGGED_WIRELESS -> "Charging wirelessly"
            charging -> "Charging"
            else -> "On battery"
        }
        val pct = if (level < 0) "--" else "$level%"
        return pct to status
    }

    private fun updateNetwork() {
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as android.net.ConnectivityManager
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager
            val info = wifiManager.connectionInfo
            var text = "📶 No WiFi"
            if (info != null && info.ssid != null && info.ssid != "<unknown ssid>") {
                val ssid = info.ssid.trim('"')
                val level = android.net.wifi.WifiManager.calculateSignalLevel(info.rssi, 5)
                text = "📶 $ssid $level/5"
            }
            // Check for mobile data as fallback
            val network = cm.activeNetwork
            val caps = cm.getNetworkCapabilities(network)
            if (caps != null && caps.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) && text.contains("No WiFi")) {
                text = "📡 Mobile data"
            }
            networkView.text = text
        } catch (_: Exception) {
            networkView.text = "📶 --"
        }
    }

    private fun card(density: Float): LinearLayout {
        val bg = GradientDrawable().apply {
            setColor(Color.argb(210, 18, 23, 27))
            cornerRadius = 8f * density
        }
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = bg
            setPadding(dp(16, density), dp(14, density), dp(16, density), dp(14, density))
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
        }
    }

    private fun label(text: String, density: Float): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(Color.rgb(204, 212, 216))
            textSize = 11f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            setPadding(0, 0, 0, dp(4, density))
        }

    private fun value(text: String, sizeSp: Float, density: Float): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(Color.WHITE)
            textSize = sizeSp
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            setPadding(0, 0, 0, dp(2, density))
        }

    private fun caption(text: String, density: Float): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(Color.rgb(204, 212, 216))
            textSize = 13f
            setPadding(0, dp(2, density), 0, 0)
        }

    private fun dp(value: Int, density: Float): Int = (value * density).roundToInt()
}
