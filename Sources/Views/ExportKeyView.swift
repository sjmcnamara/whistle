import SwiftUI
import NostrSDK

/// Modal sheet that encrypts the user's nsec with a password (NIP-49)
/// and presents the resulting ncryptsec for copy or share.
struct ExportKeyView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var ncryptsec: String?
    @State private var isExporting = false
    @State private var errorMessage: String?
    @State private var copied = false

    private var passwordsValid: Bool {
        !password.isEmpty && password == confirmPassword
    }

    var body: some View {
        NavigationStack {
            Form {
                if let ncryptsec {
                    resultSection(ncryptsec: ncryptsec)
                } else {
                    passwordSection
                }
            }
            .navigationTitle("Export Encrypted Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Password Entry

    private var passwordSection: some View {
        Group {
            Section {
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                SecureField("Confirm Password", text: $confirmPassword)
                    .textContentType(.newPassword)
            } header: {
                Text("Encryption Password")
            } footer: {
                Text("Choose a strong password. You will need it to import this key later.")
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            Section {
                Button {
                    exportKey()
                } label: {
                    HStack {
                        Spacer()
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                            Text("Encrypting…")
                        } else {
                            Label("Export Key", systemImage: "key.fill")
                        }
                        Spacer()
                    }
                }
                .disabled(!passwordsValid || isExporting)
            }
        }
    }

    // MARK: - Result Display

    private func resultSection(ncryptsec: String) -> some View {
        Group {
            Section {
                Text(ncryptsec)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(nil)
            } header: {
                Text("Encrypted Key (ncryptsec)")
            } footer: {
                Text("Store this somewhere safe. Anyone with this string and your password can access your Nostr identity.")
            }

            Section {
                Button {
                    copyToClipboard(ncryptsec)
                } label: {
                    Label(
                        copied ? "Copied" : "Copy to Clipboard",
                        systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc"
                    )
                }

                ShareLink(item: ncryptsec) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - Actions

    private func exportKey() {
        guard let nsec = appViewModel.identity.exportNsec() else {
            errorMessage = "Could not read private key from Keychain."
            return
        }

        isExporting = true
        errorMessage = nil

        // Capture password on the main actor before dispatching.
        let pw = password

        // Run crypto on a real GCD thread — the Rust FFI scrypt call is
        // a long-running synchronous block that starves the cooperative
        // thread pool if run inside Task.detached.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let secretKey = try Keys.parse(secretKey: nsec).secretKey()
                let encrypted = try secretKey.encrypt(password: pw)
                let result = try encrypted.toBech32()

                DispatchQueue.main.async {
                    self.ncryptsec = result
                    self.isExporting = false
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async {
                    self.errorMessage = "Encryption failed: \(msg)"
                    self.isExporting = false
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        // Auto-expire clipboard after 60 seconds for security.
        UIPasteboard.general.setItems(
            [[UIPasteboard.typeAutomatic: text]],
            options: [.expirationDate: Date().addingTimeInterval(60)]
        )
        withAnimation(.spring(duration: 0.2)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.spring(duration: 0.2)) { copied = false }
        }
    }
}
