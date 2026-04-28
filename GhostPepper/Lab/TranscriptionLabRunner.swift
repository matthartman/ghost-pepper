import Foundation

struct SpeakerTaggedTranscript: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let speakerID: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }

    let segments: [Segment]
}

struct SpeakerTaggedTranscriptionResult: Equatable, Sendable {
    let filteredTranscript: String?
    let diarizationSummary: DiarizationSummary
    let speakerTaggedTranscript: SpeakerTaggedTranscript?
}

struct TranscriptionLabTranscriptionResult: Equatable, Sendable {
    let rawTranscription: String
    let diarizationSummary: DiarizationSummary?
    let speakerTaggedTranscript: SpeakerTaggedTranscript?
    let speakerProfiles: [TranscriptionLabSpeakerProfile]

    init(
        rawTranscription: String,
        diarizationSummary: DiarizationSummary? = nil,
        speakerTaggedTranscript: SpeakerTaggedTranscript? = nil,
        speakerProfiles: [TranscriptionLabSpeakerProfile] = []
    ) {
        self.rawTranscription = rawTranscription
        self.diarizationSummary = diarizationSummary
        self.speakerTaggedTranscript = speakerTaggedTranscript
        self.speakerProfiles = speakerProfiles
    }
}

enum TranscriptionLabRunnerError: Error, Equatable {
    case pipelineBusy
    case missingAudio
    case transcriptionFailed
}

struct TranscriptionLabCleanupResult: Equatable {
    let correctedTranscription: String
    let cleanupUsedFallback: Bool
    let transcript: TranscriptionLabCleanupTranscript?

    init(
        correctedTranscription: String,
        cleanupUsedFallback: Bool,
        transcript: TranscriptionLabCleanupTranscript? = nil
    ) {
        self.correctedTranscription = correctedTranscription
        self.cleanupUsedFallback = cleanupUsedFallback
        self.transcript = transcript
    }
}

struct TranscriptionLabCleanupTranscript: Equatable {
    let prompt: String
    let inputText: String
    let rawModelOutput: String?
}

@MainActor
final class TranscriptionLabRunner {
    typealias AudioLoader = (TranscriptionLabEntry) throws -> [Float]
    typealias SpeechModelLoader = (String) async -> Void
    typealias Transcriber = ([Float]) async -> String?
    typealias SpeakerTaggingRunner = ([Float]) async -> SpeakerTaggedTranscriptionResult?
    typealias SpeakerProfileResolver = (
        _ entryID: UUID,
        _ audioBuffer: [Float],
        _ diarizationSummary: DiarizationSummary,
        _ speakerTaggedTranscript: SpeakerTaggedTranscript?
    ) async -> [TranscriptionLabSpeakerProfile]
    typealias Cleaner = (String, String, LocalCleanupModelKind) async -> TextCleanerResult

    private let loadAudioBuffer: AudioLoader
    private let loadSpeechModel: SpeechModelLoader
    private let transcribe: Transcriber
    private let runSpeakerTagging: SpeakerTaggingRunner
    private let resolveSpeakerProfiles: SpeakerProfileResolver
    private let clean: Cleaner
    private let correctionStore: CorrectionStore
    private let cleanupPromptBuilder: CleanupPromptBuilder

    init(
        loadAudioBuffer: @escaping AudioLoader,
        loadSpeechModel: @escaping SpeechModelLoader,
        transcribe: @escaping Transcriber,
        runSpeakerTagging: @escaping SpeakerTaggingRunner = { _ in nil },
        resolveSpeakerProfiles: @escaping SpeakerProfileResolver = { _, _, _, _ in [] },
        clean: @escaping Cleaner,
        correctionStore: CorrectionStore,
        cleanupPromptBuilder: CleanupPromptBuilder = CleanupPromptBuilder()
    ) {
        self.loadAudioBuffer = loadAudioBuffer
        self.loadSpeechModel = loadSpeechModel
        self.transcribe = transcribe
        self.runSpeakerTagging = runSpeakerTagging
        self.resolveSpeakerProfiles = resolveSpeakerProfiles
        self.clean = clean
        self.correctionStore = correctionStore
        self.cleanupPromptBuilder = cleanupPromptBuilder
    }

