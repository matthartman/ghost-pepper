import AppKit
import SwiftUI

/// Ghost Pepper logo view — uses the character image, falls back to emoji.
private struct PepperLogo: View {
    var size: CGFloat = 32

    var body: some View {
        if let image = NSImage(named: "ghost-pepper-character") ?? Bundle.main.image(forResource: "ghost-pepper-character") {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Text("🌶️")
                .font(.system(size: size * 0.7))
        }
    }
}

/// The Ghost Pepper Context Bubble — a branded floating panel that shows
/// captured screen context + spoken command with action buttons.
/// Displays the floating Context Bundler message list UI.
struct ContextBubbleView: View {
    @ObservedObject var session: PepperChatSession
    var onMinimize: () -> Void
    var onSendToZo: (String, String?) -> Void
    var onSendToTrello: ((String, String?) -> Void)?
    var isTrelloConfigured: Bool
    var onCopyBundle: (String) -> Void
    var onOpenInMeetings: ((URL) -> Void)?

    private func sendToZo(command: String, screenContext: String?) {
        session.isReviewingContext = false
        session.capturedCommand = nil
        session.capturedScreenContext = nil
        onSendToZo(command, screenContext)
    }

    private func copyBundle(command: String, screenContext: String?) {
        let bundle = formatBundle(command: command, context: screenContext)
        onCopyBundle(bundle)
        session.isReviewingContext = false
        session.capturedCommand = nil
        session.capturedScreenContext = nil
    }

    @State private var removedContextKeys: Set<String> = []
    @State private var showScreenshotPreview = false
    @State private var selectedActionIndex: Int = 0
    @State private var contextKeyMonitor: Any?
    private var actionCount: Int { isTrelloConfigured ? 3 : 2 }

    var body: some View {
        VStack(spacing: 0) {
            if session.isRecording || session.isTranscribing {
                recordingState
            } else if session.isReviewingContext, let command = session.capturedCommand {
                contextReview(command: command, screenContext: session.capturedScreenContext)
            } else if session.isProcessing {
                processingState
            } else if session.messages.contains(where: { $0.role == .assistant && !$0.text.isEmpty && $0.action == nil }) {
                chatHistoryView
            } else if let actionMessage = session.messages.last(where: { $0.action != nil && $0.action?.responded != true }) {
                meetingPromptView(message: actionMessage)
            } else if session.messages.contains(where: { $0.action?.responded == true }) {
                // Action was just handled (meeting started) — auto-dismiss
                Color.clear
                    .frame(height: 0)
                    .onAppear { onMinimize() }
            } else {
                // Nothing to show — dismiss
                Color.clear
                    .frame(height: 0)
                    .onAppear { onMinimize() }
            }
        }
        .frame(width: 380)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(
                    LinearGradient(
                        colors: [Color(nsColor: NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)),
                                 Color(nsColor: NSColor(red: 0.12, green: 0.09, blue: 0.06, alpha: 1))],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
    }

    // MARK: - Meeting Prompt

    private func meetingPromptView(message: PepperChatMessage) -> some View {
        VStack(spacing: 16) {
            PepperLogo(size: 40)

            if let rendered = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(rendered)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            } else {
                Text(message.text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }

            if let action = message.action {
                HStack(spacing: 10) {
                    Button(action: {
                        action.onAccept()
                        session.markActionResponded(messageID: message.id)
                    }) {
                        Text(action.acceptLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange))
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        action.onDecline?()
                        session.markActionResponded(messageID: message.id)
                    }) {
                        Text(action.declineLabel)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(24)
    }

    // MARK: - Recording State

    @State private var isPulsing = false

    private var recordingState: some View {
        VStack(spacing: 12) {
            // Compact recording pill
            HStack(spacing: 10) {
                PepperLogo(size: 24)

                // Red recording dot
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(isPulsing ? 0.4 : 1.0)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isPulsing)

                if session.isRecording {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording...")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white)
                        if !session.capturedScreenshots.isEmpty {
                            Text("\(session.capturedScreenshots.count) context\(session.capturedScreenshots.count == 1 ? "" : "s") captured")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.5))
                        } else {
                            Text("Click windows to add context")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                } else {
                    Text("Transcribing...")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }

                Spacer()

                Button(action: onMinimize) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            if session.isRecording {
                Text("Press hotkey again to stop · click windows to capture context")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
                    .padding(.bottom, 8)
            }
        }
        .onAppear { isPulsing = true }
    }

    // MARK: - Processing State (waiting for Zo response)

    private var processingState: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: onMinimize) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            VStack(spacing: 16) {
                PepperLogo(size: 64)
                ProgressView()
                    .scaleEffect(0.7)
                Text("Chatting with Zo...")
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .padding(.top, 8)
        }
    }

