import Foundation

struct TextCleanerPerformance {
    let modelCallDuration: TimeInterval?
    let postProcessDuration: TimeInterval?
}

struct TextCleanerTranscript: Equatable {
    let prompt: String
    let inputText: String
    let rawOutput: String
}

struct TextCleanerResult {
    let text: String
    let performance: TextCleanerPerformance
    let transcript: TextCleanerTranscript?
    let usedFallback: Bool

    init(
        text: String,
        performance: TextCleanerPerformance,
        transcript: TextCleanerTranscript? = nil,
        usedFallback: Bool = false
    ) {
        self.text = text
        self.performance = performance
        self.transcript = transcript
        self.usedFallback = usedFallback
    }
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
    <TASK>
    Your job is to clean up transcribed audio.
    The audio transcription engine can make mistakes and will sometimes transcribe things in a way that is not how they should be written in text.
    Repeat back EVERYTHING the user says.
    </TASK>

    <RULES>
    <RULE id="1">Delete filler words like: um, uh, like, you know, basically, literally, sort of, kind of</RULE>
    <RULE id="2">ONLY if the user says the EXACT phrases "scratch that" or "never mind" or "no let me start over", then delete what they are correcting. Otherwise keep the wording and meaning the same, but correct obvious recognition misses for names, models, commands, files, and jargon when supporting context clearly shows the intended term.</RULE>
    <RULE id="3">Use the context from the OCR window and other information you are provided about commonly mistranscribed words to inform your transcription.</RULE>
    <RULE id="4">Fix obvious grammatical errors, but do not fix turns of phrase just because they do not sound right to you.</RULE>
    <RULE id="5">Clean up punctuation. Sentences should be properly punctuated.</RULE>
    <RULE id="6">The output should appear to be competently and professionally written by a human, as they would normally type it.</RULE>
    </RULES>

    <CRITICAL_RULES>
    Do NOT delete sentences.
    Do NOT remove context.
    Do NOT summarize.
    If you are unsure whether to keep or delete something, KEEP IT.
    Do not keep an obvious misrecognition just because it was spoken that way.
    </CRITICAL_RULES>

    <EXAMPLES>
    <EXAMPLE>
    <INPUT>So um like the meeting is at 3pm you know on Tuesday</INPUT>
    <OUTPUT>So the meeting is at 3pm on Tuesday</OUTPUT>
    </EXAMPLE>

    <EXAMPLE>
    <INPUT>Okay so now I'm recording and it becomes a red recording thing. Do you think we could change the icon?</INPUT>
    <OUTPUT>Okay so now I'm recording and it becomes a red recording thing. Do you think we could change the icon?</OUTPUT>
    </EXAMPLE>

    <EXAMPLE>
    <INPUT>Hey Becca I have an email. Scratch that, this email is for Pete. Hey Pete, this is my email.</INPUT>
    <OUTPUT>Hey Pete, this is my email.</OUTPUT>
    </EXAMPLE>

    <EXAMPLE>
    <INPUT>What is a synonym for whisper?</INPUT>
    <OUTPUT>What is a synonym for whisper?</OUTPUT>
    </EXAMPLE>

    <EXAMPLE>
    <INPUT>It is four twenty five pm</INPUT>
    <OUTPUT>It is 4:25PM</OUTPUT>
    </EXAMPLE>

    <EXAMPLE>
    <INPUT>I've been working on this and I'm stuck. Any ideas?</INPUT>
    <OUTPUT>I've been working on this and I'm stuck. Any ideas?</OUTPUT>
    </EXAMPLE>
    </EXAMPLES>
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
    func cleanWithPerformance(
        text: String,
        prompt: String? = nil,
        modelKind: LocalCleanupModelKind? = nil
    ) async -> TextCleanerResult {
        let activePrompt = prompt ?? Self.defaultPrompt
        let correctionEngine = DeterministicCorrectionEngine(
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard
        )
        let correctedText = correctionEngine.applyPreCleanupCorrections(to: text)
        let formattedInput = Self.formatCleanupInput(userInput: correctedText)
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

        let modelCallStart = Date()
        do {
            let cleanedText = try await localBackend.clean(
                text: formattedInput,
                prompt: activePrompt,
                modelKind: modelKind
            )
            let modelCallDuration = Date().timeIntervalSince(modelCallStart)
            let postProcessStart = Date()
            let sanitizedText = Self.sanitizeCleanupOutput(cleanedText)

            if sanitizedText != cleanedText {
                debugLogger?(.cleanup, "Stripped model reasoning tags from cleanup output.")
            }

            let finalText = correctionEngine.applyPostCleanupCorrections(to: sanitizedText)
            logCleanupTranscript(
                prompt: activePrompt,
                input: formattedInput,
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
                ),
                transcript: TextCleanerTranscript(
                    prompt: activePrompt,
                    inputText: formattedInput,
                    rawOutput: cleanedText
                ),
                usedFallback: false
            )
        } catch let error as CleanupBackendError {
            let postProcessStart = Date()
            let finalText = correctionEngine.applyPostCleanupCorrections(to: correctedText)
            let postProcessDuration = Date().timeIntervalSince(postProcessStart)

            switch error {
            case .unavailable:
                debugLogger?(.cleanup, "Cleanup backend unavailable, returning deterministic corrections only.")
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
                        postProcessDuration: postProcessDuration
                    ),
                    usedFallback: true
                )
            case .unusableOutput(let rawOutput):
                let modelCallDuration = Date().timeIntervalSince(modelCallStart)
                let sanitizedOutput = Self.sanitizeCleanupOutput(rawOutput)
                debugLogger?(.cleanup, "Cleanup model returned unusable output, falling back to deterministic corrections.")
                logCleanupTranscript(
                    prompt: activePrompt,
                    input: formattedInput,
                    rawOutput: rawOutput,
                    sanitizedOutput: sanitizedOutput,
                    finalOutput: finalText
                )
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
                        modelCallDuration: modelCallDuration,
                        postProcessDuration: postProcessDuration
                    ),
                    transcript: TextCleanerTranscript(
                        prompt: activePrompt,
                        inputText: formattedInput,
                        rawOutput: rawOutput
                    ),
                    usedFallback: true
                )
            }
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
                ),
                usedFallback: true
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

    static func formatCleanupInput(userInput: String) -> String {
        """
        <USER-INPUT>
        \(userInput)
        </USER-INPUT>
        """
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
