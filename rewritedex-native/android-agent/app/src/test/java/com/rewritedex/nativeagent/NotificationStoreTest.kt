package com.rewritedex.nativeagent

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationStoreTest {
    @Test
    fun itemJsonCarriesEnrichedFields() {
        val item = NotificationStore.itemJson(
            id = "key-1",
            packageName = "com.example.app",
            title = "Hello",
            text = "World",
            postedAt = 1234L,
            priority = 2,
            category = "msg",
            actions = listOf("Reply", "Archive"),
        )
        assertEquals("key-1", item.getString("id"))
        assertEquals("com.example.app", item.getString("package"))
        assertEquals(2, item.getInt("priority"))
        assertEquals("msg", item.getString("category"))
        assertEquals(2, item.getJSONArray("actions").length())
        assertEquals("Reply", item.getJSONArray("actions").getString(0))
    }

    @Test
    fun itemJsonHandlesMissingCategoryAndActions() {
        val item = NotificationStore.itemJson("k", "p", "t", "", 0L, 0, null, emptyList())
        assertTrue(item.isNull("category"))
        assertEquals(0, item.getJSONArray("actions").length())
    }

    @Test
    fun eventPayloadIsMetadataOnly() {
        val item = NotificationStore.itemJson(
            id = "key-2",
            packageName = "com.example.app",
            title = "Alert",
            text = "Secret text",
            postedAt = 99L,
            priority = 1,
            category = "sys",
            actions = listOf("Open"),
        )
        val payload = NotificationStore.eventPayload(item)
        assertEquals("com.example.app", payload.getString("package"))
        assertEquals("Alert", payload.getString("title"))
        assertEquals(99L, payload.getLong("postedAt"))
        assertEquals(1, payload.getInt("priority"))
        // Never leak notification text or action intents into host events.
        assertFalse(payload.has("text"))
        assertFalse(payload.has("actions"))
    }
}
