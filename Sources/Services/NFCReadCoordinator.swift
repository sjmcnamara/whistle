import Foundation
import CoreNFC

/// Reads a `whistle://` invite URL from an NFC tag.
///
/// Usage: instantiate as `@StateObject`, call `start()`, observe `onScan`.
@MainActor
final class NFCReadCoordinator: NSObject, ObservableObject {

    /// Called on the main actor when a valid URL is read from an NFC tag.
    var onScan: ((String) -> Void)?

    @Published private(set) var isReading = false

    private var session: NFCNDEFReaderSession?

    func start(alertMessage: String = "Hold your iPhone near an NFC invite tag.") {
        guard NFCNDEFReaderSession.readingAvailable else { return }
        isReading = true
        let s = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: true)
        s.alertMessage = alertMessage
        s.begin()
        session = s
    }
}

// MARK: - NFCNDEFReaderSessionDelegate

extension NFCReadCoordinator: NFCNDEFReaderSessionDelegate {

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        Task { @MainActor in self.isReading = false }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        for message in messages {
            for record in message.records {
                if let url = record.wellKnownTypeURIPayload() {
                    let urlString = url.absoluteString
                    Task { @MainActor in
                        self.isReading = false
                        self.onScan?(urlString)
                    }
                    return
                }
            }
        }
    }
}
