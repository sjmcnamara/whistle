package org.findmyfam.services

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import rust.nostr.sdk.Keys
import rust.nostr.sdk.SecretKey
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages Nostr identity (keypair) with encrypted storage via Android Keystore.
 * Mirrors iOS IdentityService.
 */
@Singleton
class IdentityService @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .setRequestStrongBoxBacked(true)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        context,
        "fmf_identity",
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    private val _keys = MutableStateFlow<Keys?>(null)
    val keys: StateFlow<Keys?> = _keys.asStateFlow()

    val publicKeyHex: String?
        get() = _keys.value?.publicKey()?.toHex()

    val npub: String?
        get() = try { _keys.value?.publicKey()?.toBech32() } catch (_: Exception) { null }

    init {
        val isStrongBox = masterKey.isStrongBoxBacked
        Timber.i("Identity storage: EncryptedSharedPreferences (StrongBox=${isStrongBox})")
        loadOrCreate()
    }

    private fun loadOrCreate() {
        val stored = prefs.getString(KEY_NSEC, null)
        if (stored != null) {
            try {
                val sk = SecretKey.parse(stored)
                _keys.value = Keys(secretKey = sk)
                Timber.i("Identity loaded: ${npub?.take(16)}…")
                return
            } catch (e: Exception) {
                Timber.e(e, "Failed to load stored key, generating new one")
            }
        }
        generate()
    }

    private fun generate() {
        val newKeys = Keys.generate()
        val nsec = newKeys.secretKey().toBech32()
        prefs.edit().putString(KEY_NSEC, nsec).apply()
        _keys.value = newKeys
        Timber.i("New identity generated: ${npub?.take(16)}…")
    }

    /**
     * Explicitly destroy the current key from encrypted storage.
     * Called during burn identity to ensure old key material is deleted
     * before the new key is written. Nil's in-memory reference too.
     */
    fun destroyCurrentKey() {
        prefs.edit().remove(KEY_NSEC).commit()
        _keys.value = null
        Timber.i("Current key destroyed from secure storage")
    }

    /**
     * Import a key from nsec bech32 string, replacing the current identity.
     */
    fun importKey(nsec: String) {
        val sk = SecretKey.parse(nsec)
        val newKeys = Keys(secretKey = sk)
        prefs.edit().putString(KEY_NSEC, nsec).apply()
        _keys.value = newKeys
        Timber.i("Identity imported: ${npub?.take(16)}…")
    }

    companion object {
        private const val KEY_NSEC = "nostr_nsec"
    }
}
