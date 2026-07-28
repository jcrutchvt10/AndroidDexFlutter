package com.rewritedex.nativeagent

import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

object WorkspaceStore {
    private const val PREFIX = "_workspace_"
    private val namePattern = Regex("[A-Za-z0-9 _-]{1,32}")

    fun requireName(value: String): String {
        require(namePattern.matches(value)) { "invalid workspace name" }
        return value.trim()
    }

    fun names(preferences: SharedPreferences): List<String> = preferences.all.keys
        .filter { it.startsWith(PREFIX) }
        .map { it.removePrefix(PREFIX) }
        .sorted()

    fun load(preferences: SharedPreferences, name: String): JSONArray? =
        preferences.getString(PREFIX + requireName(name), null)?.let(::JSONArray)

    fun save(preferences: SharedPreferences, name: String, tasks: JSONArray) {
        preferences.edit().putString(PREFIX + requireName(name), tasks.toString()).apply()
    }

    fun delete(preferences: SharedPreferences, name: String) {
        preferences.edit().remove(PREFIX + requireName(name)).apply()
    }

    fun response(preferences: SharedPreferences): JSONObject {
        val workspaces = JSONArray()
        names(preferences).forEach { name ->
            workspaces.put(
                JSONObject()
                    .put("name", name)
                    .put("apps", load(preferences, name)?.length() ?: 0),
            )
        }
        return JSONObject().put("ok", true).put("workspaces", workspaces)
    }
}
