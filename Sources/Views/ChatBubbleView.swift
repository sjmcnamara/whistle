import SwiftUI

/// A single chat message bubble — right-aligned blue for "me", left-aligned grey for others.
struct ChatBubbleView: View {
    let message: ChatViewModel.ChatMessageItem

    var body: some View {
        HStack {
            if message.isMe { Spacer(minLength: 60) }

            VStack(alignment: message.isMe ? .trailing : .leading, spacing: 4) {
                if !message.isMe {
                    Text(message.senderDisplayName)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }

                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(message.isMe ? Color.blue : Color(.systemGray5))
                    .foregroundStyle(message.isMe ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                Text(message.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !message.isMe { Spacer(minLength: 60) }
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
}