    func rerunTranscription(
        entry: TranscriptionLabEntry,
        speechModelID: String,
        speakerTaggingEnabled: Bool,
        acquirePipeline: () -> Bool,
        releasePipeline: () -> Void
    ) async throws -> TranscriptionLabTranscriptionResult {
        guard acquirePipeline() else {
            throw TranscriptionLabRunnerError.pipelineBusy
        }
        defer { releasePipeline() }

        let audioBuffer = try loadAudioBuffer(entry)
        guard !audioBuffer.isEmpty else {
            throw TranscriptionLabRunnerError.missingAudio
        }

        await loadSpeechModel(speechModelID)

        if speakerTaggingEnabled,
           let speakerTaggedResult = await runSpeakerTagging(audioBuffer) {
            if let filteredTranscript = speakerTaggedResult.filteredTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               filteredTranscript.isEmpty == false {
                let speakerProfiles = await resolveSpeakerProfiles(
                    entry.id,
                    audioBuffer,
                    speakerTaggedResult.diarizationSummary,
                    speakerTaggedResult.speakerTaggedTranscript
                )
                let rawTranscription = transcriptMatchingTargetSpeakerIdentity(
                    filteredTranscript: filteredTranscript,
                    diarizationSummary: speakerTaggedResult.diarizationSummary,
                    speakerTaggedTranscript: speakerTaggedResult.speakerTaggedTranscript,
                    speakerProfiles: speakerProfiles
                )
                return TranscriptionLabTranscriptionResult(
                    rawTranscription: rawTranscription,
                    diarizationSummary: speakerTaggedResult.diarizationSummary,
                    speakerTaggedTranscript: speakerTaggedResult.speakerTaggedTranscript,
                    speakerProfiles: speakerProfiles
                )
            }

            guard let rawTranscription = await transcribe(audioBuffer)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  rawTranscription.isEmpty == false else {
                throw TranscriptionLabRunnerError.transcriptionFailed
            }

            let speakerTaggedTranscript = repairedSpeakerTaggedTranscript(
                from: speakerTaggedResult,
                fallbackRawTranscription: rawTranscription
            )
            let speakerProfiles = await resolveSpeakerProfiles(
                entry.id,
                audioBuffer,
                speakerTaggedResult.diarizationSummary,
                speakerTaggedTranscript
            )

            return TranscriptionLabTranscriptionResult(
                rawTranscription: rawTranscription,
                diarizationSummary: speakerTaggedResult.diarizationSummary,
                speakerTaggedTranscript: speakerTaggedTranscript,
                speakerProfiles: speakerProfiles
            )
        }

        guard let rawTranscription = await transcribe(audioBuffer)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              rawTranscription.isEmpty == false else {
            throw TranscriptionLabRunnerError.transcriptionFailed
        }

        return TranscriptionLabTranscriptionResult(rawTranscription: rawTranscription)
    }

    private func transcriptMatchingTargetSpeakerIdentity(
        filteredTranscript: String,
        diarizationSummary: DiarizationSummary,
        speakerTaggedTranscript: SpeakerTaggedTranscript?,
        speakerProfiles: [TranscriptionLabSpeakerProfile]
    ) -> String {
        guard let targetSpeakerID = diarizationSummary.targetSpeakerID,
              let speakerTaggedTranscript else {
            return filteredTranscript
        }

        let matchingSpeakerIDs = speakerIDsMatchingTargetIdentity(
            targetSpeakerID: targetSpeakerID,
            speakerProfiles: speakerProfiles
        )
        guard matchingSpeakerIDs.count > 1 else {
            return filteredTranscript
        }

        let matchedTranscript = speakerTaggedTranscript.segments
            .filter { matchingSpeakerIDs.contains($0.speakerID) }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }

