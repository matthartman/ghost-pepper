import Foundation

final class FluidAudioSpeechSession {
    struct FinalizationResult {
        let filteredTranscript: String?
        let summary: DiarizationSummary
    }

    private let sampleRate: Int
    private let substantialSpeakerThreshold: TimeInterval
    private let minimumKeptAudioDuration: TimeInterval
    private let mergeGapTolerance: TimeInterval
    private let transcribeFilteredAudio: @Sendable ([Float]) async -> String?
    private let stateQueue = DispatchQueue(label: "GhostPepper.FluidAudioSpeechSession")

    private var recordedAudio: [Float] = []

    init(
        sampleRate: Int = 16_000,
        substantialSpeakerThreshold: TimeInterval = 0.5,
        minimumKeptAudioDuration: TimeInterval = 0.75,
        mergeGapTolerance: TimeInterval = 0.05,
        transcribeFilteredAudio: @escaping @Sendable ([Float]) async -> String?
    ) {
        self.sampleRate = sampleRate
        self.substantialSpeakerThreshold = substantialSpeakerThreshold
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
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }

            if lhs.endTime != rhs.endTime {
                return lhs.endTime < rhs.endTime
            }

            return lhs.speakerID < rhs.speakerID
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

        guard let targetSpeakerID = selectTargetSpeakerID(from: sortedSpans) else {
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
        }

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
    }

    private func selectTargetSpeakerID(from spans: [DiarizationSummary.Span]) -> String? {
        var durationsBySpeaker: [String: TimeInterval] = [:]

        for span in spans {
            durationsBySpeaker[span.speakerID, default: 0] += span.duration
        }

        for span in spans {
            if let duration = durationsBySpeaker[span.speakerID], duration >= substantialSpeakerThreshold {
                return span.speakerID
            }
        }

        return nil
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
