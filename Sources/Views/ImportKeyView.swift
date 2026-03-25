import SwiftUI
import NostrSDK

/// Modal sheet that imports an nsec (plaintext) or ncryptsec (NIP-49 encrypted)
/// to replace the current Nostr identity.
struct ImportKeyView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    /// Called after a successful import — lets the parent pop back to Settings.
    var onImportSuccess: (() -> Void)?

    @State private var keyInput = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isImporting = false
    @State private var errorMessage: String?
    @State private var showConfirmation = false

    /// The resolved nsec ready for import (set after validation/decryption).
    @State private var resolvedNsec: String?

    private enum Field { case key, password }

    private var keyFormat: KeyFormat {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("nsec1") { return .nsec }
        if trimmed.hasPrefix("ncryptsec1") { return .ncryptsec }
        return .unknown
    }

    private var canValidate: Bool {
        switch keyFormat {
        case .nsec: return true
        case .ncryptsec: return !password.isEmpty
        case .unknown: return false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                inputSection
                if keyFormat == .ncryptsec { passwordSection }
                if let errorMessage { errorSection(errorMessage) }
                actionSection
            }
            .navigationTitle("Import Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Replace Identity?", isPresented: $showConfirmation) {
                Button("Cancel", role: .cancel) { resolvedNsec = nil }
                Button("Replace Identity", role: .destructive) { performImport() }
            } message: {
                Text("This will replace your current Nostr identity. All group memberships will be lost and you will need to be re-invited. This cannot be undone.")
            }
        }
    }

    // MARK: - Sections

    private var inputSection: some View {
        Section {
            TextField("nsec1… or ncryptsec1…", text: $keyInput, axis: .vertical)
                .font(.caption.monospaced())
                .lineLimit(3...6)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .key)
        } header: {
            Text("Paste Your Key")
        } footer: {
            switch keyFormat {
            case .nsec:     Text("Detected: plaintext private key (nsec)")
            case .ncryptsec: Text("Detected: encrypted key (ncryptsec) — enter your password below")
            case .unknown:
                if keyInput.isEmpty {
                    Text("Paste an nsec (plaintext) or ncryptsec (NIP-49 encrypted) key.")
                } else {
                    Text("Unrecognised format. Keys should start with nsec1 or ncryptsec1.")
                }
            }
        }
    }

    private var passwordSection: some View {
        Section("Decryption Password") {
            HStack {
                Group {
                    if showPassword {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                .textContentType(.password)
                .focused($focusedField, equals: .password)

                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.subheadline)
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                focusedField = nil
                validateAndConfirm()
            } label: {
                HStack {
                    Spacer()
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                        Text("Validating…")
                    } else {
                        Label("Import Key", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                }
            }
            .disabled(!canValidate || isImporting)
        } footer: {
            Text("Importing a key will replace your current identity and remove all group memberships.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func validateAndConfirm() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentFormat = keyFormat
        let pw = password
        let currentPubHex = appViewModel.identity.identity?.publicKeyHex

        isImporting = true
        errorMessage = nil

        // Run crypto on a real GCD thread — the Rust FFI scrypt call is
        // a long-running synchronous block that starves the cooperative
        // thread pool if run inside Task.detached.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let nsec: String
                switch currentFormat {
                case .nsec:
                    do {
                        _ = try Keys.parse(secretKey: trimmed)
                    } catch {
                        throw ImportError.invalidNsec
                    }
                    nsec = trimmed

                case .ncryptsec:
                    do {
                        let encrypted = try EncryptedSecretKey.fromBech32(bech32: trimmed)
                        let secretKey = try encrypted.decrypt(password: pw)
                        nsec = try secretKey.toBech32()
                    } catch {
                        throw ImportError.decryptionFailed
                    }

                case .unknown:
                    throw ImportError.unrecognisedFormat
                }

                let parsed = try Keys.parse(secretKey: nsec)
                let importedPubHex = parsed.publicKey().toHex()

                DispatchQueue.main.async {
                    if importedPubHex == currentPubHex {
                        errorMessage = "This is already your current identity. No changes needed."
                        isImporting = false
                        return
                    }
                    resolvedNsec = nsec
                    isImporting = false
                    showConfirmation = true
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async {
                    errorMessage = msg
                    isImporting = false
                }
            }
        }
    }

    private func performImport() {
        guard let nsec = resolvedNsec else { return }
        isImporting = true

        Task {
            do {
                try await appViewModel.replaceIdentity(withNsec: nsec)
                dismiss()
                // Pop the parent Import/Export page back to Settings.
                onImportSuccess?()
            } catch {
                errorMessage = "Import failed: \(error.localizedDescription)"
                isImporting = false
            }
        }
    }

    // MARK: - Types

    private enum KeyFormat {
        case nsec, ncryptsec, unknown
    }

    private enum ImportError: LocalizedError {
        case unrecognisedFormat
        case invalidNsec
        case decryptionFailed

        var errorDescription: String? {
            switch self {
            case .unrecognisedFormat: return "Unrecognised key format."
            case .invalidNsec:       return "Invalid private key. Please check and try again."
            case .decryptionFailed:  return "Wrong password. Please try again."
            }
        }
    }
}
