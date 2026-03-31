import Foundation
import CoreNFC

/// Writes a `whistle://` invite URL to an NDEF-writable NFC tag.
///
/// Usage: instantiate as `@StateObject`, call `write(url:)` when the
/// user taps the "Write to NFC Tag" button.
@MainActor
final class NFCWriteCoordinator: NSObject, ObservableObject {

    /// Whether NFC tag writing is available.
    static var isAvailable: Bool { NFCNDEFReaderSession.readingAvailable }

    @Published private(set) var status: WriteStatus = .idle

    enum WriteStatus {
        case idle
        case writing
        case success
        case failure(String)
    }

    private var session: NFCNDEFReaderSession?
    private var targetURL: URL?

    func write(url: URL) {
        guard Self.isAvailable else { return }
        targetURL = url
        status = .writing
        let s = NFCNDEFReaderSession(delegate: self, queue: nil, invalidateAfterFirstRead: false)
        s.alertMessage = "Hold your iPhone near a blank NFC tag to write the invite."
        s.begin()
        session = s
    }
}

// MARK: - NFCNDEFReaderSessionDelegate

extension NFCWriteCoordinator: NFCNDEFReaderSessionDelegate {

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didInvalidateWithError error: Error) {
        let nsError = error as NSError
        // Code 200 = user cancelled — not a real failure.
        if nsError.code != 200 {
            Task { @MainActor in self.status = .failure(error.localizedDescription) }
        } else {
            Task { @MainActor in self.status = .idle }
        }
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetectNDEFs messages: [NFCNDEFMessage]) {
        // Not used for writing (tag detection handled in didDetect tags)
    }

    nonisolated func readerSession(_ session: NFCNDEFReaderSession, didDetect tags: [NFCNDEFTag]) {
        guard let tag = tags.first else { return }

        session.connect(to: tag) { [weak self] error in
            if let error {
                session.invalidate(errorMessage: "Connection failed: \(error.localizedDescription)")
                return
            }

            tag.queryNDEFStatus { status, capacity, error in
                guard error == nil else {
                    session.invalidate(errorMessage: "Could not query tag status.")
                    return
                }

                switch status {
                case .notSupported:
                    session.invalidate(errorMessage: "Tag does not support NDEF.")
                case .readOnly:
                    session.invalidate(errorMessage: "Tag is read-only.")
                case .readWrite:
                    guard let url = self?.targetURL,
                          let payload = NFCNDEFPayload.wellKnownTypeURIPayload(url: url) else {
                        session.invalidate(errorMessage: "Could not create invite payload.")
                        return
                    }
                    let message = NFCNDEFMessage(records: [payload])
                    guard message.length <= capacity else {
                        session.invalidate(errorMessage: "Invite too large for this tag (\(capacity) bytes available).")
                        return
                    }
                    tag.writeNDEF(message) { error in
                        if let error {
                            session.invalidate(errorMessage: "Write failed: \(error.localizedDescription)")
                        } else {
                            session.alertMessage = "Tag written! Others can tap this tag to join the group."
                            session.invalidate()
                            Task { @MainActor in self?.status = .success }
                        }
                    }
                @unknown default:
                    session.invalidate(errorMessage: "Unknown tag status.")
                }
            }
        }
    }
}
