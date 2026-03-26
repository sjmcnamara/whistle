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
     * Initialise the MDK instance with SQLite storage.
     */
    suspend fun initialise() = mutex.withLock {
        if (_isInitialised) return@withLock

        val dbDir = context.filesDir.resolve("mdk")
        if (!dbDir.exists()) dbDir.mkdirs()
        val dbPath = dbDir.resolve("marmot.db").absolutePath

        try {
            mdk = newMdkUnencrypted(dbPath = dbPath, config = null)
            _isInitialised = true
            Timber.i("MDK initialised at $dbPath")
        } catch (e: Exception) {
            Timber.e(e, "MDK init failed, attempting fresh database")
            try {
                context.filesDir.resolve("mdk/marmot.db").delete()
                mdk = newMdkUnencrypted(dbPath = dbPath, config = null)
                _isInitialised = true
                Timber.i("MDK initialised (fresh) at $dbPath")
            } catch (e2: Exception) {
                Timber.e(e2, "MDK init failed even after fresh DB")
                throw e2
            }
        }
    }

    /**
     * Reset the database (used during identity replacement).
     */
    suspend fun resetDatabase() = mutex.withLock {
        mdk?.close()
        mdk = null
        _isInitialised = false
        val dbFile = context.filesDir.resolve("mdk/marmot.db")
        if (dbFile.exists()) dbFile.delete()
        Timber.i("MDK database reset")
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
}
