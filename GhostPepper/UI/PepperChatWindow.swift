import AppKit
import SwiftUI

private final class PepperChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PepperChatWindowController: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private var isMinimized = false
    var onOpenInMeetings: ((URL) -> Void)?
    var onSendToTrello: ((String, String?) -> Void)?
    var isTrelloConfigured: () -> Bool = { false }

    func show(session: PepperChatSession) {
        if let window {
            if isMinimized {
                popUp()
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            return
        }

        let onMinimize: () -> Void = { [weak self] in self?.minimize() }
        let rootView = ContextBubbleView(
            session: session,
            onMinimize: onMinimize,
            onSendToZo: { prompt, screenContext in
                Task {
                    await session.sendMessage(prompt, screenContext: screenContext)
                }
            },
            onSendToTrello: onSendToTrello,
            isTrelloConfigured: isTrelloConfigured(),
            onCopyBundle: { bundle in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(bundle, forType: .string)
            },
            onOpenInMeetings: { [weak self] url in
                self?.onOpenInMeetings?(url)
            }
        )
        let window = PepperChatPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentViewController = NSHostingController(rootView: rootView)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - window.frame.width / 2
            let y = screenFrame.midY - window.frame.height / 2 + 50 // slightly above center
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.makeKeyAndOrderFront(nil)
        self.window = window
        isMinimized = false
    }

    func popUp() {
        guard let window else { return }
        isMinimized = false
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func minimize() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            window.orderOut(nil)
            self?.isMinimized = true
        })
    }

    func showIfOpen() {
        if isMinimized {
            popUp()
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        minimize()
        return false
    }

    func shutdown() {
        guard let window else { return }
        window.delegate = nil
        window.contentViewController = nil
        window.orderOut(nil)
        self.window = nil
        isMinimized = false
    }
}

private struct PepperChatWindowView: View {
    @ObservedObject var session: PepperChatSession
    let onMinimize: () -> Void
    @State private var isBubbleVisible = true
    @State private var previousMessageCount = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isBubbleVisible {
                speechBubble
                    .frame(width: 320)
                    .padding(.top, 40)
                    .padding(.leading, 50)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading)))
            }

            pepperCharacter
                .offset(x: -10, y: -10)
                .onTapGesture(count: 2) {
                    onMinimize()
                }
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isBubbleVisible.toggle()
                    }
                }
        }
        .frame(width: isBubbleVisible ? 380 : 100, height: isBubbleVisible ? 560 : 100, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.2), value: isBubbleVisible)
        .onChange(of: session.messages.count) { _, newCount in
            if newCount > previousMessageCount && !isBubbleVisible {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isBubbleVisible = true
                }
            }
            previousMessageCount = newCount
        }
    }

    private var speechBubble: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Text("Pepper Chat")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                if !session.messages.isEmpty {
                    Button(action: { session.clearHistory() }) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isBubbleVisible = false
                    }
                }) {
                    Image(systemName: "minus.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Hide bubble")

                Button(action: onMinimize) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Close Pepper Chat")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Chat messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.messages.isEmpty {
                            emptyState
                        }
                        ForEach(session.messages) { message in
                            if !(message.text.isEmpty && message.role == .assistant && session.isProcessing) {
                                ChatBubble(message: message, onActionResponded: { messageID in
                                    session.markActionResponded(messageID: messageID)
                                })
                                    .id(message.id)
                            }
                        }
                        if session.isProcessing {
                            thinkingDots.id("thinking")
                        }
                    }
                    .padding(12)
                }
                .onChange(of: session.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: session.isProcessing) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            // Screen context badge
            if let context = session.pendingScreenContext, !context.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Screen context")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(action: { session.pendingScreenContext = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
            }

            Divider()

            // Input area
            inputArea
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
        )
    }

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if session.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Recording...")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else if session.isTranscribing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Transcribing...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else {
                TextField("Type a message...", text: $session.pendingInput, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .frame(minHeight: 30)
                    .onSubmit {
                        Task { await session.sendTypedMessage() }
                    }

                Button(action: {
                    Task { await session.sendTypedMessage() }
                }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(session.pendingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.3) : Color.orange)
                }
                .buttonStyle(.borderless)
                .disabled(session.pendingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var pepperCharacter: some View {
        VStack {
            Spacer()
            if let imagePath = Bundle.main.path(forResource: "ghost-pepper-character", ofType: "png"),
               let nsImage = NSImage(contentsOfFile: imagePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 90, height: 90)
            } else {
                Text("🌶️")
                    .font(.system(size: 60))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Ask me anything!")
                .font(.callout.weight(.medium))
            Text("Type below or hold your shortcut to speak.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var thinkingDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
                    .opacity(0.5)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15),
                        value: session.isProcessing
                    )
            }
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if session.isProcessing {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("thinking", anchor: .bottom)
            }
        } else if let lastID = session.messages.last?.id {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }
}

private struct ChatBubble: View {
    let message: PepperChatMessage
    var onActionResponded: ((UUID) -> Void)?

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if message.role == .user, let context = message.screenContext, !context.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.caption2)
                    Text("Screen context sent")
                        .font(.caption2)
                }
                .foregroundStyle(.tertiary)
            }

            if message.text.isEmpty {
                Text("...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .bubbleBackground(role: message.role)
            } else if message.role == .assistant, let rendered = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(rendered)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .bubbleBackground(role: message.role)
            } else {
                Text(message.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .bubbleBackground(role: message.role)
            }

            // Action buttons (e.g., meeting transcription prompt)
            if let action = message.action, !action.responded {
                HStack(spacing: 8) {
                    Button(action.acceptLabel) {
                        action.onAccept()
                        onActionResponded?(message.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)

                    Button(action.declineLabel) {
                        action.onDecline?()
                        onActionResponded?(message.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

private extension View {
    func bubbleBackground(role: PepperChatMessage.Role) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(role == .user
                      ? Color.orange.opacity(0.15)
                      : Color(nsColor: .controlBackgroundColor))
        )
    }
}
