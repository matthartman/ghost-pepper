import Foundation

struct DeterministicCorrectionEngine: Sendable {
    let preferredTranscriptions: [String]
    let commonlyMisheard: [MisheardReplacement]

    func applyPreCleanupCorrections(to text: String) -> String {
        let protectedText = protectPreferredTranscriptions(in: text)
        var correctedText = protectedText.text

        for replacement in sortedMisheardReplacements {
            correctedText = replacingPhrase(
                replacement.wrong,
                in: correctedText,
                with: replacement.right
            )
        }

        return restorePreferredTranscriptions(in: correctedText, replacements: protectedText.replacements)
    }

    func applyPostCleanupCorrections(to text: String) -> String {
        text
    }

    private var sortedPreferredTranscriptions: [String] {
        preferredTranscriptions.sorted { $0.count > $1.count }
    }

    private var sortedMisheardReplacements: [MisheardReplacement] {
        commonlyMisheard.sorted { $0.wrong.count > $1.wrong.count }
    }

    private func protectPreferredTranscriptions(in text: String) -> ProtectedText {
        var protectedText = text
        var replacements: [String: String] = [:]

        for preferredTranscription in sortedPreferredTranscriptions {
            guard let expression = phraseExpression(for: preferredTranscription) else {
                continue
            }

            var searchRange = NSRange(protectedText.startIndex..<protectedText.endIndex, in: protectedText)

            while let match = expression.firstMatch(in: protectedText, options: [], range: searchRange),
                  let range = Range(match.range, in: protectedText) {
                let token = "@@__GHOSTPEPPER_PREFERRED_\(replacements.count)__@@"
                protectedText.replaceSubrange(range, with: token)
                replacements[token] = preferredTranscription

                guard let tokenRange = protectedText.range(of: token) else {
                    break
                }

                searchRange = NSRange(tokenRange.upperBound..<protectedText.endIndex, in: protectedText)
            }
        }

        return ProtectedText(text: protectedText, replacements: replacements)
    }

    private func restorePreferredTranscriptions(in text: String, replacements: [String: String]) -> String {
        replacements.reduce(text) { partialResult, replacement in
            partialResult.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
    }

    private func replacingPhrase(_ phrase: String, in text: String, with replacement: String) -> String {
        guard let expression = phraseExpression(for: phrase) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }

    private func phraseExpression(for phrase: String) -> NSRegularExpression? {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhrase.isEmpty else {
            return nil
        }

        let escapedPhrase = NSRegularExpression.escapedPattern(for: trimmedPhrase)
        let startsWithWordCharacter = trimmedPhrase.unicodeScalars.first.map(CharacterSet.alphanumerics.contains) ?? false
        let endsWithWordCharacter = trimmedPhrase.unicodeScalars.last.map(CharacterSet.alphanumerics.contains) ?? false
        let prefix = startsWithWordCharacter ? "(?<![\\p{L}\\p{N}])" : ""
        let suffix = endsWithWordCharacter ? "(?![\\p{L}\\p{N}])" : ""

        return try? NSRegularExpression(
            pattern: prefix + escapedPhrase + suffix,
            options: [.caseInsensitive]
        )
    }

}

private struct ProtectedText {
    let text: String
    let replacements: [String: String]
}