    // (No idle state — bubble auto-dismisses when nothing to show)

    // MARK: - Context Review

    private func contextReview(command: String, screenContext: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top) {
                PepperLogo(size: 28)
                Text(command)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(action: onMinimize) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            // Captured context
            if let context = screenContext, !context.isEmpty {
                capturedContextSection(context: context)
            }

            // Actions
            actionButtons(command: command, screenContext: screenContext)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .padding(.top, 8)
        }
        .onAppear {
            let action = detectDefaultAction(from: command)
            switch action {
            case .zo, .none: selectedActionIndex = 0
            case .trello: selectedActionIndex = isTrelloConfigured ? 1 : 0
            case .copy: selectedActionIndex = isTrelloConfigured ? 2 : 1
            }
        }
        .onAppear {
            contextKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                switch event.keyCode {
                case 123: // left arrow
                    selectedActionIndex = max(0, selectedActionIndex - 1)
                    return nil
                case 124: // right arrow
                    selectedActionIndex = min(actionCount - 1, selectedActionIndex + 1)
                    return nil
                case 36: // return
                    if selectedActionIndex == 0 {
                        sendToZo(command: command, screenContext: screenContext)
                    } else if selectedActionIndex == 1 && isTrelloConfigured {
                        onSendToTrello?(command, screenContext)
                        onMinimize()
                    } else {
                        copyBundle(command: command, screenContext: screenContext)
                    }
                    return nil
                case 53: // escape
                    onMinimize()
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = contextKeyMonitor {
                NSEvent.removeMonitor(monitor)
                contextKeyMonitor = nil
            }
        }
    }

    // MARK: - Captured Context

