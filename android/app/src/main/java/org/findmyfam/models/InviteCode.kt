package org.findmyfam.models

import android.util.Base64
import org.json.JSONObject

/**
 * Self-contained invite token for joining a Marmot group.
 *
 * An invite encodes the relay URL, inviter's npub, and MLS group ID into
 * a compact base64-URL string that can be shared via messaging, QR code, etc.
 */
data class InviteCode(
    val relay: String,
    val inviterNpub: String,
    val groupId: String
) {
    /**
     * Encode the invite as a URL-safe base64 string.
     */
    fun encode(): String {
        val json = JSONObject().apply {
            put("relay", relay)
            put("inviterNpub", inviterNpub)
            put("groupId", groupId)
        }.toString()
        return Base64.encodeToString(json.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
    }

    /**
     * Wrap the invite in a famstr://invite/<code> deep-link URI.
     */
    fun asUri(): String {
        return "famstr://invite/${encode()}"
    }

    companion object {
        /**
         * Decode an invite from a base64-encoded string.
         */
        fun decode(encoded: String): InviteCode {
            val jsonBytes = Base64.decode(encoded, Base64.NO_WRAP)
            val obj = JSONObject(String(jsonBytes, Charsets.UTF_8))
            return InviteCode(
                relay = obj.getString("relay"),
                inviterNpub = obj.getString("inviterNpub"),
                groupId = obj.getString("groupId")
            )
        }

        /**
         * Extract an invite from a famstr://invite/<code> URI.
         * Also accepts a raw base64 string for backwards compatibility.
         */
        fun fromUri(uri: String): InviteCode {
            val prefix = "famstr://invite/"
            val code = if (uri.startsWith(prefix)) {
                uri.removePrefix(prefix)
            } else {
                uri
            }
            return decode(code)
        }

        /**
         * Build a famstr://addmember/<pubkeyHex>/<groupId> URI that the
         * invitee shares back with the inviter to request group admission.
         */
        fun approvalUri(pubkeyHex: String, groupId: String): String {
            return "famstr://addmember/$pubkeyHex/$groupId"
        }
    }
}
