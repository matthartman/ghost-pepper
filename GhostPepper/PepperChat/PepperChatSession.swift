import AppKit
import Foundation

struct PepperChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String
    let timestamp: Date
    var screenContext: String?
    var action: PepperChatAction?

    enum Role {
        case user
        case assistant
    }
}

/// An actionable prompt with buttons (e.g., meeting transcription offer).
struct PepperChatAction {
    let acceptLabel: String
    let declineLabel: String
    let onAccept: () -> Void
    let onDecline: (() -> Void)?
    var responded: Bool = false
}

@MainActor
final class PepperChatSession: ObservableObject {
    @Published private(set) var messages: [PepperChatMessage] = []
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published private(set) var isProcessing = false
    @Published var pendingInput: String = ""
    @Published var pendingScreenContext: String?
    @Published var capturedCommand: String?
    @Published var capturedScreenContext: String?
    @Published var capturedScreenshots: [NSImage] = []
    @Published var capturedContextTexts: [String] = []
    @Published var capturedAppNames: [String] = []
    @Published var isReviewingContext = false
    /// Screen contexts captured during recording (one per window switch)
    var preCapturedScreenContexts: [String] = []

    private let transcriber: SpeechTranscriber
    private let ocrService: FrontmostWindowOCRService
    private var backendProvider: () -> PepperChatBackend?
    private var cleanupProvider: ((String) async -> String)?
    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        transcriber: SpeechTranscriber,
        ocrService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        backendProvider: @escaping () -> PepperChatBackend? = { nil }
    ) {
        self.transcriber = transcriber
        self.ocrService = ocrService
        self.backendProvider = backendProvider
    }

    func updateCleanupProvider(_ provider: @escaping (String) async -> String) {
        self.cleanupProvider = provider
    }

    func updateBackendProvider(_ provider: @escaping () -> PepperChatBackend?) {
        self.backendProvider = provider
    }

    private var activeProcessingCount = 0

    func processRecording(audioBuffer: [Float], includeScreenContext: Bool) async {
        guard !audioBuffer.isEmpty else {
            debugLogger?(.model, "Pepper Chat: empty audio buffer, skipping.")
            return
        }

        isTranscribing = true
        let rawTranscription = await transcriber.transcribe(audioBuffer: audioBuffer)
        isTranscribing = false

        guard let rawTranscription, !rawTranscription.isEmpty else {
            debugLogger?(.model, "Pepper Chat: no transcription detected, showing context review anyway.")
            // Still show context review so user can access captured screenshots
            let allContexts = preCapturedScreenContexts
            preCapturedScreenContexts = []
            capturedCommand = ""
            capturedScreenContext = allContexts.isEmpty ? nil : allContexts.joined(separator: "\n\n---\n\n")
            capturedContextTexts = allContexts
            isReviewingContext = true
            return
        }

        // Run cleanup (same as voice-to-text paste) to fix misheard words
        let transcription: String
        if let cleanupProvider {
            transcription = await cleanupProvider(rawTranscription)
            debugLogger?(.model, "Pepper Chat: cleaned \"\(rawTranscription)\" → \"\(transcription)\"")
        } else {
            transcription = rawTranscription
        }

        // Use pre-captured contexts (captured during recording, one per window)
        let allContexts = preCapturedScreenContexts
        preCapturedScreenContexts = []

        // Combine all captured contexts into one
        let screenContext = allContexts.isEmpty ? nil : allContexts.joined(separator: "\n\n---\n\n")

        // Pause for context review — user chooses action from the bubble
        capturedCommand = transcription
        capturedScreenContext = screenContext
        capturedContextTexts = allContexts
        isReviewingContext = true
    }

    func sendTypedMessage() async {
        let text = pendingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let screenContext = pendingScreenContext
        pendingInput = ""
        pendingScreenContext = nil

        await sendMessage(text, screenContext: screenContext)
    }

    func captureScreenContext() async {
        let ocrResult = await ocrService.captureContext(customWords: [])
        pendingScreenContext = ocrResult?.windowContents
    }

    func sendMessage(_ text: String, screenContext: String?) async {
        activeProcessingCount += 1
        isProcessing = true

        let userMessage = PepperChatMessage(role: .user, text: text, timestamp: Date(), screenContext: screenContext)
        messages.append(userMessage)

        // Build conversation history into prompt
        let promptWithHistory = buildPromptWithHistory(newMessage: text, screenContext: screenContext)

        guard let backend = backendProvider() else {
            let errorMessage = PepperChatMessage(
                role: .assistant,
                text: "Add your Zo API key in Settings > Pepper Chat.",
                timestamp: Date()
            )
            messages.append(errorMessage)
            activeProcessingCount -= 1
            if activeProcessingCount == 0 { isProcessing = false }
            return
        }

        let assistantMessage = PepperChatMessage(role: .assistant, text: "", timestamp: Date())
        messages.append(assistantMessage)
        let messageID = assistantMessage.id

        do {
            try await backend.send(prompt: promptWithHistory, screenContext: nil) { [weak self] chunk in
                guard let self else { return }
                if let index = self.messages.firstIndex(where: { $0.id == messageID }) {
                    self.messages[index].text += chunk
                }
            }
            debugLogger?(.model, "Pepper Chat: response complete.")
        } catch {
            if let index = messages.firstIndex(where: { $0.id == messageID }), messages[index].text.isEmpty {
                messages[index].text = "Error: \(error.localizedDescription)"
            }
            debugLogger?(.model, "Pepper Chat: backend error: \(error.localizedDescription)")
        }

        activeProcessingCount -= 1
        if activeProcessingCount == 0 { isProcessing = false }
    }

    func clearHistory() {
        messages.removeAll()
    }

    /// Clear the conversation thread — next question starts fresh.
    func clearThread() {
        messages.removeAll(where: { $0.action == nil }) // keep action messages (meeting prompts)
        capturedCommand = nil
        capturedScreenContext = nil
        capturedScreenshots = []
        capturedContextTexts = []
        capturedAppNames = []
        isReviewingContext = false
    }

    func cancelForTermination() {
        isRecording = false
        isTranscribing = false
        isReviewingContext = false
        pendingInput = ""
        pendingScreenContext = nil
        capturedCommand = nil
        capturedScreenContext = nil
        capturedScreenshots = []
        capturedContextTexts = []
        capturedAppNames = []
        preCapturedScreenContexts = []
    }

    /// Build a prompt that includes prior conversation as context.
    private func buildPromptWithHistory(newMessage: String, screenContext: String?) -> String {
        var parts: [String] = []

        // Prior conversation
        let priorMessages = messages.dropLast(1) // exclude the just-added user message
            .filter { $0.action == nil } // exclude action messages
        if !priorMessages.isEmpty {
            var history: [String] = []
            for msg in priorMessages {
                let role = msg.role == .user ? "You" : "Zo"
                if !msg.text.isEmpty {
                    history.append("**\(role):** \(msg.text)")
                }
            }
            if !history.isEmpty {
                parts.append("Previous conversation:\n\(history.joined(separator: "\n\n"))")
            }
        }

        // Screen context
        if let context = screenContext, !context.isEmpty {
            parts.append("[Screen context from frontmost window]\n\(context)")
        }

        // New question
        parts.append(newMessage)

        return parts.joined(separator: "\n\n")
    }

    /// Export the current thread as a markdown string for saving as a note.
    func exportThreadAsMarkdown() -> String? {
        let threadMessages = messages.filter { $0.action == nil && !$0.text.isEmpty }
        guard !threadMessages.isEmpty else { return nil }

        let firstCommand = threadMessages.first?.text ?? "Zo Chat"
        let title = String(firstCommand.prefix(50))

        var lines: [String] = []
        lines.append("# Zo Chat — \(title)")
        lines.append("")

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        if let firstDate = threadMessages.first?.timestamp {
            lines.append("**Date:** \(formatter.string(from: firstDate))")
            lines.append("")
        }

        lines.append("## Thread")
        lines.append("")

        for msg in threadMessages {
            let role = msg.role == .user ? "You" : "Zo"
            lines.append("**\(role):** \(msg.text)")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Mark an action message as responded (hides the buttons).
    func markActionResponded(messageID: UUID) {
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].action?.responded = true
        }
    }

    /// Show a transcription prompt with accept/decline buttons.
    func showMeetingPrompt(meeting: DetectedMeeting, onAccept: @escaping () -> Void) {
        let action = PepperChatAction(
            acceptLabel: "Yes, transcribe",
            declineLabel: "No thanks",
            onAccept: onAccept,
            onDecline: nil
        )

        let promptText: String
        switch meeting.appName {
        case "YouTube", "Vimeo", "Twitch", "Loom", "Netflix", "Dailymotion":
            promptText = "Looks like you're watching a video on **\(meeting.appName)**. Want me to create notes and transcribe it?"
        default:
            promptText = "Looks like you're on a **\(meeting.appName)** call. Want me to transcribe it?"
        }

        let message = PepperChatMessage(
            role: .assistant,
            text: promptText,
            timestamp: Date(),
            action: action
        )
        messages.append(message)
    }
}