    private func capturedContextSection(context: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("WHAT I CAPTURED")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.orange.opacity(0.6))
                    .tracking(0.8)
                Spacer()
            }
            .padding(.horizontal, 20)

            // Screenshot thumbnails (multiple if user switched windows)
            if !session.capturedScreenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(session.capturedScreenshots.enumerated()), id: \.offset) { index, screenshot in
                            VStack(spacing: 4) {
                                Image(nsImage: screenshot)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.1)))
                                if index < session.capturedAppNames.count {
                                    Text(session.capturedAppNames[index])
                                        .font(.system(size: 9))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                        }
                    }
                    .padding(8)
                }
                .padding(.horizontal, 12)
            }

            // Context chips
            let chips = parseContextChips(from: context)
            if !chips.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(chips, id: \.key) { chip in
                        if !removedContextKeys.contains(chip.key) {
                            contextChip(icon: chip.icon, text: chip.text, key: chip.key)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }

            // Body preview
            let bodyPreview = extractBodyPreview(from: context)
            if !bodyPreview.isEmpty {
                Text(bodyPreview)
                    .font(.system(size: 12))
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    .lineLimit(4)
                    .lineSpacing(3)
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }
        }
    }

    private func contextChip(icon: String, text: String, key: String) -> some View {
        HStack(spacing: 5) {
            Text(icon)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
            Button(action: { removedContextKeys.insert(key) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08)))
        )
    }

    // MARK: - Chat History View

    @State private var savedNote = false

    private var chatHistoryView: some View {
        let threadMessages = session.messages.filter { $0.action == nil && !$0.text.isEmpty }

        return VStack(alignment: .leading, spacing: 0) {
            // Top bar — Clear context / Save as note
            HStack(spacing: 12) {
                Button(action: {
                    session.clearThread()
                    onMinimize()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 10))
                        Text("Clear context")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: saveAsNote) {
                    HStack(spacing: 4) {
                        Image(systemName: savedNote ? "checkmark" : "square.and.arrow.down")
                            .font(.system(size: 10))
                        Text(savedNote ? "Saved!" : "Save as note")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.orange)
                }
                .buttonStyle(.plain)

                Button(action: onMinimize) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // Thread
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(threadMessages) { msg in
                            chatMessageRow(msg)
                                .id(msg.id)
                        }

                        if session.isProcessing {
                            HStack(spacing: 6) {
                                Text("Zo")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(.orange)
                                ProgressView()
                                    .scaleEffect(0.5)
                                Text("Chatting with Zo...")
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            .id("processing")
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                .onChange(of: session.messages.count) { _, _ in
                    if let last = threadMessages.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxHeight: 500)

            // Bottom — Copy last response
            if let lastResponse = threadMessages.last(where: { $0.role == .assistant }) {
                HStack(spacing: 12) {
                    Button(action: {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lastResponse.text, forType: .string)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Copy last response")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.03))
            }
        }
    }

    private func chatMessageRow(_ message: PepperChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Role label
            Text(message.role == .user ? "You" : "Zo")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(message.role == .user ? .white.opacity(0.5) : .orange)

            // Message text
            if message.role == .assistant, let rendered = try? AttributedString(markdown: message.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                Text(rendered)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            } else {
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundColor(message.role == .user ? .white.opacity(0.8) : .white.opacity(0.9))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
    }

    private func saveAsNote() {
        guard let markdown = session.exportThreadAsMarkdown() else { return }
        let dir = MeetingTranscriptSettings.effectiveSaveDirectory()
        let dateFolder = {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: Date())
        }()
        let folder = dir.appendingPathComponent(dateFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let firstCommand = session.messages.first(where: { $0.role == .user })?.text ?? "zo-chat"
        let slug = MeetingMarkdownWriter.slugify(String(firstCommand.prefix(40)))
        let fileName = "zo-\(slug).md"
        let fileURL = folder.appendingPathComponent(fileName)
        try? markdown.write(to: fileURL, atomically: true, encoding: .utf8)

        savedNote = true
        onOpenInMeetings?(fileURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { savedNote = false }
    }

    // MARK: - (Legacy single response view — kept for reference)

    private func responseView(command: String, response: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — your command
            HStack(alignment: .top) {
                PepperLogo(size: 28)
                Text(command)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(2)
                Spacer()
                Button(action: onMinimize) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Zo label
            HStack(spacing: 6) {
                Text("Zo")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.orange)
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Response — grows to fill available screen height
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let rendered = try? AttributedString(markdown: response, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(rendered)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.9))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    } else {
                        Text(response)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.9))
                            .lineSpacing(5)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 500)

            // Bottom bar
            HStack(spacing: 12) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(response, forType: .string)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copy")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: onMinimize) {
                    Text("Done")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.03))
        }
    }

    // MARK: - Action Buttons

    private func actionButton(index: Int, icon: some View, label: String, action: @escaping () -> Void) -> some View {
        let isSelected = selectedActionIndex == index
        return Button(action: action) {
            HStack(spacing: 5) {
                icon
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isSelected ? .black : .white.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.orange : Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.orange : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private func actionButtons(command: String, screenContext: String?) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton(index: 0, icon: PepperLogo(size: 14), label: "Send to Zo") {
                    sendToZo(command: command, screenContext: screenContext)
                }

                if isTrelloConfigured {
                    actionButton(index: 1, icon: Image(systemName: "list.bullet.rectangle").font(.system(size: 11)), label: "Add to Trello") {
                        onSendToTrello?(command, screenContext)
                        onMinimize()
                    }
                }

                actionButton(index: isTrelloConfigured ? 2 : 1, icon: Image(systemName: "doc.on.doc").font(.system(size: 11)), label: "Copy") {
                    copyBundle(command: command, screenContext: screenContext)
                }
            }

            Text("← → to switch · ⏎ to confirm · esc to cancel")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    // MARK: - Helpers

    private enum DefaultAction {
        case zo, trello, copy, none
    }

    private func detectDefaultAction(from command: String) -> DefaultAction {
        let lower = command.lowercased()
        if lower.contains("trello") || lower.contains("card") || lower.contains("task") { return .trello }
        if lower.contains("copy") || lower.contains("clipboard") { return .copy }
        if lower.contains("zo") || lower.contains("send") || lower.contains("ask") { return .zo }
        return .zo // default to Zo
    }

    private struct ContextChip: Identifiable {
        let id: String
        let key: String
        let icon: String
        let text: String
    }

    private func parseContextChips(from context: String) -> [ContextChip] {
        var chips: [ContextChip] = []

        // Try to detect app from frontmost
        if let app = NSWorkspace.shared.frontmostApplication {
            let appName = app.localizedName ?? "Unknown"
            chips.append(ContextChip(id: "app", key: "app", icon: "💻", text: appName))
        }

        // Extract URL-like patterns
        let lines = context.components(separatedBy: .newlines)
        for line in lines.prefix(5) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("http") || trimmed.contains("www.") || trimmed.contains(".com/") {
                chips.append(ContextChip(id: "url", key: "url", icon: "🔗", text: String(trimmed.prefix(40))))
                break
            }
        }

        return chips
    }

    private func extractBodyPreview(from context: String) -> String {
        let lines = context.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("http") }
        return lines.prefix(8).joined(separator: "\n")
    }

    private func formatBundle(command: String, context: String?) -> String {
        var parts: [String] = []
        parts.append("**Command:** \(command)")
        if let context = context, !context.isEmpty {
            parts.append("**Context:**\n\(context)")
        }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Flow Layout (for chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), positions)
    }
}
