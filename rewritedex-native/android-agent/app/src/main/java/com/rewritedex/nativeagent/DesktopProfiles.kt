package com.rewritedex.nativeagent

import android.graphics.Rect
import kotlin.math.roundToInt

enum class DesktopProfile(val wireName: String) {
    AUTO("auto"),
    PHONE("phone"),
    TABLET("tablet"),
    LARGE("large"),
    MAXIMIZED("maximized");

    companion object {
        fun fromWireName(value: String?): DesktopProfile =
            entries.firstOrNull { it.wireName == value } ?: AUTO
    }
}

object DesktopBounds {
    fun forProfile(profile: DesktopProfile, width: Int, height: Int, densityDpi: Int): Rect? {
        val bounds = calculate(profile, width, height, densityDpi)
        return Rect(bounds.left, bounds.top, bounds.right, bounds.bottom)
    }

    fun calculate(
        profile: DesktopProfile,
        width: Int,
        height: Int,
        densityDpi: Int,
    ): ParsedTaskBounds {
        if (profile == DesktopProfile.MAXIMIZED) return ParsedTaskBounds(0, 0, width, height)
        val density = densityDpi / 160f
        val desiredWidth = when (profile) {
            DesktopProfile.PHONE -> 430f * density
            DesktopProfile.TABLET -> 760f * density
            DesktopProfile.LARGE -> width * 0.82f
            // Keep the default desktop app footprint a little tighter so more
            // room remains for side-by-side windows on the scrcpy desktop.
            else -> width * 0.64f
        }.roundToInt().coerceAtMost((width * 0.9f).roundToInt())
        val desiredHeight = when (profile) {
            DesktopProfile.PHONE -> 760f * density
            DesktopProfile.TABLET -> 680f * density
            DesktopProfile.LARGE -> height * 0.84f
            else -> height * 0.74f
        }.roundToInt().coerceAtMost((height * 0.88f).roundToInt())
        val left = (width - desiredWidth) / 2
        val top = ((height - desiredHeight) / 2).coerceAtLeast(0)
        return ParsedTaskBounds(left, top, left + desiredWidth, top + desiredHeight)
    }

    fun preset(name: String, width: Int, height: Int): Rect = when (name) {
        "left" -> Rect(0, 0, width / 2, height)
        "right" -> Rect(width / 2, 0, width, height)
        "top-left" -> Rect(0, 0, width / 2, height / 2)
        "top-right" -> Rect(width / 2, 0, width, height / 2)
        "bottom-left" -> Rect(0, height / 2, width / 2, height)
        "bottom-right" -> Rect(width / 2, height / 2, width, height)
        "phone" -> forProfile(DesktopProfile.PHONE, width, height, 240)!!
        "tablet" -> forProfile(DesktopProfile.TABLET, width, height, 240)!!
        "large" -> forProfile(DesktopProfile.LARGE, width, height, 240)!!
        "center", "restore", "floating" -> forProfile(DesktopProfile.AUTO, width, height, 240)!!
        "maximize" -> Rect(0, 0, width, height)
        else -> throw IllegalArgumentException("unknown window preset")
    }

    /** Grow/shrink a freeform window around its center, clamped to the display. */
    fun scaleAboutCenter(
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        displayWidth: Int,
        displayHeight: Int,
        factor: Float,
    ): ParsedTaskBounds {
        val cx = (left + right) / 2f
        val cy = (top + bottom) / 2f
        val bw = ((right - left) * factor).roundToInt()
            .coerceIn(displayWidth / 5, (displayWidth * 0.95f).roundToInt())
        val bh = ((bottom - top) * factor).roundToInt()
            .coerceIn(displayHeight / 5, (displayHeight * 0.92f).roundToInt())
        var newLeft = (cx - bw / 2f).roundToInt()
        var newTop = (cy - bh / 2f).roundToInt()
        if (newLeft < 0) newLeft = 0
        if (newTop < 0) newTop = 0
        if (newLeft + bw > displayWidth) newLeft = displayWidth - bw
        if (newTop + bh > displayHeight) newTop = displayHeight - bh
        return ParsedTaskBounds(newLeft, newTop, newLeft + bw, newTop + bh)
    }

    fun scaleAboutCenter(bounds: Rect, width: Int, height: Int, factor: Float): Rect {
        val scaled = scaleAboutCenter(
            bounds.left, bounds.top, bounds.right, bounds.bottom, width, height, factor,
        )
        return Rect(scaled.left, scaled.top, scaled.right, scaled.bottom)
    }

    fun encodeNormalized(bounds: Rect, width: Int, height: Int): String =
        encodeNormalized(bounds.left, bounds.top, bounds.right, bounds.bottom, width, height)

    fun encodeNormalized(
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        width: Int,
        height: Int,
    ): String = listOf(
        left.toFloat() / width,
        top.toFloat() / height,
        right.toFloat() / width,
        bottom.toFloat() / height,
    ).joinToString(",") { "%.6f".format(java.util.Locale.US, it) }

    fun decodeNormalized(value: String?, width: Int, height: Int): Rect? {
        val bounds = decodeNormalizedValues(value, width, height) ?: return null
        return Rect(bounds.left, bounds.top, bounds.right, bounds.bottom)
    }

    fun decodeNormalizedValues(value: String?, width: Int, height: Int): ParsedTaskBounds? {
        val values = value?.split(',')?.mapNotNull(String::toFloatOrNull) ?: return null
        if (values.size != 4 || values.any { it !in 0f..1f }) return null
        val bounds = ParsedTaskBounds(
            (values[0] * width).roundToInt(),
            (values[1] * height).roundToInt(),
            (values[2] * width).roundToInt(),
            (values[3] * height).roundToInt(),
        )
        return bounds.takeIf { it.right > it.left && it.bottom > it.top }
    }
}
