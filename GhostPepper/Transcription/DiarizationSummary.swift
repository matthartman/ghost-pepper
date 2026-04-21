import Foundation

struct DiarizationSummary: Equatable, Codable, Sendable {
    struct Span: Equatable, Codable, Sendable {
        let speakerID: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let isKept: Bool

        init(
            speakerID: String,
            startTime: TimeInterval,
            endTime: TimeInterval,
            isKept: Bool = false
        ) {
            self.speakerID = speakerID
            self.startTime = startTime
            self.endTime = endTime
            self.isKept = isKept
        }

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }
    }

    struct MergedSpan: Equatable, Codable, Sendable {
        let startTime: TimeInterval
        let endTime: TimeInterval

        init(startTime: TimeInterval, endTime: TimeInterval) {
            self.startTime = startTime
            self.endTime = endTime
        }

        var duration: TimeInterval {
            max(0, endTime - startTime)
        }
    }

    enum FallbackReason: String, Equatable, Codable, Sendable {
        case noUsableSpeakerSpans
        case noSpeakerReachedThreshold
        case ambiguousDominantSpeaker
        case singleDetectedSpeaker
        case insufficientKeptAudio
        case filteredAudioExtractionFailed
        case emptyFilteredTranscription
    }

    let spans: [Span]
    let mergedKeptSpans: [MergedSpan]
    let targetSpeakerID: String?
    let targetSpeakerDuration: TimeInterval
    let keptAudioDuration: TimeInterval
    let usedFallback: Bool
    let fallbackReason: FallbackReason?

    init(
        spans: [Span],
        mergedKeptSpans: [MergedSpan],
        targetSpeakerID: String?,
        targetSpeakerDuration: TimeInterval,
        keptAudioDuration: TimeInterval,
        usedFallback: Bool,
        fallbackReason: FallbackReason?
    ) {
        self.spans = spans
        self.mergedKeptSpans = mergedKeptSpans
        self.targetSpeakerID = targetSpeakerID
        self.targetSpeakerDuration = targetSpeakerDuration
        self.keptAudioDuration = keptAudioDuration
        self.usedFallback = usedFallback
        self.fallbackReason = fallbackReason
    }
}
