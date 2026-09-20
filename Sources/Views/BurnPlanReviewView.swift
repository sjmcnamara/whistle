import SwiftUI

/// Shown before the final Burn Identity confirmation only when at least one
/// active group would be stranded — i.e. the user is its sole admin. Lets
/// them promote another member per affected group, or explicitly accept
/// that the group ends. Groups where they're not the sole admin are left
/// automatically with no per-group review needed.
struct BurnPlanReviewView: View {
    let plan: BurnPlan
    @Binding var promotions: [String: String]
    let onContinue: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !plan.autoLeaveGroupIds.isEmpty {
                    Section {
                        Text("You'll be automatically removed from \(plan.autoLeaveGroupIds.count) other group(s).")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(plan.soleAdminGroups) { group in
                    Section {
                        if group.candidates.isEmpty {
                            Label("No other members — this group will end.", systemImage: "xmark.circle")
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Promote", selection: Binding(
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
                    } header: {
                        Text(group.groupName)
                    } footer: {
                        if !group.candidates.isEmpty {
                            Text("You're the only admin. Promote someone to keep this group going, or it will end when you burn.")
                        }
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
