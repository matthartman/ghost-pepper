import Foundation

final class FluidAudioSpeechSession {
    private struct TaggedSpanGroup {
        let speakerID: String
        let span: DiarizationSummary.MergedSpan
    }

    struct FinalizationResult {
        let filteredTranscript: String?
        let summary: DiarizationSummary
    }

    private enum TargetSpeakerSelection {
        case selected(String)
        case noSpeakerReachedThreshold
        case ambiguousDominantSpeaker
    }

    private let sampleRate: Int
    private let substantialSpeakerThreshold: TimeInterval
    private let dominantSpeakerRatioThreshold: Double
    private let minimumKeptAudioDuration: TimeInterval
    private let mergeGapTolerance: TimeInterval
    private let transcribeFilteredAudio: @Sendable ([Float]) async -> String?
    private let stateQueue = DispatchQueue(label: "GhostPepper.FluidAudioSpeechSession")

    private var recordedAudio: [Float] = []

    init(
        sampleRate: Int = 16_000,
        substantialSpeakerThreshold: TimeInterval = 0.5,
        dominantSpeakerRatioThreshold: Double = 1.25,
        minimumKeptAudioDuration: TimeInterval = 0.75,
        mergeGapTolerance: TimeInterval = 0.05,
        transcribeFilteredAudio: @escaping @Sendable ([Float]) async -> String?
    ) {
        self.sampleRate = sampleRate
        self.substantialSpeakerThreshold = substantialSpeakerThreshold
        self.dominantSpeakerRatioThreshold = dominantSpeakerRatioThreshold
        self.minimumKeptAudioDuration = minimumKeptAudioDuration
        self.mergeGapTolerance = mergeGapTolerance
        self.transcribeFilteredAudio = transcribeFilteredAudio
    }

    func appendAudioChunk(_ samples: [Float]) {
        guard samples.isEmpty == false else {
            return
        }

        stateQueue.sync {
            recordedAudio.append(contentsOf: samples)
        }
    }

