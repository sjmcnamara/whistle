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
                            HStack {
                                // Mirrors the icon in "Leaving"/"Will end" —
                                // reflects this row's *current* choice, so it
                                // updates live as the picker selection changes.
                                Image(systemName: promotions[group.groupId] == nil ? "xmark.circle" : "arrow.right.circle")
                                    .foregroundStyle(.secondary)
                                Picker(group.groupName, selection: Binding(
                                    get: { promotions[group.groupId] },
                                    set: { newValue in
                                        if let newValue {
                                            promotions[group.groupId] = newValue
                                        } else {
                                            promotions.removeValue(forKey: group.groupId)
                                        }
                                    }
                                )) {
                                    Text("End this group").tag(String?.none)
                                    ForEach(group.candidates) { candidate in
                                        Text(candidate.displayName).tag(String?.some(candidate.pubkeyHex))
                                    }
                                }
                                .pickerStyle(.navigationLink)
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
}
