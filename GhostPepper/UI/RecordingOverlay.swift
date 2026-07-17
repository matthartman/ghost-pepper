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

    func show(message: OverlayMessage = .recording) {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        if let hostingView = hostingView, let panel = panel {
            let size = panelSize(for: message)
            hostingView.rootView = OverlayPillView(message: message, onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil)
            panel.setContentSize(size)
            panel.ignoresMouseEvents = message != .noSoundDetected
            panel.contentViewController?.view.frame = NSRect(origin: .zero, size: size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            position(panel: panel)
            panel.orderFrontRegardless()
            currentMessage = message
            scheduleDismissIfNeeded(for: message)
            return
        }

        let size = panelSize(for: message)
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
        panel.ignoresMouseEvents = message != .noSoundDetected
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: OverlayPillView(message: message, onTap: message == .noSoundDetected ? { [weak self] in self?.onNoSoundSettingsTapped?() } : nil))
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

    private func panelSize(for message: OverlayMessage) -> NSSize {
        switch message {
        case .clipboardFallback, .learnedCorrection, .noSoundDetected:
            return NSSize(width: 420, height: 84)
        default:
            return NSSize(width: 300, height: 60)
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
    @AppStorage(AppTheme.storageKey) private var selectedThemeID = AppThemeID.current.rawValue
    @State private var isPulsing = false

    private var appTheme: AppTheme {
        AppTheme.resolve(selectedThemeID)
    }

    private var textColor: Color {
        appTheme.usesDarkText ? .black : .white
    }

    private var pillFill: Color {
        switch appTheme.id {
        case .current:
            return .black.opacity(0.85)
        case .windows95:
            return Color(red: 0.78, green: 0.78, blue: 0.72).opacity(0.96)
        case .space:
            return Color(red: 0.03, green: 0.04, blue: 0.16).opacity(0.92)
        }
    }

    private var dotColor: Color {
        switch message {
        case .recording:
            return .red
        case .modelLoading:
            return appTheme.accent
        case .cleaningUp, .transcribing, .clipboardFallback:
            return appTheme.id == .current ? .blue : appTheme.accent
        case .noSoundDetected:
            return appTheme.accent
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
                    .foregroundStyle(textColor)

                if let secondaryText = message.secondaryText {
                    Text(secondaryText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(textColor.opacity(0.8))
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(pillFill)
                .overlay(Capsule().stroke(appTheme.accent.opacity(appTheme.id == .current ? 0 : 0.7), lineWidth: appTheme.id == .current ? 0 : 1))
        )
        .onAppear { isPulsing = true }
        .onTapGesture {
            onTap?()
        }
    }
}
