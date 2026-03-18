import AppKit
import SwiftUI

/// A floating NSPanel for meeting detection notifications.
/// Non-activating so it doesn't steal focus from the meeting app.
final class MeetingPopupPanel: NSPanel {
    init() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 130
        let margin: CGFloat = 16
        let contentRect = NSRect(
            x: screenFrame.maxX - panelWidth - margin,
            y: screenFrame.maxY - panelHeight - margin,
            width: panelWidth,
            height: panelHeight
        )

        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        let hidden = UserDefaults.standard.object(forKey: "hideFromScreenShare") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "hideFromScreenShare")
        sharingType = hidden ? .none : .readOnly
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .alertPanel
        collectionBehavior = [.canJoinAllSpaces, .transient]
    }
}

/// SwiftUI content for the meeting popup notification.
struct MeetingPopupContent: View {
    let title: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Spacer()
            }

            Text("Would you like to start recording?")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            // Buttons
            HStack(spacing: 10) {
                Button(action: onStart) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 6, height: 6)
                        Text("Start Recording")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.green.opacity(0.85))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(16)
        .frame(width: 300, height: 130)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Manages the meeting popup panel lifecycle.
@MainActor
final class MeetingPopupManager {
    private var panel: MeetingPopupPanel?
    private var autoDismissTimer: Timer?

    func show(meeting: DetectedMeeting, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hide()

        let popup = MeetingPopupPanel()
        let content = MeetingPopupContent(
            title: meeting.title,
            onStart: { [weak self] in
                self?.hide()
                onStart()
            },
            onDismiss: { [weak self] in
                self?.hide()
                onDismiss()
            }
        )

        let hostingView = NSHostingView(rootView: content)
        popup.contentView = hostingView
        popup.orderFront(nil)
        panel = popup

        // Auto-dismiss after 30 seconds
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
                onDismiss()
            }
        }
    }

    func hide() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    var isVisible: Bool {
        panel?.isVisible == true
    }
}
