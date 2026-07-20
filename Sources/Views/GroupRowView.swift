import SwiftUI

/// A row in the group list — shows group name, member count, and last activity.
struct GroupRowView: View {
    let group: GroupListViewModel.GroupListItem
    var isUnhealthy: Bool = false
    var isLeaving: Bool = false
    var hasAdminAction: Bool = false

    @ObservedObject private var avatars = LocalGroupAvatarStore.shared
    @EnvironmentObject private var sharedAvatars: SharedGroupAvatarStore

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                if let img = SharedGroupAvatarStore.resolvedImage(
                    for: group.id, local: avatars, shared: sharedAvatars
                ) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                        .opacity(group.isActive && !isLeaving ? 1 : 0.4)
                } else {
                    Image(systemName: "person.3.fill")
                        .font(.title2)
                        .foregroundStyle(group.isActive && !isLeaving ? .blue : .secondary)
                        .frame(width: 36)
                }
                if hasAdminAction {
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                        .offset(x: 2, y: -2)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.body.weight(group.hasUnread ? .bold : .regular))
                        .lineLimit(1)
                    if group.hasUnread {
                        Circle()
                            .fill(.blue)
                            .frame(width: 10, height: 10)
                    }
                }

                HStack(spacing: 8) {
                    Label("\(group.memberCount)", systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let lastActivity = group.lastActivity {
                        Text(lastActivity, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if isLeaving {
                Text("Leaving…")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.1))
                    .clipShape(Capsule())
            } else if isUnhealthy {
                Label("Decryption failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.red.opacity(0.1))
                    .clipShape(Capsule())
            } else if !group.isActive {
                Text("Inactive")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}