                return lhs.startTime < rhs.startTime
            }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return matchedTranscript.isEmpty ? filteredTranscript : matchedTranscript
    }

    private func speakerIDsMatchingTargetIdentity(
        targetSpeakerID: String,
        speakerProfiles: [TranscriptionLabSpeakerProfile]
    ) -> Set<String> {
        guard let targetProfile = speakerProfiles.first(where: { $0.speakerID == targetSpeakerID }) else {
            return [targetSpeakerID]
        }

        var matchingSpeakerIDs: Set<String> = [targetSpeakerID]

        if let recognizedVoiceID = targetProfile.recognizedVoiceID {
            for profile in speakerProfiles where profile.recognizedVoiceID == recognizedVoiceID {
                matchingSpeakerIDs.insert(profile.speakerID)
            }
        }

        if targetProfile.isMe {
            for profile in speakerProfiles where profile.isMe {
                matchingSpeakerIDs.insert(profile.speakerID)
            }
        }

        return matchingSpeakerIDs
    }

    private func repairedSpeakerTaggedTranscript(
        from result: SpeakerTaggedTranscriptionResult,
        fallbackRawTranscription: String
    ) -> SpeakerTaggedTranscript? {
        guard shouldRepairSingleSpeakerTranscript(for: result.diarizationSummary.fallbackReason) else {
            return result.speakerTaggedTranscript
        }

        let normalizedFallbackTranscript = fallbackRawTranscription.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard normalizedFallbackTranscript.isEmpty == false else {
            return nil
        }

        let speakerIDs = result.diarizationSummary.spans.reduce(into: [String]()) { orderedSpeakerIDs, span in
            if orderedSpeakerIDs.contains(span.speakerID) == false {
                orderedSpeakerIDs.append(span.speakerID)
            }
        }
        guard speakerIDs.count == 1, let speakerID = speakerIDs.first else {
            return nil
        }

        let startTime = result.diarizationSummary.spans.map(\.startTime).min() ?? 0
        let endTime = result.diarizationSummary.spans.map(\.endTime).max() ?? startTime
        guard endTime > startTime else {
            return nil
        }

        return SpeakerTaggedTranscript(
            segments: [
                .init(
                    speakerID: speakerID,
                    startTime: startTime,
                    endTime: endTime,
                    text: normalizedFallbackTranscript
                )
            ]
        )
    }

    private func shouldRepairSingleSpeakerTranscript(
        for fallbackReason: DiarizationSummary.FallbackReason?
    ) -> Bool {
        switch fallbackReason {
        case .emptyFilteredTranscription, .singleDetectedSpeaker:
            return true
        case .none,
             .noUsableSpeakerSpans,
             .noSpeakerReachedThreshold,
             .ambiguousDominantSpeaker,
             .insufficientKeptAudio,
             .filteredAudioExtractionFailed:
            return false
        }
    }

    func rerunCleanup(
        entry: TranscriptionLabEntry,
        rawTranscription: String,
        cleanupModelKind: LocalCleanupModelKind,
        prompt: String,
        includeWindowContext: Bool,
        acquirePipeline: () -> Bool,
        releasePipeline: () -> Void
    ) async throws -> TranscriptionLabCleanupResult {
        guard acquirePipeline() else {
            throw TranscriptionLabRunnerError.pipelineBusy
        }
        defer { releasePipeline() }

        let activePrompt = cleanupPromptBuilder.buildPrompt(
            basePrompt: prompt,
            windowContext: entry.windowContext,
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard,
            includeWindowContext: includeWindowContext
        )

        let cleanedResult = await clean(rawTranscription, activePrompt, cleanupModelKind)
        return TranscriptionLabCleanupResult(
            correctedTranscription: cleanedResult.text,
            cleanupUsedFallback: cleanedResult.usedFallback,
            transcript: TranscriptionLabCleanupTranscript(
                prompt: activePrompt,
                inputText: cleanedResult.transcript?.inputText ?? rawTranscription,
                rawModelOutput: cleanedResult.transcript?.rawOutput
            )
        )
    }
}
