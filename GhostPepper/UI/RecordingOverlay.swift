import SwiftUI
import AppKit

enum OverlayMessage: String {
    case recording = "Recording..."
    case modelLoading = "Loading models..."
    case cleaningUp = "Cleaning up..."
    case transcribing = "Transcribing..."
}

class RecordingOverlayController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<OverlayPillView>?

    func show(message: OverlayMessage = .recording) {
        let isLarge = message == .modelLoading
        let panelWidth: CGFloat = isLarge ? 250 : 300
        let panelHeight: CGFloat = isLarge ? 320 : 60

        if let hostingView = hostingView, let panel = panel {
            hostingView.rootView = OverlayPillView(message: message)
            panel.setContentSize(NSSize(width: panelWidth, height: panelHeight))
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = screenFrame.midX - panelWidth / 2
                let y = screenFrame.minY + 40
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            }
            panel.orderFrontRegardless()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: OverlayPillView(message: message))
        panel.contentView = hosting
        self.hostingView = hosting

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panelWidth / 2
            let y = screenFrame.minY + 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}

struct OverlayPillView: View {
    let message: OverlayMessage
    @State private var isPulsing = false
    @State private var spriteFrame = 0

    private let spriteTimer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
    private let frameCount = 5

    private var showSprite: Bool {
        message == .modelLoading
    }

    private var dotColor: Color {
        switch message {
        case .recording: return .red
        case .modelLoading: return .orange
        case .cleaningUp, .transcribing: return .blue
        }
    }

    var body: some View {
        Group {
            if showSprite {
                VStack(spacing: 6) {
                    spriteView
                    Text(message.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.black.opacity(0.85))
                )
            } else {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 10, height: 10)
                        .opacity(isPulsing ? 0.4 : 1.0)
                        .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)

                    Text(message.rawValue)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(.black.opacity(0.85))
                )
            }
        }
        .onAppear { isPulsing = true }
    }

    private var spriteView: some View {
        Image(nsImage: loadSpriteFrame(spriteFrame))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: 80, height: 250)
            .onReceive(spriteTimer) { _ in
                if showSprite {
                    spriteFrame = (spriteFrame + 1) % frameCount
                }
            }
    }

    private func loadSpriteFrame(_ index: Int) -> NSImage {
        let name = "sprite_frame_\(index)"
        for ext in ["png", "tiff", "tif"] {
            if let path = Bundle.main.path(forResource: name, ofType: ext),
               let image = NSImage(contentsOfFile: path) {
                return image
            }
        }
        if let image = NSImage(named: name) {
            return image
        }
        return NSImage()
    }
}
