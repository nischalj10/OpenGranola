import SwiftUI

struct MeetingNotificationView: View {
    var onStartRecording: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(Color.accentTeal)

            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting Detected")
                    .font(.system(size: 13, weight: .semibold))
                Text("Your microphone is being used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onStartRecording) {
                Text("Start Recording")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentTeal, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}
