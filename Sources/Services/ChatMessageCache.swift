import Foundation

/// In-memory cache of loaded chat threads, keyed by group id.
///
/// `ChatViewModel` is owned by `GroupChatView` via `@StateObject` and is
/// therefore destroyed when the chat is popped off the navigation stack and
/// rebuilt (empty) when re-entered. Without a cache that would flash an empty
/// thread and re-decrypt the recent page from MDK every visit. This cache lets
/// a freshly-created `ChatViewModel` seed itself synchronously with the last
/// known messages so the thread renders instantly; a background refresh then
/// merges in anything new.
///
/// Purely in-memory — the durable store remains MDK's encrypted SQLite DB.
@MainActor
final class ChatMessageCache {

    /// A cached thread: the displayed bubbles plus the pagination cursor so
    /// "load earlier" continues from where the deepest load reached.
    struct Thread {
        var messages: [ChatViewModel.ChatMessageItem]
        /// Offset into MDK's raw message store (see `ChatViewModel.currentOffset`).
        var offset: UInt32
        /// Whether older messages remain to be paged in.
        var hasMore: Bool
    }

    private var threads: [String: Thread] = [:]

    /// The cached thread for a group, if one has been loaded this session.
    func thread(for groupId: String) -> Thread? {
        threads[groupId]
    }

    /// Store (or replace) the cached thread for a group.
    func store(groupId: String, messages: [ChatViewModel.ChatMessageItem], offset: UInt32, hasMore: Bool) {
        threads[groupId] = Thread(messages: messages, offset: offset, hasMore: hasMore)
    }

    /// Drop a single group's cached thread.
    func clear(groupId: String) {
        threads.removeValue(forKey: groupId)
    }

    /// Drop all cached threads (e.g. on logout / identity reset).
    func clear() {
        threads.removeAll()
    }
}
