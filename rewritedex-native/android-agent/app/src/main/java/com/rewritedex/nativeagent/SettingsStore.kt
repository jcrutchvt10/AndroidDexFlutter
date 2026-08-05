package com.rewritedex.nativeagent

import org.json.JSONObject

/**
 * Typed, validated settings schema for the unified host-facing settings API.
 *
 * The host shell is the primary settings UI; this store is the single source
 * of truth for the agent-side knobs and rejects anything that cannot be
 * represented in the typed schema.
 */
object SettingsStore {
    const val KEY_DARK_THEME = "dark_theme"
    const val KEY_QUALITY_PROFILE = "quality_profile"
    const val KEY_WALLPAPER = "wallpaper"

    const val KEY_WALLPAPER_INDEX = "index"
    const val KEY_WALLPAPER_INTERVAL = "intervalMinutes"
    const val KEY_WALLPAPER_DIM = "dim"

    const val DEFAULT_QUALITY_PROFILE = 1
    const val MIN_WALLPAPER_INTERVAL = 15
    const val MAX_WALLPAPER_INTERVAL = 1440
    const val MAX_WALLPAPER_DIM = 0.65f

    /**
     * Validates a settings object and returns the normalized subset that is
     * safe to persist. Unknown keys are ignored; invalid values throw so the
     * HTTP layer can return a 400.
     */
    fun validate(settings: JSONObject): JSONObject {
        val result = JSONObject()
        if (settings.has(KEY_DARK_THEME)) {
            result.put(KEY_DARK_THEME, settings.optBoolean(KEY_DARK_THEME))
        }
        if (settings.has(KEY_QUALITY_PROFILE)) {
            val profile = settings.optInt(KEY_QUALITY_PROFILE, -1)
            require(profile in 0..2) { "quality_profile must be 0..2" }
            result.put(KEY_QUALITY_PROFILE, profile)
        }
        if (settings.has(KEY_WALLPAPER)) {
            val wallpaper = settings.getJSONObject(KEY_WALLPAPER)
            result.put(KEY_WALLPAPER, validateWallpaper(wallpaper))
        }
        return result
    }

    fun validateWallpaper(wallpaper: JSONObject): JSONObject {
        val result = JSONObject()
        if (wallpaper.has(KEY_WALLPAPER_INDEX)) {
            val index = wallpaper.optInt(KEY_WALLPAPER_INDEX, -1)
            require(index >= 0) { "wallpaper index must be >= 0" }
            result.put(KEY_WALLPAPER_INDEX, index)
        }
        if (wallpaper.has(KEY_WALLPAPER_INTERVAL)) {
            val interval = wallpaper.optInt(KEY_WALLPAPER_INTERVAL, -1)
            require(interval == 0 || interval in MIN_WALLPAPER_INTERVAL..MAX_WALLPAPER_INTERVAL) {
                "wallpaper interval must be 0 or between $MIN_WALLPAPER_INTERVAL and $MAX_WALLPAPER_INTERVAL"
            }
            result.put(KEY_WALLPAPER_INTERVAL, interval)
        }
        if (wallpaper.has(KEY_WALLPAPER_DIM)) {
            val dim = wallpaper.optDouble(KEY_WALLPAPER_DIM, -1.0)
            require(dim in 0.0..MAX_WALLPAPER_DIM.toDouble()) {
                "wallpaper dim must be between 0 and $MAX_WALLPAPER_DIM"
            }
            result.put(KEY_WALLPAPER_DIM, dim)
        }
        return result
    }
}