    func finalize(spans: [DiarizationSummary.Span]) async -> FinalizationResult {
        let sortedSpans = spans.sorted { lhs, rhs in
            if lhs.startTime == rhs.startTime {
                return lhs.endTime < rhs.endTime
            }
            return lhs.startTime < rhs.startTime
        }

        guard sortedSpans.isEmpty == false else {
            return FinalizationResult(
                filteredTranscript: nil,
                summary: DiarizationSummary(
                    spans: [],
                    mergedKeptSpans: [],
                    targetSpeakerID: nil,
                    targetSpeakerDuration: 0,
                    keptAudioDuration: 0,
                    usedFallback: true,
                    fallbackReason: .noUsableSpeakerSpans
                )
            )
        }

        let detectedSpeakerIDs = sortedSpans.reduce(into: [String]()) { speakerIDs, span in
            if speakerIDs.contains(span.speakerID) == false {
                speakerIDs.append(span.speakerID)
            }
        }
        if detectedSpeakerIDs.count == 1, let speakerID = detectedSpeakerIDs.first {
            let keptSpans = sortedSpans.map { span in
                DiarizationSummary.Span(
                    speakerID: span.speakerID,
                    startTime: span.startTime,
                    endTime: span.endTime,
                    isKept: true
                )
            }
            let targetSpeakerDuration = keptSpans.reduce(into: 0.0) { total, span in
                total += span.duration
            }
            let mergedKeptSpans = mergeKeptSpans(in: keptSpans)
            let keptAudioDuration = mergedKeptSpans.reduce(into: 0.0) { total, span in
                total += span.duration
            }

            return FinalizationResult(
                filteredTranscript: nil,
                summary: DiarizationSummary(
                    spans: keptSpans,
                    mergedKeptSpans: mergedKeptSpans,
                    targetSpeakerID: speakerID,
                    targetSpeakerDuration: targetSpeakerDuration,
                    keptAudioDuration: keptAudioDuration,
                    usedFallback: true,
                    fallbackReason: .singleDetectedSpeaker
                )
            )
        }

        switch selectTargetSpeaker(in: sortedSpans) {
        case .selected(let targetSpeakerID):
            let keptSpans = sortedSpans.map { span in
                DiarizationSummary.Span(
                    speakerID: span.speakerID,
                    startTime: span.startTime,
                    endTime: span.endTime,
                    isKept: span.speakerID == targetSpeakerID
                )
            }
            let targetSpeakerDuration = keptSpans
                .filter(\.isKept)
                .reduce(into: 0.0) { total, span in
                    total += span.duration
                }
            let mergedKeptSpans = mergeKeptSpans(in: keptSpans)
            let keptAudioDuration = mergedKeptSpans.reduce(into: 0.0) { total, span in
                total += span.duration
            }

            guard keptAudioDuration >= minimumKeptAudioDuration else {
                return FinalizationResult(
                    filteredTranscript: nil,
                    summary: DiarizationSummary(
                        spans: keptSpans,
                        mergedKeptSpans: mergedKeptSpans,
                        targetSpeakerID: targetSpeakerID,
                        targetSpeakerDuration: targetSpeakerDuration,
                        keptAudioDuration: keptAudioDuration,
                        usedFallback: true,
                        fallbackReason: .insufficientKeptAudio
                    )
                )
            }

            guard let filteredAudio = extractAudio(from: mergedKeptSpans) else {
                return FinalizationResult(
                    filteredTranscript: nil,
                    summary: DiarizationSummary(
                        spans: keptSpans,
                        mergedKeptSpans: mergedKeptSpans,
                        targetSpeakerID: targetSpeakerID,
                        targetSpeakerDuration: targetSpeakerDuration,
                        keptAudioDuration: keptAudioDuration,
                        usedFallback: true,
                        fallbackReason: .filteredAudioExtractionFailed
                    )
                )
            }

            let filteredTranscript = await transcribeFilteredAudio(filteredAudio)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let filteredTranscript, filteredTranscript.isEmpty == false else {
                return FinalizationResult(
                    filteredTranscript: nil,
                    summary: DiarizationSummary(
                        spans: keptSpans,
                        mergedKeptSpans: mergedKeptSpans,
                        targetSpeakerID: targetSpeakerID,
                        targetSpeakerDuration: targetSpeakerDuration,
                        keptAudioDuration: keptAudioDuration,
                        usedFallback: true,
                        fallbackReason: .emptyFilteredTranscription
                    )
                )
            }

            return FinalizationResult(
                filteredTranscript: filteredTranscript,
                summary: DiarizationSummary(
                    spans: keptSpans,
                    mergedKeptSpans: mergedKeptSpans,
                    targetSpeakerID: targetSpeakerID,
                    targetSpeakerDuration: targetSpeakerDuration,
                    keptAudioDuration: keptAudioDuration,
                    usedFallback: false,
                    fallbackReason: nil
                )
            )
        case .noSpeakerReachedThreshold:
            return FinalizationResult(
                filteredTranscript: nil,
                summary: DiarizationSummary(
                    spans: sortedSpans,
                    mergedKeptSpans: [],
                    targetSpeakerID: nil,
                    targetSpeakerDuration: 0,
                    keptAudioDuration: 0,
                    usedFallback: true,
                    fallbackReason: .noSpeakerReachedThreshold
                )
            )
        case .ambiguousDominantSpeaker:
            return FinalizationResult(
                filteredTranscript: nil,
                summary: DiarizationSummary(
                    spans: sortedSpans,
                    mergedKeptSpans: [],
                    targetSpeakerID: nil,
                    targetSpeakerDuration: 0,
                    keptAudioDuration: 0,
                    usedFallback: true,
                    fallbackReason: .ambiguousDominantSpeaker
                )
            )
        }
    }

    func speakerTaggedTranscript(spans: [DiarizationSummary.Span]) async -> SpeakerTaggedTranscript? {
        let taggedSpanGroups = mergeSpeakerSpans(in: spans)
        guard taggedSpanGroups.isEmpty == false else {
            return nil
        }

        var transcriptSegments: [SpeakerTaggedTranscript.Segment] = []
        transcriptSegments.reserveCapacity(taggedSpanGroups.count)

        for taggedSpanGroup in taggedSpanGroups {
            guard let audio = extractAudio(from: [taggedSpanGroup.span]),
                  let transcript = await transcribeFilteredAudio(audio)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  transcript.isEmpty == false else {
                continue
            }

            transcriptSegments.append(
                SpeakerTaggedTranscript.Segment(
                    speakerID: taggedSpanGroup.speakerID,
                    startTime: taggedSpanGroup.span.startTime,
                    endTime: taggedSpanGroup.span.endTime,
                    text: transcript
                )
            )
        }

        guard transcriptSegments.isEmpty == false else {
            return nil
        }

        return SpeakerTaggedTranscript(segments: transcriptSegments)
    }

