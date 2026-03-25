import SwiftUI

/// Settings sub-page offering Import and Export key flows.
struct IdentityImportExportView: View {
    @EnvironmentObject var appViewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showExport = false
    @State private var showImport = false

    var body: some View {
        List {
            Section {
                Button {
                    showExport = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Export Encrypted Backup")
                            Text("Encrypt your key with a password (NIP-49)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.blue)
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export your private key as an encrypted ncryptsec string that you can store safely or use to restore your identity on another device.")
            }

            Section {
                Button {
                    showImport = true
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Import Key")
                            Text("Replace identity with an nsec or ncryptsec")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.down")
                            .foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Restore / Migrate")
            } footer: {
                Text("Import an existing Nostr private key. This will replace your current identity and remove all group memberships.")
            }
        }
        .navigationTitle("Import / Export Key")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showExport) {
            ExportKeyView()
                .environmentObject(appViewModel)
        }
        .sheet(isPresented: $showImport) {
            ImportKeyView(onImportSuccess: { dismiss() })
                .environmentObject(appViewModel)
        }
    }
}
