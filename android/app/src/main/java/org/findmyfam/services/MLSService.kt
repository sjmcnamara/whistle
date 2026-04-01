package org.findmyfam.services

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import build.marmot.mdk.*
import timber.log.Timber
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Actor-like wrapper around MDK for MLS group operations.
 * Uses a Mutex to serialize access (mirrors Swift `actor` isolation).
 */
@Singleton
class MLSService @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val mutex = Mutex()
    private var mdk: Mdk? = null
    private var _isInitialised = false

    val isInitialised: Boolean get() = _isInitialised

    /**
     * Initialise the MDK instance with SQLCipher-encrypted SQLite storage.
     * Uses `newMdk` which delegates key management to keyring-core — the
     * 32-byte encryption key is generated and stored in Android Keystore
     * automatically. No app-level key management required.
     *
     * If keyring-core is unavailable on this Android build (Phase 3 of the
     * MDK encrypted-storage-plan is still in progress), falls back to
     * `newMdkUnencrypted` with a warning — encryption will be enforced once
     * the MDK ships Android keyring support.
     *
     * If the existing DB cannot be opened (pre-0.9 plaintext DB or key
     * mismatch), it is deleted and recreated — matching the forced-reinstall
     * policy for the 0.9 release.
     */
    suspend fun initialise() = mutex.withLock {
        if (_isInitialised) return@withLock

        val dbDir = context.filesDir.resolve("mdk")
        if (!dbDir.exists()) dbDir.mkdirs()
        val dbPath = dbDir.resolve("marmot.db").absolutePath

        try {
            mdk = newMdk(dbPath = dbPath, serviceId = SERVICE_ID, dbKeyId = DB_KEY_ID, config = null)
            _isInitialised = true
            Timber.i("MDK initialised (encrypted via keyring-core) at $dbPath")
        } catch (e: Exception) {
            Timber.w(e, "newMdk failed — trying fresh DB, then unencrypted fallback")
            try {
                deleteDbFiles(dbDir)
                mdk = newMdk(dbPath = dbPath, serviceId = SERVICE_ID, dbKeyId = DB_KEY_ID, config = null)
                _isInitialised = true
                Timber.i("MDK initialised (encrypted, fresh) at $dbPath")
            } catch (e2: Exception) {
                // keyring-core may not be available on Android yet (MDK Phase 3).
                // Fall back to unencrypted until the MDK ships Android keyring support.
                Timber.w(e2, "Encrypted init failed — falling back to newMdkUnencrypted")
                deleteDbFiles(dbDir)
                try {
                    mdk = newMdkUnencrypted(dbPath = dbPath, config = null)
                    _isInitialised = true
                    Timber.w("MDK initialised UNENCRYPTED at $dbPath — Android keyring not yet available")
                } catch (e3: Exception) {
                    Timber.e(e3, "MDK init failed entirely")
                    throw e3
                }
            }
        }
    }

    /**
     * Reset the database (used during identity replacement).
     * Deletes the DB files and resets in-memory state. keyring-core manages
     * the encryption key lifecycle — a fresh DB will get a new key automatically.
     */
    suspend fun resetDatabase() = mutex.withLock {
        mdk?.close()
        mdk = null
        _isInitialised = false
        val dbDir = context.filesDir.resolve("mdk")
        deleteDbFiles(dbDir)
        Timber.i("MDK database reset for identity replacement")
    }

    private fun deleteDbFiles(dbDir: java.io.File) {
        for (suffix in listOf("", "-wal", "-shm")) {
            val f = dbDir.resolve("marmot.db$suffix")
            if (f.exists()) f.delete()
        }
    }

    // MARK: - Key Packages

    suspend fun createKeyPackageForEvent(publicKey: String, relays: List<String>): KeyPackageResult =
        mutex.withLock { requireMdk().createKeyPackageForEvent(publicKey, relays) }

    // MARK: - Group Lifecycle

    suspend fun createGroup(
        creatorPublicKey: String,
        memberKeyPackageEventsJson: List<String>,
        name: String,
        description: String,
        relays: List<String>,
        admins: List<String>
    ): CreateGroupResult = mutex.withLock {
        requireMdk().createGroup(creatorPublicKey, memberKeyPackageEventsJson, name, description, relays, admins)
    }

    suspend fun addMembers(mlsGroupId: String, keyPackageEventsJson: List<String>): UpdateGroupResult =
        mutex.withLock { requireMdk().addMembers(mlsGroupId, keyPackageEventsJson) }

    suspend fun removeMembers(mlsGroupId: String, memberPublicKeys: List<String>): UpdateGroupResult =
        mutex.withLock { requireMdk().removeMembers(mlsGroupId, memberPublicKeys) }

    suspend fun selfUpdate(mlsGroupId: String): UpdateGroupResult =
        mutex.withLock { requireMdk().selfUpdate(mlsGroupId) }

    suspend fun mergePendingCommit(mlsGroupId: String) =
        mutex.withLock { requireMdk().mergePendingCommit(mlsGroupId) }

    suspend fun clearPendingCommit(mlsGroupId: String) =
        mutex.withLock { requireMdk().clearPendingCommit(mlsGroupId) }

    // MARK: - Messages

    suspend fun createMessage(
        mlsGroupId: String,
        senderPublicKey: String,
        content: String,
        kind: UShort,
        tags: List<List<String>>?
    ): String = mutex.withLock {
        requireMdk().createMessage(mlsGroupId, senderPublicKey, content, kind, tags)
    }

    suspend fun processMessage(eventJson: String): ProcessMessageResult =
        mutex.withLock { requireMdk().processMessage(eventJson) }

    // MARK: - Welcome

    suspend fun processWelcome(wrapperEventId: String, rumorEventJson: String): Welcome =
        mutex.withLock { requireMdk().processWelcome(wrapperEventId, rumorEventJson) }

    suspend fun acceptWelcome(welcome: Welcome) =
        mutex.withLock { requireMdk().acceptWelcome(welcome) }

    suspend fun declineWelcome(welcome: Welcome) =
        mutex.withLock { requireMdk().declineWelcome(welcome) }

    suspend fun getPendingWelcomes(limit: UInt? = null, offset: UInt? = null): List<Welcome> =
        mutex.withLock { requireMdk().getPendingWelcomes(limit, offset) }

    // MARK: - Queries

    suspend fun getGroups(): List<Group> =
        mutex.withLock { requireMdk().getGroups() }

    suspend fun getGroup(mlsGroupId: String): Group? =
        mutex.withLock {
            try { requireMdk().getGroup(mlsGroupId) } catch (_: Exception) { null }
        }

    suspend fun getMembers(mlsGroupId: String): List<String> =
        mutex.withLock { requireMdk().getMembers(mlsGroupId) }

    suspend fun getRelays(mlsGroupId: String): List<String> =
        mutex.withLock { requireMdk().getRelays(mlsGroupId) }

    suspend fun getMessages(mlsGroupId: String, limit: UInt?, offset: UInt?, sortOrder: String?): List<Message> =
        mutex.withLock { requireMdk().getMessages(mlsGroupId, limit, offset, sortOrder) }

    // MARK: - Key Rotation

    suspend fun groupsNeedingSelfUpdate(thresholdSecs: ULong): List<String> =
        mutex.withLock { requireMdk().groupsNeedingSelfUpdate(thresholdSecs) }

    // MARK: - Internal

    private fun requireMdk(): Mdk = mdk ?: throw IllegalStateException("MDK not initialised")

    companion object {
        private const val SERVICE_ID = "org.findmyfam"
        private const val DB_KEY_ID = "mdk.db.key"
    }
}
