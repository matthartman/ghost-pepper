import SwiftUI
import AppKit

enum OverlayMessage: Equatable {
    case recording
    case modelLoading
    case cleaningUp
    case transcribing
    case clipboardFallback
    case noSoundDetected
    case learnedCorrection(MisheardReplacement)

    var primaryText: String {
        switch self {
        case .recording:
            return "Recording..."
        case .modelLoading:
            return "Loading models..."
        case .cleaningUp:
            return "Cleaning up..."
        case .transcribing:
            return "Transcribing..."
        case .clipboardFallback:
            return "Copied to clipboard"
        case .noSoundDetected:
            return "No sound detected"
        case .learnedCorrection:
            return "Learned correction"
        }
    }

    var secondaryText: String? {
        switch self {
        case .clipboardFallback:
            return "⌘V to paste"
        case .noSoundDetected:
            return "Check your mic in Settings → Recording"
        case .learnedCorrection(let replacement):
            return "\(replacement.wrong) -> \(replacement.right)"
        default:
            return nil
        }
    }
}

class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayPillView>?
    private var dismissWorkItem: DispatchWorkItem?
    private var currentMessage: OverlayMessage?
    var onNoSoundSettingsTapped: (() -> Void)?

    func show(message: OverlayMessage = .recording, onCancel: (() -> Void)? = nil) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if let hostingView = hostingView, let panel = panel {
            let size = panelSize(for: message, showsCancelButton: onCancel != nil)
            hostingView.rootView = OverlayPillView(
                message: message,
                onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil,
                onCancel: onCancel
            )
            panel.setContentSize(size)
            panel.ignoresMouseEvents = message != .noSoundDetected && onCancel == nil
            panel.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            position(panel: panel)
            panel.orderFrontRegardless()
            currentMessage = message
            scheduleDismissIfNeeded(for: message)
            return
        }

        let size = panelSize(for: message, showsCancelButton: onCancel != nil)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = message != .noSoundDetected && onCancel == nil
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: OverlayPillView(
            message: message,
            onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil,
            onCancel: onCancel
        ))
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let contentViewController = NSViewController()
        contentViewController.view = container
        panel.contentViewController = contentViewController
        self.hostingView = hosting

        position(panel: panel)
        panel.orderFrontRegardless()
        self.panel = panel
        currentMessage = message
        scheduleDismissIfNeeded(for: message)
    }

    func dismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        currentMessage = nil
    }

    func dismiss(ifShowing message: OverlayMessage) {
        guard currentMessage == message else {
            return
        }

        dismiss()
    }

    private func position(panel: NSPanel) {
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panel.frame.width / 2
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    private func panelSize(for message: OverlayMessage, showsCancelButton: Bool) -> NSSize {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected:
            return NSSize(width: 420, height: 84)
        default:
            return NSSize(width: showsCancelButton ? 330 : 300, height: 60)
        }
    }

    private func scheduleDismissIfNeeded(for message: OverlayMessage) {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected:
            let delay: TimeInterval = message == .noSoundDetected ? 5 : 3
            let workItem = DispatchWorkItem { [weak self] in
                self?.dismiss()
            }
            dismissWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        default:
            return
        }
    }
}

struct OverlayPillView: View {
    let message: OverlayMessage
    var onTap: (() -> Void)?
    var onCancel: (() -> Void)?
    @State private var isPulsing = false

    private var dotColor: Color {
        switch message {
        case .recording:
            return .red
        case .modelLoading:
            return .orange
        case .cleaningUp, .transcribing, .clipboardFallback:
            return .blue
        case .noSoundDetected:
            return .orange
        case .learnedCorrection:
            return .green
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if message == .modelLoading {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else if case .learnedCorrection = message {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
            } else {
                Circle()
                    .fill(dotColor)
                    .frame(width: 10, height: 10)
                    .opacity(isPulsing ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(message.primaryText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let secondaryText = message.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                }
            }

            if let onCancel {
                Spacer(minLength: 4)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityLabel("Cancel \(message.primaryText)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(.black.opacity(0.85))
        )
        .onAppear { isPulsing = true }
        .onTapGesture {
            onTap?()
        }
    }
}
