import AppKit
import SwiftUI

/// A floating NSPanel for the meeting detection notification.
final class MeetingNotificationPanel: NSPanel {
    init() {
        let width: CGFloat = 320
        let height: CGFloat = 60
        // Position top-right of the main screen
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: screenFrame.maxX - width - 16,
            y: screenFrame.maxY - height - 16
        )
        let rect = NSRect(origin: origin, size: NSSize(width: width, height: height))

        super.init(
            contentRect: rect,
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
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}

/// Manages the meeting notification panel lifecycle.
@MainActor
final class MeetingNotificationManager {
    private var panel: MeetingNotificationPanel?
    private var autoDismissTask: Task<Void, Never>?

    var isVisible: Bool {
        panel?.isVisible == true
    }

    func show(onStartRecording: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hide()

        let panel = MeetingNotificationPanel()
        let content = MeetingNotificationView(
            onStartRecording: { [weak self] in
                onStartRecording()
                self?.hide()
            },
            onDismiss: { [weak self] in
                onDismiss()
                self?.hide()
            }
        )
        let hostingView = NSHostingView(rootView: content)
        panel.contentView = hostingView
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 1
        }

        self.panel = panel

        // Auto-dismiss after 15 seconds
        autoDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            onDismiss()
            hide()
        }
    }

    func hide() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.panel = nil
        })
    }
}
