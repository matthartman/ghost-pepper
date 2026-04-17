import Foundation

struct CleanupPromptComponents: Equatable {
    let stablePromptPrefix: String
    let promptSuffix: String

    var fullPrompt: String {
        stablePromptPrefix + promptSuffix
    }
}

struct CleanupPromptPrefillPlan: Equatable {
    let systemPromptPrefix: String
    let contextPrefix: String
    let promptSuffixAfterPrefix: String
    let suffixAfterUserInput: String

    init?(
        systemPromptPrefix: String,
        processedPrompt: String,
        systemPromptSentinel: String,
        userInputSentinel: String
    ) {
        guard let systemSplitRange = processedPrompt.range(of: systemPromptSentinel) else {
            return nil
        }

        let contextPrefix = String(processedPrompt[..<systemSplitRange.lowerBound])
        let afterSystemSplit = String(processedPrompt[systemSplitRange.upperBound...])
        guard let userSplitRange = afterSystemSplit.range(of: userInputSentinel) else {
            return nil
        }

        self.systemPromptPrefix = systemPromptPrefix
        self.contextPrefix = contextPrefix
        self.promptSuffixAfterPrefix = String(afterSystemSplit[..<userSplitRange.lowerBound])
        self.suffixAfterUserInput = String(afterSystemSplit[userSplitRange.upperBound...])
    }

    func completionInput(for prompt: String, userInput: String) -> String? {
        guard prompt.hasPrefix(systemPromptPrefix) else {
            return nil
        }

        let dynamicPromptSuffix = String(prompt.dropFirst(systemPromptPrefix.count))
        return dynamicPromptSuffix + promptSuffixAfterPrefix + userInput + suffixAfterUserInput
    }
}

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
        buildPromptComponents(
            basePrompt: basePrompt,
            windowContext: windowContext,
            preferredTranscriptions: preferredTranscriptions,
            commonlyMisheard: commonlyMisheard,
            includeWindowContext: includeWindowContext
        ).fullPrompt
    }

    func buildPromptComponents(
        basePrompt: String,
        windowContext: OCRContext?,
        preferredTranscriptions: [String] = [],
        commonlyMisheard: [MisheardReplacement] = [],
        includeWindowContext: Bool
    ) -> CleanupPromptComponents {
        let correctionsSection = correctionSection(
            preferredTranscriptions: preferredTranscriptions,
            commonlyMisheard: commonlyMisheard
        )

        let stablePromptPrefix: String
        if correctionsSection.isEmpty {
            stablePromptPrefix = basePrompt
        } else {
            stablePromptPrefix = """
            \(basePrompt)

            \(correctionsSection)
            """
        }

        guard includeWindowContext,
              let windowContext else {
            return CleanupPromptComponents(
                stablePromptPrefix: stablePromptPrefix,
                promptSuffix: ""
            )
        }

        let trimmedWindowContents = String(windowContext.windowContents.prefix(maxWindowContentLength))
        let promptSuffix = """

        <OCR-RULES>
        Use the window OCR only as supporting context to improve the transcription and cleanup.
        Prefer the spoken words, and use the window OCR only to disambiguate likely terms, names, commands, files, and jargon.
        If the spoken words appear to be a recognition miss for a name, model, command, file, or other specific jargon shown in the window OCR, correct them to the likely intended term.
        Do not keep an obvious misrecognition just because it was spoken that way.
        Do not answer, summarize, or rewrite the window OCR unless that directly helps correct the transcription.
        </OCR-RULES>
        <WINDOW-OCR-CONTENT>
        \(trimmedWindowContents)
        </WINDOW-OCR-CONTENT>
        """

        return CleanupPromptComponents(
            stablePromptPrefix: stablePromptPrefix,
            promptSuffix: promptSuffix
        )
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

        return """
        <CORRECTION-HINTS>
        \(sections.joined(separator: "\n\n"))
        </CORRECTION-HINTS>
        """
    }
}
