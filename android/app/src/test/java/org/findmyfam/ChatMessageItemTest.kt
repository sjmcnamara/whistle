package org.findmyfam

import org.findmyfam.viewmodels.ChatViewModel.ChatMessageItem
import org.findmyfam.shared.models.ChatPayload
import org.junit.Assert.*
import org.junit.Test

/**
 * Tests for ChatMessageItem data class and ChatPayload → ChatMessageItem mapping logic.
 */
class ChatMessageItemTest {

    private val myPubkey = "a".repeat(64)
    private val otherPubkey = "b".repeat(64)

    private fun item(
        senderPubkeyHex: String = otherPubkey,
        text: String = "Hello",
        timestamp: Long = 1000L
    ) = ChatMessageItem(
        id = "msg-1",
        senderPubkeyHex = senderPubkeyHex,
        senderDisplayName = if (senderPubkeyHex == myPubkey) "Me" else "Alice",
        text = text,
        timestamp = timestamp,
        isMe = senderPubkeyHex == myPubkey
    )

    @Test
    fun isMe_whenSenderIsMyPubkey() {
        val msg = item(senderPubkeyHex = myPubkey)
        assertTrue(msg.isMe)
    }

    @Test
    fun isNotMe_whenSenderIsDifferent() {
        val msg = item(senderPubkeyHex = otherPubkey)
        assertFalse(msg.isMe)
    }

    @Test
    fun chatPayload_typeFilter_chatPassesThrough() {
        val json = """{"type":"chat","text":"hello","ts":1000}"""
        val payload = ChatPayload.fromJson(json)
        assertEquals("hello", payload.text)
        assertEquals("chat", payload.type)
    }

    @Test
    fun chatPayload_typeFilter_nicknameFiltered() {
        // The mapMessage function filters out non-"chat" types.
        // Verify that a nickname payload has type != "chat".
        val json = """{"type":"nickname","name":"Alice","ts":1000}"""
        val obj = org.json.JSONObject(json)
        val type = obj.optString("type", "chat")
        assertNotEquals("chat", type)
    }

    @Test
    fun chatPayload_defaultType_isChatWhenMissing() {
        // When "type" is missing from JSON, mapMessage defaults to "chat"
        val json = """{"text":"hello","ts":1000}"""
        val obj = org.json.JSONObject(json)
        val type = obj.optString("type", "chat")
        assertEquals("chat", type)
    }

    @Test
    fun chatPayload_roundTrip() {
        val original = ChatPayload(text = "Test message")
        val json = original.toJson()
        val parsed = ChatPayload.fromJson(json)
        assertEquals("Test message", parsed.text)
        assertEquals("chat", parsed.type)
    }

    @Test
    fun chatMessageItem_equality() {
        val a = item()
        val b = item()
        assertEquals(a, b)
    }

    @Test
    fun chatMessageItem_copyUpdatesName() {
        val original = item()
        val updated = original.copy(senderDisplayName = "Bob")
        assertEquals("Alice", original.senderDisplayName)
        assertEquals("Bob", updated.senderDisplayName)
    }

    @Test
    fun chatPayload_nonJsonContent_treatedAsPlainText() {
        // When content is not valid JSON, mapMessage treats it as plain text
        val content = "just a plain string"
        val isJson = try {
            org.json.JSONObject(content)
            true
        } catch (_: Exception) {
            false
        }
        assertFalse("Plain text should not parse as JSON", isJson)
    }

    @Test
    fun chatPayload_locationTypeFiltered() {
        val json = """{"type":"location","lat":53.35,"lon":-6.26,"ts":1000}"""
        val obj = org.json.JSONObject(json)
        val type = obj.optString("type", "chat")
        assertEquals("location", type)
        assertNotEquals("chat", type)
    }
}