    private func selectTargetSpeaker(in spans: [DiarizationSummary.Span]) -> TargetSpeakerSelection {
        var durationsBySpeaker: [String: TimeInterval] = [:]
        var firstStartBySpeaker: [String: TimeInterval] = [:]

        for span in spans {
            durationsBySpeaker[span.speakerID, default: 0] += span.duration
            firstStartBySpeaker[span.speakerID] = min(
                firstStartBySpeaker[span.speakerID] ?? span.startTime,
                span.startTime
            )
        }

        let rankedSpeakers = durationsBySpeaker.map { speakerID, duration in
            (
                speakerID: speakerID,
                duration: duration,
                firstStartTime: firstStartBySpeaker[speakerID] ?? .greatestFiniteMagnitude
            )
        }
        .sorted { lhs, rhs in
            if lhs.duration == rhs.duration {
                return lhs.firstStartTime < rhs.firstStartTime
            }

            return lhs.duration > rhs.duration
        }

        guard let targetSpeaker = rankedSpeakers.first,
              targetSpeaker.duration >= substantialSpeakerThreshold else {
            return .noSpeakerReachedThreshold
        }

        if let runnerUpSpeaker = rankedSpeakers.dropFirst().first,
           targetSpeaker.duration < runnerUpSpeaker.duration * dominantSpeakerRatioThreshold {
            return .ambiguousDominantSpeaker
        }

        return .selected(targetSpeaker.speakerID)
    }

    private func mergeSpeakerSpans(in spans: [DiarizationSummary.Span]) -> [TaggedSpanGroup] {
        guard spans.isEmpty == false else {
            return []
        }

        var mergedSpanGroups: [TaggedSpanGroup] = []

        for span in spans {
            guard span.duration > 0 else {
                continue
            }

            if let lastSpanGroup = mergedSpanGroups.last,
               lastSpanGroup.speakerID == span.speakerID,
               span.startTime - lastSpanGroup.span.endTime <= mergeGapTolerance {
                mergedSpanGroups[mergedSpanGroups.count - 1] = TaggedSpanGroup(
                    speakerID: lastSpanGroup.speakerID,
                    span: DiarizationSummary.MergedSpan(
                        startTime: lastSpanGroup.span.startTime,
                        endTime: max(lastSpanGroup.span.endTime, span.endTime)
                    )
                )
            } else {
                mergedSpanGroups.append(
                    TaggedSpanGroup(
                        speakerID: span.speakerID,
                        span: DiarizationSummary.MergedSpan(
                            startTime: span.startTime,
                            endTime: span.endTime
                        )
                    )
                )
            }
        }

        return mergedSpanGroups
    }

    private func mergeKeptSpans(in spans: [DiarizationSummary.Span]) -> [DiarizationSummary.MergedSpan] {
        let keptSpans = spans.filter(\.isKept)
        guard keptSpans.isEmpty == false else {
            return []
        }

        var mergedSpans: [DiarizationSummary.MergedSpan] = []

        for span in keptSpans {
            guard span.duration > 0 else {
                continue
            }

            if let lastSpan = mergedSpans.last,
               span.startTime - lastSpan.endTime <= mergeGapTolerance {
                mergedSpans[mergedSpans.count - 1] = DiarizationSummary.MergedSpan(
                    startTime: lastSpan.startTime,
                    endTime: max(lastSpan.endTime, span.endTime)
                )
            } else {
                mergedSpans.append(
                    DiarizationSummary.MergedSpan(
                        startTime: span.startTime,
                        endTime: span.endTime
                    )
                )
            }
        }

        return mergedSpans
    }

    private func extractAudio(from spans: [DiarizationSummary.MergedSpan]) -> [Float]? {
        let audio = stateQueue.sync {
            recordedAudio
        }

        guard audio.isEmpty == false else {
            return nil
        }

        var filteredAudio: [Float] = []

        for span in spans {
            let startIndex = max(0, Int(floor(span.startTime * Double(sampleRate))))
            let endIndex = min(audio.count, Int(ceil(span.endTime * Double(sampleRate))))
            guard endIndex > startIndex else {
                continue
            }

            filteredAudio.append(contentsOf: audio[startIndex..<endIndex])
        }

        return filteredAudio.isEmpty ? nil : filteredAudio
    }
}
