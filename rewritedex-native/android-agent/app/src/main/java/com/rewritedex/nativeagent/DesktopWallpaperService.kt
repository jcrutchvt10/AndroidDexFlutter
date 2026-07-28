package com.rewritedex.nativeagent

import android.app.WallpaperColors
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RadialGradient
import android.graphics.Shader
import android.os.Handler
import android.os.Looper
import android.service.wallpaper.WallpaperService
import android.view.SurfaceHolder
import java.util.concurrent.TimeUnit
import kotlin.math.max

class DesktopWallpaperService : WallpaperService() {
    private val storage by lazy { createDeviceProtectedStorageContext() }
    private val preferences by lazy {
        storage.getSharedPreferences(PREFERENCES, MODE_PRIVATE)
    }

    override fun onCreateEngine(): Engine = DesktopEngine()

    private inner class DesktopEngine : Engine(),
        android.content.SharedPreferences.OnSharedPreferenceChangeListener {
        private val handler = Handler(Looper.getMainLooper())
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.DITHER_FLAG)
        private var width = 1
        private var height = 1
        private var visible = false

        private val rotate = object : Runnable {
            override fun run() {
                if (visible && intervalMinutes() > 0) {
                    selectNext(preferences)
                    drawFrame()
                    scheduleRotation()
                }
            }
        }

        override fun onCreate(surfaceHolder: SurfaceHolder) {
            super.onCreate(surfaceHolder)
            setOffsetNotificationsEnabled(false)
            preferences.registerOnSharedPreferenceChangeListener(this)
        }

        override fun onDestroy() {
            handler.removeCallbacksAndMessages(null)
            preferences.unregisterOnSharedPreferenceChangeListener(this)
            super.onDestroy()
        }

        override fun onVisibilityChanged(visible: Boolean) {
            this.visible = visible
            if (visible) {
                drawFrame()
                scheduleRotation()
            } else {
                handler.removeCallbacks(rotate)
            }
        }

