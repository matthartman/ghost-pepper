import Foundation

final class TextCleaner {
    private static let thinkBlockExpression = try? NSRegularExpression(
        pattern: #"(?is)<think\b[^>]*>.*?</think>"#
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
    3. Nothing else. Keep ALL other words exactly as spoken.

    CRITICAL: Do NOT delete sentences. Do NOT remove context. Do NOT summarize. \
    If you are unsure whether to keep or delete something, KEEP IT.

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
            sensitiveDebugLogger?(
                .cleanup,
                """
                Cleanup prompt:
                \(activePrompt)
                """
            )
            sensitiveDebugLogger?(
                .cleanup,
                """
                Cleanup LLM input:
                \(correctedText)
                """
            )
            let cleanedText = try await localBackend.clean(text: correctedText, prompt: activePrompt)
            sensitiveDebugLogger?(
                .cleanup,
                """
                Cleanup LLM raw output:
                \(cleanedText)
                """
            )

            let sanitizedText = sanitizeCleanupOutput(cleanedText)

            if sanitizedText != cleanedText {
                debugLogger?(.cleanup, "Stripped model reasoning tags from cleanup output.")
                sensitiveDebugLogger?(
                    .cleanup,
                    """
                    Cleanup LLM sanitized output:
                    \(sanitizedText)
                    """
                )
            }

            let finalText = correctionEngine.applyPostCleanupCorrections(to: sanitizedText)
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
            return finalText
        } catch {
            debugLogger?(.cleanup, "Cleanup backend unavailable, returning deterministic corrections only.")
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
            return finalText
        }
    }

    private func sanitizeCleanupOutput(_ text: String) -> String {
        guard let expression = Self.thinkBlockExpression else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let range = NSRange(text.startIndex..., in: text)
        let sanitizedText = expression.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return sanitizedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
