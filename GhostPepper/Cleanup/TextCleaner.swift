import Foundation

struct TextCleanerPerformance {
    let modelCallDuration: TimeInterval?
    let postProcessDuration: TimeInterval?
}

struct TextCleanerResult {
    let text: String
    let performance: TextCleanerPerformance
}

final class TextCleaner {
    private static let thinkBlockExpression = try? NSRegularExpression(
        pattern: #"(?is)<think\b[^>]*>.*?</think>"#
    )
    private static let leadingThinkTagExpression = try? NSRegularExpression(
        pattern: #"(?is)^\s*<think\b[^>]*>"#
    )

    private let localBackend: CleanupBackend
    private let correctionStore: CorrectionStore
    var debugLogger: ((DebugLogCategory, String) -> Void)?
    var sensitiveDebugLogger: ((DebugLogCategory, String) -> Void)?

    static let defaultPrompt = """
    You are an echo machine. Repeat back EVERYTHING the user says. Your ONLY allowed edits are:
    1. Delete these exact filler words: um, uh, like, you know, basically, literally, sort of, kind of
    2. ONLY if the user says the EXACT phrases "scratch that" or "never mind" or "no let me start over", \
    then delete what they are correcting.
    3. Otherwise keep the wording and meaning the same, but correct obvious recognition misses for names, \
    models, commands, files, and jargon when supporting context clearly shows the intended term.

    CRITICAL: Do NOT delete sentences. Do NOT remove context. Do NOT summarize. \
    If you are unsure whether to keep or delete something, KEEP IT. Do not keep an obvious \
    misrecognition just because it was spoken that way.

    Input: "So um like the meeting is at 3pm you know on Tuesday"
    Output: So the meeting is at 3pm on Tuesday

    Input: "Okay so now I'm recording and it becomes a red recording thing. Do you think we could change the icon?"
    Output: Okay so now I'm recording and it becomes a red recording thing. Do you think we could change the icon?

    Input: "Hey Becca I have an email. Scratch that, this email is for Pete. Hey Pete, this is my email."
    Output: Hey Pete, this is my email.

    Input: "What is a synonym for whisper?"
    Output: What is a synonym for whisper?

    Input: "I've been working on this and I'm stuck. Any ideas?"
    Output: I've been working on this and I'm stuck. Any ideas?
    """

    init(
        localBackend: CleanupBackend,
        correctionStore: CorrectionStore = CorrectionStore()
    ) {
        self.localBackend = localBackend
        self.correctionStore = correctionStore
    }

    convenience init(
        cleanupManager: TextCleaningManaging,
        correctionStore: CorrectionStore = CorrectionStore()
    ) {
        self.init(
            localBackend: LocalLLMCleanupBackend(cleanupManager: cleanupManager),
            correctionStore: correctionStore
        )
    }

    @MainActor
    func clean(text: String, prompt: String? = nil) async -> String {
        let result = await cleanWithPerformance(text: text, prompt: prompt)
        return result.text
    }

    @MainActor
    func cleanWithPerformance(text: String, prompt: String? = nil) async -> TextCleanerResult {
        let activePrompt = prompt ?? Self.defaultPrompt
        let correctionEngine = DeterministicCorrectionEngine(
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard
        )
        let correctedText = correctionEngine.applyPreCleanupCorrections(to: text)
        if correctedText == text {
            sensitiveDebugLogger?(.cleanup, "Pre-cleanup corrections: no changes applied.")
        } else {
            sensitiveDebugLogger?(
                .cleanup,
                """
                Pre-cleanup corrections:
                input:
                \(text)

                output:
                \(correctedText)
                """
            )
        }

        do {
            let modelCallStart = Date()
            let cleanedText = try await localBackend.clean(text: correctedText, prompt: activePrompt)
            let modelCallDuration = Date().timeIntervalSince(modelCallStart)
            let postProcessStart = Date()
            let sanitizedText = Self.sanitizeCleanupOutput(cleanedText)

            if sanitizedText != cleanedText {
                debugLogger?(.cleanup, "Stripped model reasoning tags from cleanup output.")
            }

            let finalText = correctionEngine.applyPostCleanupCorrections(to: sanitizedText)
            logCleanupTranscript(
                prompt: activePrompt,
                input: correctedText,
                rawOutput: cleanedText,
                sanitizedOutput: sanitizedText,
                finalOutput: finalText
            )
            if finalText == sanitizedText {
                sensitiveDebugLogger?(.cleanup, "Post-cleanup corrections: no changes applied.")
            } else {
                sensitiveDebugLogger?(
                    .cleanup,
                    """
                    Post-cleanup corrections:
                    input:
                    \(sanitizedText)

                    output:
                    \(finalText)
                    """
                )
            }
            return TextCleanerResult(
                text: finalText,
                performance: TextCleanerPerformance(
                    modelCallDuration: modelCallDuration,
                    postProcessDuration: Date().timeIntervalSince(postProcessStart)
                )
            )
        } catch {
            debugLogger?(.cleanup, "Cleanup backend unavailable, returning deterministic corrections only.")
            let postProcessStart = Date()
            let finalText = correctionEngine.applyPostCleanupCorrections(to: correctedText)
            if finalText == correctedText {
                sensitiveDebugLogger?(.cleanup, "Post-cleanup corrections: no changes applied.")
            } else {
                sensitiveDebugLogger?(
                    .cleanup,
                    """
                    Post-cleanup corrections:
                    input:
                    \(correctedText)

                    output:
                    \(finalText)
                    """
                )
            }
            return TextCleanerResult(
                text: finalText,
                performance: TextCleanerPerformance(
                    modelCallDuration: nil,
                    postProcessDuration: Date().timeIntervalSince(postProcessStart)
                )
            )
        }
    }

    static func sanitizeCleanupOutput(_ text: String) -> String {
        var sanitizedText = text

        if let expression = Self.thinkBlockExpression {
            let range = NSRange(sanitizedText.startIndex..., in: sanitizedText)
            sanitizedText = expression.stringByReplacingMatches(in: sanitizedText, range: range, withTemplate: "")
        }

        if let leadingThinkTagExpression = Self.leadingThinkTagExpression {
            let range = NSRange(sanitizedText.startIndex..., in: sanitizedText)
            if let match = leadingThinkTagExpression.firstMatch(in: sanitizedText, range: range),
               let thinkStart = Range(match.range, in: sanitizedText)?.lowerBound {
                sanitizedText = String(sanitizedText[..<thinkStart])
            }
        }

        return sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func logCleanupTranscript(
        prompt: String,
        input: String,
        rawOutput: String,
        sanitizedOutput: String,
        finalOutput: String
    ) {
        sensitiveDebugLogger?(
            .cleanup,
            """
            Cleanup LLM transcript:
            System prompt:
            \(prompt)

            User input:
            \(input)

            Raw model output:
            \(rawOutput)

            Sanitized model output:
            \(sanitizedOutput)

            Final cleaned output:
            \(finalOutput)
            """
        )
    }
}