        override fun onSurfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
            this.width = max(1, width)
            this.height = max(1, height)
            drawFrame()
        }

        override fun onSurfaceRedrawNeeded(holder: SurfaceHolder) = drawFrame()

        override fun onSharedPreferenceChanged(
            sharedPreferences: android.content.SharedPreferences,
            key: String?,
        ) {
            if (key?.startsWith("wallpaper_") == true) {
                drawFrame()
                scheduleRotation()
                notifyColorsChanged()
            }
        }

        override fun onComputeColors(): WallpaperColors {
            val theme = THEMES[currentIndex(preferences)]
            return WallpaperColors(
                Color.valueOf(theme.primary),
                Color.valueOf(theme.secondary),
                Color.valueOf(theme.accent),
                WallpaperColors.HINT_SUPPORTS_DARK_TEXT.takeIf { theme.light } ?: 0,
            )
        }

        private fun intervalMinutes(): Int =
            preferences.getInt(KEY_INTERVAL_MINUTES, DEFAULT_INTERVAL_MINUTES)

        private fun scheduleRotation() {
            handler.removeCallbacks(rotate)
            val minutes = intervalMinutes()
            if (visible && minutes > 0) {
                handler.postDelayed(rotate, TimeUnit.MINUTES.toMillis(minutes.toLong()))
            }
        }

        private fun drawFrame() {
            if (!surfaceHolder.surface.isValid) return
            val canvas = try {
                surfaceHolder.lockHardwareCanvas()
            } catch (_: Exception) {
                null
            } ?: return
            try {
                drawTheme(canvas, THEMES[currentIndex(preferences)])
                val dim = preferences.getFloat(KEY_DIM, DEFAULT_DIM).coerceIn(0f, 0.65f)
                if (dim > 0f) {
                    canvas.drawColor(Color.argb((dim * 255).toInt(), 0, 0, 0))
                }
            } finally {
                surfaceHolder.unlockCanvasAndPost(canvas)
            }
        }

        private fun drawTheme(canvas: Canvas, theme: Theme) {
            val w = width.toFloat()
            val h = height.toFloat()
            paint.shader = LinearGradient(
                0f,
                0f,
                w,
                h,
                theme.primary,
                theme.secondary,
                Shader.TileMode.CLAMP,
            )
            canvas.drawRect(0f, 0f, w, h, paint)

            paint.shader = RadialGradient(
                w * theme.glowX,
                h * theme.glowY,
                max(w, h) * 0.72f,
                intArrayOf(theme.accent, Color.TRANSPARENT),
                floatArrayOf(0f, 1f),
                Shader.TileMode.CLAMP,
            )
            canvas.drawRect(0f, 0f, w, h, paint)

            val ridge = Path().apply {
                moveTo(0f, h * 0.76f)
                cubicTo(w * 0.22f, h * 0.62f, w * 0.42f, h * 0.88f, w * 0.62f, h * 0.69f)
                cubicTo(w * 0.78f, h * 0.55f, w * 0.88f, h * 0.72f, w, h * 0.59f)
                lineTo(w, h)
                lineTo(0f, h)
                close()
            }
            paint.shader = LinearGradient(
                0f,
                h * 0.58f,
                0f,
                h,
                theme.ridge,
                theme.floor,
                Shader.TileMode.CLAMP,
            )
            canvas.drawPath(ridge, paint)

            paint.shader = null
            paint.color = Color.argb(20, 255, 255, 255)
            paint.strokeWidth = max(1f, h / 900f)
            for (line in 1..3) {
                val y = h * (0.16f + line * 0.12f)
                canvas.drawLine(w * 0.08f, y, w * 0.92f, y + h * 0.025f, paint)
            }
        }
    }

    data class Theme(
        val name: String,
        val primary: Int,
        val secondary: Int,
        val accent: Int,
        val ridge: Int,
        val floor: Int,
        val glowX: Float,
        val glowY: Float,
        val light: Boolean = false,
    )

    companion object {
        const val PREFERENCES = "desktop_wallpaper"
        const val KEY_INDEX = "wallpaper_index"
        const val KEY_INTERVAL_MINUTES = "wallpaper_interval_minutes"
        const val KEY_DIM = "wallpaper_dim"
        const val DEFAULT_INTERVAL_MINUTES = 60
        const val DEFAULT_DIM = 0.08f

        val THEMES = listOf(
            Theme("Graphite", 0xff11171c.toInt(), 0xff324047.toInt(), 0xff526f73.toInt(), 0xff17252b.toInt(), 0xff090d10.toInt(), 0.78f, 0.22f),
            Theme("Blue hour", 0xff10233a.toInt(), 0xff49606b.toInt(), 0xff568fa0.toInt(), 0xff1c3342.toInt(), 0xff0c151c.toInt(), 0.72f, 0.18f),
            Theme("Forest glass", 0xff142521.toInt(), 0xff52645c.toInt(), 0xff6f9682.toInt(), 0xff233a32.toInt(), 0xff0d1512.toInt(), 0.24f, 0.2f),
            Theme("Plum dusk", 0xff211823.toInt(), 0xff604b59.toInt(), 0xff9a7283.toInt(), 0xff372737.toInt(), 0xff120d13.toInt(), 0.7f, 0.2f),
            Theme("Cloud", 0xffc7d2d8.toInt(), 0xff8298a1.toInt(), 0x6699c0cc, 0xff6d838a.toInt(), 0xff44575d.toInt(), 0.3f, 0.16f, light = true),
        )

        fun currentIndex(preferences: android.content.SharedPreferences): Int =
            preferences.getInt(KEY_INDEX, 0).mod(THEMES.size)

        fun selectNext(preferences: android.content.SharedPreferences): Int {
            val index = (currentIndex(preferences) + 1).mod(THEMES.size)
            preferences.edit().putInt(KEY_INDEX, index).apply()
            return index
        }

        fun rotateForSession(context: android.content.Context): Int {
            val storage = context.createDeviceProtectedStorageContext()
            val preferences = storage.getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            val now = System.currentTimeMillis()
            val last = preferences.getLong("wallpaper_last_session", 0L)
            if (now - last < TimeUnit.MINUTES.toMillis(2)) return currentIndex(preferences)
            val index = selectNext(preferences)
            preferences.edit().putLong("wallpaper_last_session", now).apply()
            return index
        }
    }
}
