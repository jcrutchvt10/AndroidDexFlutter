package com.rewritedex.nativeagent

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.Drawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.AdaptiveIconDrawable
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

/**
 * Renders launcher icons to rounded-corner PNGs and caches them on device so
 * the host shell can render a real icon-based launcher (icons are not exposed
 * by the metadata-only /api/v1/apps contract).
 */
object IconCache {
    const val ICON_SIZE_DP = 96
    const val ICON_CORNER_RADIUS_FACTOR = 0.18f
    const val ICON_DIR = "icons"

    fun pathFor(context: Context, packageName: String): File =
        File(File(context.filesDir, ICON_DIR), "$packageName.png")

    fun cachedIcon(context: Context, packageName: String): ByteArray? {
        val file = pathFor(context, packageName)
        if (file.isFile) return file.readBytes()
        val bytes = renderIcon(context, packageName) ?: return null
        runCatching {
            file.parentFile?.mkdirs()
            FileOutputStream(file).use { out -> out.write(bytes) }
        }
        return bytes
    }

    fun renderIcon(context: Context, packageName: String): ByteArray? {
        val drawable = loadIcon(context, packageName) ?: return null
        val density = context.resources.displayMetrics.density
        val size = (ICON_SIZE_DP * density).toInt().coerceAtLeast(48)
        val inset = (size * 0.06f).toInt()
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val clip = Path().apply {
            val radius = size * ICON_CORNER_RADIUS_FACTOR
            addRoundRect(0f, 0f, size.toFloat(), size.toFloat(), radius, radius, Path.Direction.CW)
        }
        canvas.save()
        canvas.clipPath(clip)
        drawable.setBounds(inset, inset, size - inset, size - inset)
        drawable.draw(canvas)
        canvas.restore()
        val out = ByteArrayOutputStream()
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) return null
        return out.toByteArray()
    }

    private fun loadIcon(context: Context, packageName: String): Drawable? = try {
        val applicationInfo = context.packageManager.getApplicationInfo(packageName, 0)
        val drawable = applicationInfo.loadIcon(context.packageManager)
        // Adaptive icons draw a small safe-zone image over a transparent
        // canvas; wrap with a themed background so they look like a launcher.
        when (drawable) {
            is AdaptiveIconDrawable -> BitmapDrawable(
                context.resources,
                renderAdaptive(drawable, context),
            )
            else -> drawable
        }
    } catch (_: Exception) {
        null
    }

    private fun renderAdaptive(adaptive: AdaptiveIconDrawable, context: Context): Bitmap {
        val density = context.resources.displayMetrics.density
        val size = (ICON_SIZE_DP * density).toInt().coerceAtLeast(48)
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        adaptive.background?.setBounds(0, 0, size, size)
        adaptive.background?.draw(canvas)
        val foreground = adaptive.foreground
        foreground?.setBounds(0, 0, size, size)
        // Adaptive foregrounds are designed for the 66dp safe zone inside
        // 108dp; scale to keep the same relative inset.
        val scale = size / (108f / 66f)
        val safe = (size - scale) / 2f
        canvas.save()
        canvas.translate(safe, safe)
        canvas.scale(scale / size, scale / size)
        foreground?.draw(canvas)
        canvas.restore()
        return bitmap
    }
}
