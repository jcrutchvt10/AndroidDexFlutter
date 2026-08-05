package com.rewritedex.nativeagent

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsStoreTest {
    @Test
    fun validateReturnsOnlyKnownKeys() {
        val validated = SettingsStore.validate(
            JSONObject()
                .put(SettingsStore.KEY_DARK_THEME, true)
                .put(SettingsStore.KEY_QUALITY_PROFILE, 2)
                .put("unknown", "ignored"),
        )
        assertTrue(validated.getBoolean(SettingsStore.KEY_DARK_THEME))
        assertEquals(2, validated.getInt(SettingsStore.KEY_QUALITY_PROFILE))
        assertFalse(validated.has("unknown"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun validateRejectsOutOfRangeQualityProfile() {
        SettingsStore.validate(JSONObject().put(SettingsStore.KEY_QUALITY_PROFILE, 9))
    }

    @Test(expected = IllegalArgumentException::class)
    fun validateRejectsNegativeQualityProfile() {
        SettingsStore.validate(JSONObject().put(SettingsStore.KEY_QUALITY_PROFILE, -1))
    }

    @Test
    fun emptySettingsObjectIsSafe() {
        val validated = SettingsStore.validate(JSONObject())
        assertFalse(validated.has(SettingsStore.KEY_DARK_THEME))
        assertFalse(validated.has(SettingsStore.KEY_QUALITY_PROFILE))
    }

    @Test(expected = IllegalArgumentException::class)
    fun validateRejectsTooSmallWallpaperInterval() {
        SettingsStore.validateWallpaper(JSONObject().put(SettingsStore.KEY_WALLPAPER_INTERVAL, 5))
    }

    @Test
    fun validateAllowsOffWallpaperRotation() {
        val validated = SettingsStore.validateWallpaper(JSONObject().put(SettingsStore.KEY_WALLPAPER_INTERVAL, 0))
        assertEquals(0, validated.getInt(SettingsStore.KEY_WALLPAPER_INTERVAL))
    }

    @Test(expected = IllegalArgumentException::class)
    fun validateRejectsWallpaperDimAboveCap() {
        SettingsStore.validateWallpaper(JSONObject().put(SettingsStore.KEY_WALLPAPER_DIM, 0.9))
    }
}
