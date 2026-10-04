package org.findmyfam.shared.models

import org.json.JSONObject

/**
 * A decrypted inner message, as the app understands one.
 *
 * The Kotlin counterpart of iOS's `WhistleMessage`. `content` is the
 * already-extracted inner plaintext, so nothing above this layer needs a
 * MarmotKit type to read a message.
 */
data class WhistleMessage(
    val id: String,
    val mlsGroupId: String,
    val senderPubkey: String,
    val kind: Int,
    val content: String,
    /** Epoch seconds. */
    val createdAt: Long,
    /**
     * True for a membership or rename event rather than an app payload.
     *
     * These share the timeline with chat, and [payloadType] is null for them,
     * so a chat filter keyed on that alone lets them through and renders raw
     * JSON in a bubble — attributed to whoever performed the action, which
     * reads as a message they typed.
     */
    val isSystemEvent: Boolean = false,
    /**
     * MarmotKit's own display string for a system event ("Member added"), with
     * actor and subject already resolved.
     */
    val systemText: String? = null,
    /**
     * The MLS epoch the message was sent in, when known.
     *
     * A causally correct tiebreaker for ordering. `createdAt` has only
     * **one-second** resolution, so several commits from one action — promote,
     * self-demote, leave — share a timestamp and sort arbitrarily; on iOS,
     * ordering those by message id put them on screen in the exact reverse of
     * what happened. The epoch increments per commit, so it orders
     * group-state events correctly.
     */
    val sourceEpoch: Long? = null,
) {
    /** Epoch milliseconds, for Kotlin date APIs. */
    val timestampMillis: Long get() = createdAt * 1000

    /**
     * The `type` discriminator carried inside [content] for chat-kind payloads
     * (`chat`, `nickname`, `avatar`, `group_avatar`).
     *
     * Several distinct payloads share the chat kind and are told apart by this
     * field, so both the receive path and the chat UI read it. Null when the
     * content is not a JSON object with a string `type` — plain text from an
     * older client, which callers treat as ordinary chat.
     *
     * Note it is **absent on anything Whistle did not write**, which is why it
     * cannot be used to exclude foreign kinds; use [kind] for that.
     */
    val payloadType: String?
        get() = runCatching {
            val type = JSONObject(content).optString("type")
            type.ifEmpty { null }
        }.getOrNull()
}
