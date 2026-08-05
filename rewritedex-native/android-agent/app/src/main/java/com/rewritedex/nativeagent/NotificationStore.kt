package com.rewritedex.nativeagent

import android.content.SharedPreferences
import android.service.notification.StatusBarNotification
import org.json.JSONArray
import org.json.JSONObject

/**
 * Shared persistence for mirrored Android notifications plus a pure JSON
 * builder so the payload contract can be unit-tested without the framework.
 */
object NotificationStore {
    const val PREFERENCES = "desktop_notifications"
    const val KEY_ENTRIES = "entries"
    const val MAX_ENTRIES = 24

    /** Pure builder; see [fromStatusBarNotification] for the framework adapter. */
    fun itemJson(
        id: String,
        packageName: String,
        title: String,
        text: String,
        postedAt: Long,
        priority: Int,
        category: String?,
        actions: List<String>,
    ): JSONObject = JSONObject()
        .put("id", id)
        .put("package", packageName)
        .put("title", title)
        .put("text", text)
        .put("postedAt", postedAt)
        .put("priority", priority)
        .put("category", category ?: JSONObject.NULL)
        .put("actions", JSONArray(actions))

    fun fromStatusBarNotification(notification: StatusBarNotification): JSONObject {
        val extras = notification.notification.extras
        return itemJson(
            id = notification.key,
            packageName = notification.packageName,
            title = extras.getCharSequence("android.title")?.toString().orEmpty(),
            text = extras.getCharSequence("android.text")?.toString().orEmpty(),
            postedAt = notification.postTime,
            priority = notification.notification.priority,
            category = notification.notification.category,
            actions = notification.notification.actions
                ?.mapNotNull { it.title?.toString() }
                .orEmpty(),
        )
    }

    /** Push the newest notification to the head of the bounded ring. */
    fun push(preferences: SharedPreferences, item: JSONObject) {
        val entries = list(preferences)
        val next = JSONArray().put(item)
        for (index in 0 until minOf(entries.length(), MAX_ENTRIES - 1)) {
            entries.optJSONObject(index)?.let(next::put)
        }
        preferences.edit().putString(KEY_ENTRIES, next.toString()).apply()
    }

    fun list(preferences: SharedPreferences): JSONArray = try {
        JSONArray(preferences.getString(KEY_ENTRIES, "[]"))
    } catch (_: Exception) {
        JSONArray()
    }

    fun clear(preferences: SharedPreferences) {
        preferences.edit().remove(KEY_ENTRIES).apply()
    }

    /** Host-event payload (metadata only — no images or intents). */
    fun eventPayload(item: JSONObject): JSONObject = JSONObject()
        .put("package", item.optString("package"))
        .put("title", item.optString("title"))
        .put("postedAt", item.optLong("postedAt"))
        .put("priority", item.optInt("priority"))
        .put("category", item.optString("category"))
}
