import CoreGraphics
import Foundation

struct PostPasteLearningObservation: Equatable, Sendable {
    let text: String
}

final class PostPasteLearningCoordinator {
    typealias Scheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    typealias Revisit = @Sendable (PasteSession) async -> PostPasteLearningObservation?

    static let observationWindow: TimeInterval = 15
    static let pollInterval: TimeInterval = 1
    static let quiescencePeriod: TimeInterval = 2
    private static let maximumReplacementWordCount = 2
    private static let maximumPollCount = Int(observationWindow / pollInterval) + 1
    private static let requiredStablePollCount = Int(quiescencePeriod / pollInterval)

    var learningEnabled: Bool
    var onLearnedCorrection: ((MisheardReplacement) -> Void)?

    private let correctionStore: CorrectionStore
    private let scheduler: Scheduler
    private let revisit: Revisit

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    init(
        correctionStore: CorrectionStore,
        learningEnabled: Bool = true,
        scheduler: @escaping Scheduler = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        revisit: @escaping Revisit
    ) {
        self.correctionStore = correctionStore
        self.learningEnabled = learningEnabled
        self.scheduler = scheduler
        self.revisit = revisit
    }

    func handlePaste(_ session: PasteSession) {
        guard learningEnabled else {
            debugLogger?(.cleanup, "Post-paste learning skipped because it is disabled.")
            return
        }

        debugLogger?(.cleanup, "Scheduled post-paste learning polling session.")
        schedulePoll(
            for: session,
            progress: LearningProgress(
                baselineText: Self.normalizedText(session.focusedElementText),
                latestObservedText: nil,
                stablePollCount: 0,
                completedPollCount: 0
            ),
            delay: 0
        )
    }

    private func schedulePoll(for session: PasteSession, progress: LearningProgress, delay: TimeInterval) {
        scheduler(delay) {
            Task {
                await self.poll(session: session, progress: progress)
            }
        }
    }

    private func poll(session: PasteSession, progress: LearningProgress) async {
        guard learningEnabled else {
            debugLogger?(.cleanup, "Post-paste learning skipped because it is disabled.")
            return
        }

        var nextProgress = progress
        nextProgress.completedPollCount += 1

        if let observation = await revisit(session),
           let observedText = Self.normalizedText(observation.text) {
            if nextProgress.baselineText == nil {
                nextProgress.baselineText = observedText
                nextProgress.latestObservedText = observedText
                debugLogger?(.cleanup, "Post-paste learning captured initial text-field snapshot during polling.")
            } else if !Self.stringsMatch(observedText, nextProgress.latestObservedText ?? "") {
                nextProgress.latestObservedText = observedText
                nextProgress.stablePollCount = 0
                debugLogger?(.cleanup, "Post-paste learning observed text-field edits and is waiting for them to settle.")
            } else if nextProgress.latestObservedText != nil {
                nextProgress.stablePollCount += 1
                debugLogger?(
                    .cleanup,
                    "Post-paste learning observed \(nextProgress.stablePollCount)s of text-field quiescence."
                )
            }
        } else {
            debugLogger?(.cleanup, "Post-paste learning poll found no readable focused text field.")
        }

        if let baselineText = nextProgress.baselineText,
           let observedText = nextProgress.latestObservedText,
           nextProgress.stablePollCount >= Self.requiredStablePollCount {
            await learn(from: baselineText, to: observedText, pastedText: session.pastedText)
            return
        }

        if nextProgress.completedPollCount >= Self.maximumPollCount {
            debugLogger?(.cleanup, "Post-paste learning skipped because the polling window expired without a stable correction.")
            return
        }

        schedulePoll(for: session, progress: nextProgress, delay: Self.pollInterval)
    }

    private func learn(from baselineText: String, to observedText: String, pastedText: String) async {
        guard let replacement = Self.inferredReplacement(
            from: baselineText,
            to: observedText,
            constrainedTo: pastedText
        ) else {
            debugLogger?(.cleanup, "Post-paste learning skipped because no narrow correction could be inferred.")
            return
        }

        guard learningEnabled else {
            debugLogger?(.cleanup, "Post-paste learning skipped because it was disabled before storing.")
            return
        }

        await MainActor.run {
            guard self.learningEnabled else {
                self.debugLogger?(.cleanup, "Post-paste learning skipped because it was disabled before storing.")
                return
            }

            self.store(replacement)
        }
    }

    private func store(_ replacement: MisheardReplacement) {
        correctionStore.appendCommonlyMisheard(replacement)
        debugLogger?(.cleanup, "Post-paste learning learned replacement: \(replacement.wrong) -> \(replacement.right)")
        onLearnedCorrection?(replacement)
    }

