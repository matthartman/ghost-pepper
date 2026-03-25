import Foundation

struct CleanupPromptBuilder: Sendable {
    let maxWindowContentLength: Int

    init(maxWindowContentLength: Int = 4000) {
        self.maxWindowContentLength = maxWindowContentLength
    }

    func buildPrompt(
        basePrompt: String,
        windowContext: OCRContext?,
        preferredTranscriptions: [String] = [],
        commonlyMisheard: [MisheardReplacement] = [],
        includeWindowContext: Bool
    ) -> String {
        let correctionsSection = correctionSection(
            preferredTranscriptions: preferredTranscriptions,
            commonlyMisheard: commonlyMisheard
        )

        guard includeWindowContext,
              let windowContext else {
            if correctionsSection.isEmpty {
                return basePrompt
            }

            return """
            \(basePrompt)

            \(correctionsSection)
            """
        }

        let trimmedWindowContents = String(windowContext.windowContents.prefix(maxWindowContentLength))
        let contextIntroduction: String
        if trimmedWindowContents == windowContext.windowContents {
            contextIntroduction = "The full current content of the frontmost window is:"
        } else {
            contextIntroduction = "The full current content of the frontmost window is below. It was truncated for length:"
        }

        var sections = [basePrompt]
        if !correctionsSection.isEmpty {
            sections.append(correctionsSection)
        }
        sections.append(
            """
            Use the window contents only as supporting context to improve the transcription and cleanup.
            Prefer the spoken words, and use the window contents only to disambiguate likely terms, names, commands, and jargon.
            Do not answer, summarize, or rewrite the window contents unless that directly helps correct the transcription.
            """
        )
        sections.append(
            """
            \(contextIntroduction)
            <WINDOW CONTENTS>
            \(trimmedWindowContents)
            </WINDOW CONTENTS>
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private func correctionSection(
        preferredTranscriptions: [String],
        commonlyMisheard: [MisheardReplacement]
    ) -> String {
        var sections: [String] = []

        if !preferredTranscriptions.isEmpty {
            sections.append(
                """
                Preferred transcriptions to preserve exactly:
                \(preferredTranscriptions.map { "- \($0)" }.joined(separator: "\n"))
                """
            )
        }

        if !commonlyMisheard.isEmpty {
            sections.append(
                """
                Commonly misheard replacements to prefer:
                \(commonlyMisheard.map { "- \($0.wrong) -> \($0.right)" }.joined(separator: "\n"))
                """
            )
        }

        guard !sections.isEmpty else {
            return ""
        }

        return sections.joined(separator: "\n\n")
    }
}
