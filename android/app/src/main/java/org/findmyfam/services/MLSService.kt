package org.findmyfam.services

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import build.marmot.mdk.*
import timber.log.Timber
import java.security.SecureRandom
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
     *
     * MDK 0.8.0's newMdk() auto-init of Android keyring requires the NDK
     * context (JVM + Application context) to be set up, which is not
     * available when loaded via JNA. As a workaround we manage the 32-byte
     * encryption key ourselves via EncryptedSharedPreferences, which uses
     * Android Keystore internally without the NDK context requirement.
     *
     * If the DB can't be opened (corrupt or stale), it is deleted and
     * recreated — matching the forced-reinstall policy from v0.9.
     */
    suspend fun initialise() = mutex.withLock {
        if (_isInitialised) return@withLock

        val dbDir = context.filesDir.resolve("mdk")
        if (!dbDir.exists()) dbDir.mkdirs()

        // Migrate legacy filename from pre-1.1.2 installs.
        val oldFile = dbDir.resolve("marmot.db")
        val newFile = dbDir.resolve("whistle.db")
        if (oldFile.exists() && !newFile.exists()) {
            oldFile.renameTo(newFile)
            for (suffix in listOf("-wal", "-shm")) {
                val old = dbDir.resolve("marmot.db$suffix")
                if (old.exists()) old.renameTo(dbDir.resolve("whistle.db$suffix"))
            }
            Timber.i("Migrated MLS database: marmot.db → whistle.db")
        }

        val dbPath = newFile.absolutePath
        val key = loadOrCreateDbKey()

        try {
            mdk = newMdkWithKey(dbPath = dbPath, encryptionKey = key, config = null)
            _isInitialised = true
            Timber.i("MDK initialised (encrypted via EncryptedSharedPreferences key) at $dbPath")
        } catch (e: Exception) {
            Timber.w(e, "newMdkWithKey failed — deleting DB and retrying")
            try {
                deleteDbFiles(dbDir)
                mdk = newMdkWithKey(dbPath = dbPath, encryptionKey = key, config = null)
                _isInitialised = true
                Timber.i("MDK initialised (encrypted, fresh DB) at $dbPath")
            } catch (e2: Exception) {
                Timber.e(e2, "MDK init failed entirely")
                throw e2
            }
        }
    }

    /**
     * Load the 32-byte SQLCipher key from EncryptedSharedPreferences, or
     * generate and persist a new one on first launch.
     * EncryptedSharedPreferences wraps Android Keystore — the key never
     * leaves the device in plaintext.
     */
    private fun loadOrCreateDbKey(): ByteArray {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        val prefs = EncryptedSharedPreferences.create(
            context,
            "mdk_db_key",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
        val stored = prefs.getString(PREF_DB_KEY, null)
        if (stored != null) {
            return android.util.Base64.decode(stored, android.util.Base64.NO_WRAP)
        }
        val fresh = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString(PREF_DB_KEY, android.util.Base64.encodeToString(fresh, android.util.Base64.NO_WRAP)).apply()
        Timber.i("Generated new MDK database encryption key")
        return fresh
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

    /**
     * Securely delete database files — overwrites each file with zeros before
     * deletion to prevent recovery of MLS key material from disk.
     */
    private fun deleteDbFiles(dbDir: java.io.File) {
        for (suffix in listOf("", "-wal", "-shm")) {
            val f = dbDir.resolve("marmot.db$suffix")
            if (f.exists()) {
                secureOverwrite(f)
                f.delete()
            }
        }
    }

    /** Overwrite a file's contents with zeros. Best-effort — errors are logged but non-fatal. */
    private fun secureOverwrite(file: java.io.File) {
        try {
            java.io.RandomAccessFile(file, "rw").use { raf ->
                val size = raf.length()
                if (size <= 0) return
                raf.seek(0)
                val chunkSize = 64 * 1024
                val zeros = ByteArray(chunkSize)
                var remaining = size
                while (remaining > 0) {
                    val toWrite = minOf(remaining, chunkSize.toLong()).toInt()
                    raf.write(zeros, 0, toWrite)
                    remaining -= toWrite
                }
                raf.fd.sync()
            }
        } catch (e: Exception) {
            Timber.w(e, "secureOverwrite failed for ${file.name}")
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
        requireMdk().createMessage(mlsGroupId, senderPublicKey, content, kind, tags, eventTags = null)
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

    suspend fun updateGroupData(mlsGroupId: String, update: GroupDataUpdate): UpdateGroupResult =
        mutex.withLock { requireMdk().updateGroupData(mlsGroupId, update) }

    // MARK: - Key Rotation

    suspend fun groupsNeedingSelfUpdate(thresholdSecs: ULong): List<String> =
        mutex.withLock { requireMdk().groupsNeedingSelfUpdate(thresholdSecs) }

    // MARK: - Internal

    private fun requireMdk(): Mdk = mdk ?: throw IllegalStateException("MDK not initialised")

    companion object {
        private const val SERVICE_ID = "org.findmyfam"
        private const val DB_KEY_ID = "mdk.db.key"
        private const val PREF_DB_KEY = "mdk_encryption_key"
    }
}