    static func inferredReplacement(
        from original: String,
        to observed: String,
        constrainedTo pastedText: String
    ) -> MisheardReplacement? {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedObserved = observed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOriginal.isEmpty,
              !trimmedObserved.isEmpty,
              trimmedOriginal.caseInsensitiveCompare(trimmedObserved) != .orderedSame else {
            return nil
        }

        let originalWords = words(in: trimmedOriginal)
        let observedWords = words(in: trimmedObserved)
        let sharedPrefixCount = sharedPrefixLength(between: originalWords, and: observedWords)
        let sharedSuffixCount = sharedSuffixLength(
            between: originalWords,
            and: observedWords,
            excludingPrefix: sharedPrefixCount
        )

        guard sharedPrefixCount > 0 || sharedSuffixCount > 0 else {
            return nil
        }

        let originalEndIndex = originalWords.count - sharedSuffixCount
        let observedEndIndex = observedWords.count - sharedSuffixCount
        let wrong = originalWords[sharedPrefixCount..<originalEndIndex].joined(separator: " ")
        let right = observedWords[sharedPrefixCount..<observedEndIndex].joined(separator: " ")

        guard !wrong.isEmpty,
              !right.isEmpty,
              !stringsDifferOnlyByPunctuation(wrong, right),
              wordCount(in: wrong) <= maximumReplacementWordCount,
              wordCount(in: right) <= maximumReplacementWordCount,
              containsWordSequence(wrong, in: pastedText) else {
            return nil
        }

        return MisheardReplacement(wrong: wrong, right: right)
    }

    private static func sharedPrefixLength(between lhs: [String], and rhs: [String]) -> Int {
        let limit = min(lhs.count, rhs.count)
        var index = 0
        while index < limit && unchangedBoundaryWordsMatch(lhs[index], rhs[index]) {
            index += 1
        }
        return index
    }

    private static func sharedSuffixLength(
        between lhs: [String],
        and rhs: [String],
        excludingPrefix prefixLength: Int
    ) -> Int {
        let limit = min(lhs.count, rhs.count) - prefixLength
        guard limit > 0 else {
            return 0
        }

        var count = 0
        while count < limit &&
                unchangedBoundaryWordsMatch(lhs[lhs.count - count - 1], rhs[rhs.count - count - 1]) {
            count += 1
        }
        return count
    }

    private static func unchangedBoundaryWordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs
    }

    private static func stringsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func stringsDifferOnlyByPunctuation(_ lhs: String, _ rhs: String) -> Bool {
        normalizedComparisonText(lhs) == normalizedComparisonText(rhs)
    }

    private static func normalizedText(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }

        return text
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return " "
            }

            return " "
        }

        return String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static func wordCount(in text: String) -> Int {
        words(in: text).count
    }

    private static func containsWordSequence(_ needle: String, in haystack: String) -> Bool {
        let needleWords = words(in: needle)
        let haystackWords = words(in: haystack)
        guard !needleWords.isEmpty, needleWords.count <= haystackWords.count else {
            return false
        }

        let lastStartIndex = haystackWords.count - needleWords.count
        for startIndex in 0...lastStartIndex {
            let candidate = Array(haystackWords[startIndex..<(startIndex + needleWords.count)])
            if zip(candidate, needleWords).allSatisfy(stringsMatch) {
                return true
            }
        }

        return false
    }
}

private struct LearningProgress: Sendable {
    var baselineText: String?
    var latestObservedText: String?
    var stablePollCount: Int
    var completedPollCount: Int
}

enum PostPasteLearningObservationProvider {
    static func captureObservation(
        for session: PasteSession,
        locator: FocusedElementLocator = FocusedElementLocator()
    ) async -> PostPasteLearningObservation? {
        let currentBundleIdentifier = locator.frontmostApplicationBundleIdentifier()
        let currentWindow = locator.frontmostWindowReference()
        let currentFocusedFrame = locator.focusedElementFrame()

        guard isEligibleObservation(
                for: session,
                currentBundleIdentifier: currentBundleIdentifier,
                currentWindowReference: currentWindow,
                currentFocusedFrame: currentFocusedFrame
              ),
              let text = locator.focusedElementText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return PostPasteLearningObservation(text: text)
    }

    static func isEligibleObservation(
        for session: PasteSession,
        currentBundleIdentifier: String?,
        currentWindowReference: FrontmostWindowReference?,
        currentFocusedFrame: CGRect?
    ) -> Bool {
        _ = currentWindowReference
        _ = currentFocusedFrame
        return currentBundleIdentifier == session.frontmostAppBundleIdentifier
    }
}
