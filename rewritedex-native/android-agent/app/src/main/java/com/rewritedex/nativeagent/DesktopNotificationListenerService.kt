package com.rewritedex.nativeagent

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

class DesktopNotificationListenerService : NotificationListenerService() {
    override fun onNotificationPosted(notification: StatusBarNotification) {
        val extras = notification.notification.extras
        val item = JSONObject()
            .put("id", notification.key)
            .put("package", notification.packageName)
            .put("title", extras.getCharSequence("android.title")?.toString().orEmpty())
            .put("text", extras.getCharSequence("android.text")?.toString().orEmpty())
            .put("postedAt", notification.postTime)
        val preferences = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
        val entries = try {
            JSONArray(preferences.getString(KEY_ENTRIES, "[]"))
        } catch (_: Exception) {
            JSONArray()
        }
        val next = JSONArray().put(item)
        for (index in 0 until minOf(entries.length(), MAX_ENTRIES - 1)) {
            entries.optJSONObject(index)?.let(next::put)
        }
        preferences.edit().putString(KEY_ENTRIES, next.toString()).apply()
        DexAgentService.instance?.publishHostEvent(
            "notification-posted",
            JSONObject()
                .put("package", notification.packageName)
                .put("title", item.optString("title"))
                .put("postedAt", notification.postTime),
        )
    }

    companion object {
        const val PREFERENCES = "desktop_notifications"
        const val KEY_ENTRIES = "entries"
        private const val MAX_ENTRIES = 24
    }
}
