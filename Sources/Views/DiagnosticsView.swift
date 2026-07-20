import SwiftUI
import UIKit
import WhistleCore

/// Shows the diagnostics report and offers to copy or share it.
///
/// The report is displayed in full rather than hidden behind a share button.
/// It is meant to be pasteable into a public issue, so the user should be able
/// to read exactly what they are about to send — a diagnostics blob you cannot
/// inspect is one you should not trust.
struct DiagnosticsView: View {
    @EnvironmentObject private var appViewModel: AppViewModel

    @State private var json: String?
    @State private var fileURL: URL?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Text(
                    "A snapshot of this device's app and group state. It contains no messages, "
                    + "no locations, and no names — public keys and group IDs are shortened. "
                    + "Safe to share."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let json {
                Section("Report") {
                    Text(json)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = json
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }

                    if let fileURL {
                        ShareLink(item: fileURL) {
                            Label("Share as File", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            } else {
                Section {
                    HStack {
                        ProgressView()
                        Text("Collecting…").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task { await generate() }
    }

    private func generate() async {
        let report = await DiagnosticsCollector.collect(
            marmot: appViewModel.marmot,
            mls: appViewModel.mls,
            identity: appViewModel.identity,
            settings: appViewModel.settings,
            relay: appViewModel.relay
        )
        guard let text = try? report.jsonString() else { return }
        json = text
        fileURL = writeTempFile(text)
    }

    /// Write the report to a temp file so ShareLink can offer it as an
    /// attachment. Named with the date so two reports from the same device do
    /// not overwrite each other in the recipient's downloads.
    private func writeTempFile(_ text: String) -> URL? {
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: TimeZone(identifier: "UTC")!,
            formatOptions: [.withYear, .withMonth, .withDay]
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whistle-diagnostics-\(stamp).json")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            WhistleLogger.chat.error("Could not write diagnostics file: \(error)")
            return nil
        }
    }
}
