import Foundation
import WhistleCore
import MDKBindings

/// Actor-isolated wrapper around the Marmot Development Kit (MDK).
///
/// MDK manages all MLS cryptographic state: key packages, groups, epoch rotation,
/// message encryption/decryption, and welcome events. It is a pure state machine —
/// it produces Nostr event JSON strings but never touches relays itself.
///
/// Threading: `Mdk` must be confined to a single thread. The Swift `actor` isolation
/// satisfies this requirement — all calls are serialised through the actor executor.
actor MLSService {

    // MARK: - State

    private var mdk: (any MdkProtocol)?
    private(set) var isInitialised = false

    // MARK: - Initialisation

    /// Production init — attempts encrypted SQLCipher storage via `newMdk`,
    /// which delegates key management to `keyring-core` (Keychain on iOS,
    /// Keystore on Android).
    ///
    /// **Fallback:** `keyring-core` requires `set_default_store()` to be called
    /// from Rust before `newMdk` can work, but this function is not yet exposed
    /// via UniFFI (MDK encrypted-storage-plan Phase 4 incomplete). If `newMdk`
    /// fails, we fall back to `newMdkUnencrypted` and log a warning. Once the
    /// MDK ships the store-init function via UniFFI, remove the fallback.
    ///
    /// If an existing database cannot be opened (e.g. a pre-0.9 unencrypted DB
    /// left on device), it is deleted and recreated.
    func initialise(
        serviceId: String = "org.findmyfam",
        dbKeyId: String = "mdk.db.key"
    ) throws {
        guard !isInitialised else {
            FMFLogger.mls.debug("MLSService already initialised, skipping")
            return
        }

        let path = Self.defaultDBPath()
        let dbExists = FileManager.default.fileExists(atPath: path)

        FMFLogger.mls.info("MLSService init — dbExists=\(dbExists), path=\(path)")

        // Attempt 1: encrypted via keyring-core
        do {
            mdk = try newMdk(dbPath: path, serviceId: serviceId, dbKeyId: dbKeyId, config: nil)
            isInitialised = true
            let groupCount = (try? mdk?.getGroups().count) ?? -1
            FMFLogger.mls.info("MLSService initialised (encrypted via keyring-core), \(groupCount) group(s)")
            return
        } catch {
            FMFLogger.mls.warning("newMdk failed: \(error)")
            // If a stale DB blocked us, delete and retry encrypted
            if dbExists {
                Self.deleteDatabase(at: path)
                do {
                    mdk = try newMdk(dbPath: path, serviceId: serviceId, dbKeyId: dbKeyId, config: nil)
                    isInitialised = true
                    let groupCount = (try? mdk?.getGroups().count) ?? -1
                    FMFLogger.mls.info("MLSService initialised (encrypted, fresh DB), \(groupCount) group(s)")
                    return
                } catch {
                    FMFLogger.mls.warning("newMdk still failed after DB delete: \(error)")
                }
            }
        }

        // Fallback: keyring-core store not yet exposed via UniFFI — use unencrypted.
        // TODO: Remove this fallback once MDK exposes set_default_store() via UniFFI.
        FMFLogger.mls.warning("⚠️ Falling back to newMdkUnencrypted — keyring-core store init not available via UniFFI")
        Self.deleteDatabase(at: path)  // ensure clean state
        mdk = try newMdkUnencrypted(dbPath: path, config: nil)
        isInitialised = true
        let groupCount = (try? mdk?.getGroups().count) ?? -1
        FMFLogger.mls.info("MLSService initialised (UNENCRYPTED fallback), \(groupCount) group(s)")
    }

    /// Tear down the MLS state entirely so a new identity can start fresh.
    ///
    /// Deletes the database files on disk and resets in-memory state.
    /// keyring-core manages the encryption key lifecycle — when a fresh DB is
    /// created on the next `initialise()`, keyring-core will generate a new key.
    func resetDatabase() {
        isInitialised = false
        mdk = nil
        Self.deleteDatabase(at: Self.defaultDBPath())
        FMFLogger.mls.info("MLS database reset for identity replacement")
    }

    /// Delete the database file and any related WAL/SHM files.
    private static func deleteDatabase(at path: String) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let file = path + suffix
            if fm.fileExists(atPath: file) {
                try? fm.removeItem(atPath: file)
            }
        }
    }

    /// In-memory init for unit tests only (unencrypted — no Keychain in test host).
    func initialiseInMemory() throws {
        mdk = try newMdkUnencrypted(dbPath: ":memory:", config: nil)
        isInitialised = true
        FMFLogger.mls.debug("MLSService initialised in memory (test mode)")
    }

    // MARK: - Key Packages (kind 443)

    /// Produce a KeyPackage payload for publishing as a kind-443 Nostr event.
    ///
    /// The caller must:
    /// 1. Build a kind-443 event: `content = result.keyPackage`, `tags = result.tags`
    /// 2. Sign the event with the user's Nostr nsec
    /// 3. Publish to relays
    func createKeyPackage(
        publicKeyHex: String,
        relays: [String]
    ) throws -> KeyPackageResult {
        try instance().createKeyPackageForEvent(publicKey: publicKeyHex, relays: relays)
    }

    // MARK: - Group Lifecycle

    /// Create a new MLS group.
    ///
    /// After calling this you **must** call `mergePendingCommit(groupId:)` before
    /// sending messages or performing further group operations.
    ///
    /// - Parameters:
    ///   - creatorPublicKeyHex:       Hex pubkey of the group creator.
    ///   - memberKeyPackageEventsJson: Fully signed kind-443 event JSON strings for
    ///                                 any members to add at creation time. Pass `[]`
    ///                                 to create a solo group.
    ///   - name:        Human-readable group name.
    ///   - description: Optional group description.
    ///   - relays:      Relay URLs the group will use.
    /// - Returns: `CreateGroupResult` — call `.publishPayload(relayURLs:)` then
    ///   NIP-59 gift-wrap the welcome rumors (v0.3).
    func createGroup(
        creatorPublicKeyHex: String,
        memberKeyPackageEventsJson: [String] = [],
        name: String,
        description: String = "",
        relays: [String]
    ) throws -> CreateGroupResult {
        let result = try instance().createGroup(
            creatorPublicKey: creatorPublicKeyHex,
            memberKeyPackageEventsJson: memberKeyPackageEventsJson,
            name: name,
            description: description,
            relays: relays,
            admins: [creatorPublicKeyHex]
        )
        FMFLogger.mls.info("Group created: \(result.group.mlsGroupId) epoch=\(result.group.epoch)")
        return result
    }

    /// **Required** after `createGroup`, `addMembers`, `removeMembers`, or `selfUpdate`
    /// before sending messages or performing further mutations.
    func mergePendingCommit(groupId: String) throws {
        try instance().mergePendingCommit(mlsGroupId: groupId)
        FMFLogger.mls.debug("Merged pending commit: group=\(groupId)")
    }

    func clearPendingCommit(groupId: String) throws {
        try instance().clearPendingCommit(mlsGroupId: groupId)
    }

    /// Add members to a group. Caller must `mergePendingCommit` and publish the result.
    /// - Parameter keyPackageEventsJson: Signed kind-443 event JSON for each new member.
    func addMembers(
        groupId: String,
        keyPackageEventsJson: [String]
    ) throws -> UpdateGroupResult {
        let result = try instance().addMembers(
            mlsGroupId: groupId,
            keyPackageEventsJson: keyPackageEventsJson
        )
        FMFLogger.mls.info("Members added to group \(groupId)")
        return result
    }

    /// Remove members from a group. Caller must `mergePendingCommit` and publish the result.
    /// - Parameter memberPublicKeys: Hex pubkeys of members to remove.
    func removeMembers(
        groupId: String,
        memberPublicKeys: [String]
    ) throws -> UpdateGroupResult {
        let result = try instance().removeMembers(
            mlsGroupId: groupId,
            memberPublicKeys: memberPublicKeys
        )
        FMFLogger.mls.info("Removed \(memberPublicKeys.count) member(s) from group \(groupId)")
        return result
    }

    /// Update group metadata (name, description, relays, admins).
    /// Caller must `mergePendingCommit` and publish the result.
    func updateGroupData(groupId: String, update: GroupDataUpdate) throws -> UpdateGroupResult {
        let result = try instance().updateGroupData(mlsGroupId: groupId, update: update)
        FMFLogger.mls.info("Updated group data for \(groupId)")
        return result
    }

    /// Perform a self-update (MLS key rotation) for the given group.
    /// Produces a new epoch. Caller must `mergePendingCommit` and publish the result.
    func selfUpdate(groupId: String) throws -> UpdateGroupResult {
        let result = try instance().selfUpdate(mlsGroupId: groupId)
        FMFLogger.mls.info("Self-updated group \(groupId) → epoch \(result.mlsGroupId)")
        return result
    }

    /// Returns group IDs whose last self-update is older than `thresholdSecs`.
    /// Default threshold: 7 days.
    func groupsNeedingSelfUpdate(
        thresholdSecs: UInt64 = 7 * 24 * 3600
    ) throws -> [String] {
        try instance().groupsNeedingSelfUpdate(thresholdSecs: thresholdSecs)
    }

    // MARK: - Messages (kind 445)

    /// Encrypt a message for the group.
    /// - Parameters:
    ///   - kind: Inner Nostr kind. Use `MarmotKind.chat` (9) for chat,
    ///           `MarmotKind.location` (1) for location payloads (v0.4).
    /// - Returns: A complete, encrypted Nostr event JSON string — publish directly to relays.
    func createMessage(
        groupId: String,
        senderPublicKeyHex: String,
        content: String,
        kind: UInt16 = MarmotKind.chat,
        tags: [[String]]? = nil
    ) throws -> String {
        try instance().createMessage(
            mlsGroupId: groupId,
            senderPublicKey: senderPublicKeyHex,
            content: content,
            kind: kind,
            tags: tags
        )
    }

    /// Process an incoming Nostr event from a relay.
    ///
    /// Pass any raw event JSON (kind-445 group events or kind-1059 gift wraps).
    /// The return value tells you what action to take:
    /// - `.applicationMessage`: decrypted message, store/display it
    /// - `.proposal`: auto-committed (you're admin) — publish the evolution event
    /// - `.commit`: epoch advanced — no further action needed
    /// - `.unprocessable`: epoch mismatch or decryption failure — log and discard
    func processIncomingEvent(eventJson: String) throws -> ProcessMessageResult {
        try instance().processMessage(eventJson: eventJson)
    }

    /// Retrieve stored messages for a group, newest first.
    func getMessages(
        groupId: String,
        limit: UInt32? = 50,
        offset: UInt32? = nil,
        sortOrder: String = MLSSortOrder.createdAtFirst
    ) throws -> [Message] {
        try instance().getMessages(
            mlsGroupId: groupId,
            limit: limit,
            offset: offset,
            sortOrder: sortOrder
        )
    }

    // MARK: - Welcome Flow (kind 444)

    /// Decode an incoming NIP-59 gift-wrap and extract the pending Welcome.
    ///
    /// - Parameters:
    ///   - wrapperEventId: The `id` field of the outer kind-1059 gift-wrap event (hex).
    ///   - rumorEventJson: The inner unwrapped rumor event JSON string.
    func processWelcome(
        wrapperEventId: String,
        rumorEventJson: String
    ) throws -> Welcome {
        try instance().processWelcome(
            wrapperEventId: wrapperEventId,
            rumorEventJson: rumorEventJson
        )
    }

    func acceptWelcome(_ welcome: Welcome) throws {
        try instance().acceptWelcome(welcome: welcome)
        FMFLogger.mls.info("Accepted welcome for group \(welcome.mlsGroupId)")
    }

    func declineWelcome(_ welcome: Welcome) throws {
        try instance().declineWelcome(welcome: welcome)
        FMFLogger.mls.info("Declined welcome for group \(welcome.mlsGroupId)")
    }

    func getPendingWelcomes() throws -> [Welcome] {
        try instance().getPendingWelcomes(limit: nil, offset: nil)
    }

    // MARK: - Group Queries

    func getGroups() throws -> [Group] {
        try instance().getGroups()
    }

    func getGroup(mlsGroupId: String) throws -> Group? {
        try instance().getGroup(mlsGroupId: mlsGroupId)
    }

    func getMembers(groupId: String) throws -> [String] {
        try instance().getMembers(mlsGroupId: groupId)
    }

    func getRelays(groupId: String) throws -> [String] {
        try instance().getRelays(mlsGroupId: groupId)
    }

    // MARK: - Private

    private func instance() throws -> any MdkProtocol {
        guard let mdk else { throw MLSError.notInitialised }
        return mdk
    }

    private static func defaultDBPath() -> String {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("findmyfam-mdk.db")
            .path
    }

    // MARK: - Errors

    enum MLSError: LocalizedError {
        case notInitialised
        case epochMismatch(String)

        var errorDescription: String? {
            switch self {
            case .notInitialised:      return "MLSService has not been initialised"
            case .epochMismatch(let m): return "Epoch mismatch: \(m)"
            }
        }
    }
}
