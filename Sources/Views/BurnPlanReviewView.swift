import SwiftUI

/// Shown before the final Burn Identity confirmation only when at least one
/// active group would be stranded — i.e. the user is its sole admin. Every
/// active group falls into one of three camps, shown as separate sections
/// so the very different consequences don't blur together: groups that just
/// continue without you, groups needing a promote-or-end decision, and solo
/// groups that end no matter what you choose.
struct BurnPlanReviewView: View {
    let plan: BurnPlan
    @Binding var promotions: [String: String]
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !plan.leaving.isEmpty {
                    Section {
                        ForEach(plan.leaving) { group in
                            Label(group.groupName, systemImage: "arrow.right.circle")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Leaving")
                    } footer: {
                        Text("Another admin remains — these groups continue without you.")
                    }
                }

                if !plan.promoteOrEnd.isEmpty {
                    Section {
                        ForEach(plan.promoteOrEnd) { group in
                            // Built from the same Label used in "Leaving"/"Will
                            // end" rather than a Picker(.navigationLink), whose
                            // title text renders at a subtly different weight
                            // than a plain Label in the same row — this
                            // guarantees identical text instead of hoping a
                            // .font() override lands the same way.
                            NavigationLink {
                                promoteOrEndDestination(for: group)
                            } label: {
                                HStack {
                                    Label(
                                        group.groupName,
                                        systemImage: promotions[group.groupId] == nil ? "xmark.circle" : "arrow.right.circle"
                                    )
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(selectedPromoteeName(for: group))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Choose a new admin")
                    } footer: {
                        Text("You're the only admin in these groups. Promote someone to keep it going, or let it end.")
                    }
                }

                if !plan.ending.isEmpty {
                    Section {
                        ForEach(plan.ending) { group in
                            Label(group.groupName, systemImage: "xmark.circle")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Will end")
                    } footer: {
                        Text("No other members — burning ends these groups.")
                    }
                }
            }
            .navigationTitle("Review Before Burning")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        dismiss()
                        onContinue()
                    }
                }
            }
        }
    }

    private func selectedPromoteeName(for group: BurnPlan.PromoteOrEndGroup) -> String {
        guard let pubkey = promotions[group.groupId] else { return "End this group" }
        return group.candidates.first { $0.pubkeyHex == pubkey }?.displayName ?? "End this group"
    }

    @ViewBuilder
    private func promoteOrEndDestination(for group: BurnPlan.PromoteOrEndGroup) -> some View {
        List {
            Button {
                promotions.removeValue(forKey: group.groupId)
            } label: {
                HStack {
                    Text("End this group")
                    Spacer()
                    if promotions[group.groupId] == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .foregroundStyle(.primary)
            ForEach(group.candidates) { candidate in
                Button {
                    promotions[group.groupId] = candidate.pubkeyHex
                } label: {
                    HStack {
                        Text(candidate.displayName)
                        Spacer()
                        if promotions[group.groupId] == candidate.pubkeyHex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .navigationTitle(group.groupName)
    }
}
