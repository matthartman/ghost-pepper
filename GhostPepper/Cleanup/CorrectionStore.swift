import Combine
import Foundation

struct MisheardReplacement: Codable, Equatable, Hashable, Sendable {
    let wrong: String
    let right: String

    init(wrong: String, right: String) {
        self.wrong = wrong.trimmingCharacters(in: .whitespacesAndNewlines)
        self.right = right.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final class CorrectionStore: ObservableObject {
    @Published private(set) var preferredTranscriptions: [String]
    @Published private(set) var commonlyMisheard: [MisheardReplacement]
    @Published private(set) var preferredTranscriptionsDraft: String
    @Published private(set) var commonlyMisheardDraft: String

    var preferredOCRCustomWords: [String] {
        preferredTranscriptions
    }

    var preferredTranscriptionsText: String {
        get { preferredTranscriptionsDraft }
        set { updatePreferredTranscriptions(from: newValue) }
    }

    var commonlyMisheardText: String {
        get { commonlyMisheardDraft }
        set { updateCommonlyMisheard(from: newValue) }
    }

    private static let preferredTranscriptionsDefaultsKey = "preferredTranscriptionsDraft"
    private static let commonlyMisheardDefaultsKey = "commonlyMisheardDraft"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let preferredDraft = defaults.string(forKey: Self.preferredTranscriptionsDefaultsKey) ?? ""
        let commonlyMisheardDraft = defaults.string(forKey: Self.commonlyMisheardDefaultsKey) ?? ""

        self.defaults = defaults
        self.preferredTranscriptionsDraft = preferredDraft
        self.commonlyMisheardDraft = commonlyMisheardDraft
        self.preferredTranscriptions = Self.parsePreferredTranscriptions(from: preferredDraft)
        self.commonlyMisheard = Self.parseCommonlyMisheard(from: commonlyMisheardDraft)
    }

    func updatePreferredTranscriptions(from text: String) {
        preferredTranscriptionsDraft = text
        preferredTranscriptions = Self.parsePreferredTranscriptions(from: text)
        persistPreferredTranscriptions()
    }

    func updateCommonlyMisheard(from text: String) {
        commonlyMisheardDraft = text
        commonlyMisheard = Self.parseCommonlyMisheard(from: text)
        persistCommonlyMisheard()
    }

    func appendCommonlyMisheard(_ replacement: MisheardReplacement) {
        guard !replacement.wrong.isEmpty,
              !replacement.right.isEmpty,
              !commonlyMisheard.contains(replacement) else {
            return
        }

        let line = "\(replacement.wrong) -> \(replacement.right)"
        let separator = commonlyMisheardDraft.isEmpty || commonlyMisheardDraft.hasSuffix("\n") ? "" : "\n"
        updateCommonlyMisheard(from: commonlyMisheardDraft + separator + line)
    }

    private func persistPreferredTranscriptions() {
        defaults.set(preferredTranscriptionsDraft, forKey: Self.preferredTranscriptionsDefaultsKey)
    }

    private func persistCommonlyMisheard() {
        defaults.set(commonlyMisheardDraft, forKey: Self.commonlyMisheardDefaultsKey)
    }

    private static func parsePreferredTranscriptions(from text: String) -> [String] {
        uniqueValues(
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func parseCommonlyMisheard(from text: String) -> [MisheardReplacement] {
        let replacements = text
            .components(separatedBy: .newlines)
            .compactMap { line -> MisheardReplacement? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    return nil
                }

                let parts = trimmedLine.components(separatedBy: "->")
                guard parts.count == 2 else {
                    return nil
                }

                let replacement = MisheardReplacement(
                    wrong: parts[0],
                    right: parts[1]
                )
                guard !replacement.wrong.isEmpty, !replacement.right.isEmpty else {
                    return nil
                }

                return replacement
            }

        return uniqueValues(replacements)
    }

    private static func uniqueValues<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
