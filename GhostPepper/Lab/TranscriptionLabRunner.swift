import Foundation

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
    typealias Cleaner = (String, String, LocalCleanupModelKind) async -> TextCleanerResult

    private let loadAudioBuffer: AudioLoader
    private let loadSpeechModel: SpeechModelLoader
    private let transcribe: Transcriber
    private let clean: Cleaner
    private let correctionStore: CorrectionStore
    private let cleanupPromptBuilder: CleanupPromptBuilder

    init(
        loadAudioBuffer: @escaping AudioLoader,
        loadSpeechModel: @escaping SpeechModelLoader,
        transcribe: @escaping Transcriber,
        clean: @escaping Cleaner,
        correctionStore: CorrectionStore,
        cleanupPromptBuilder: CleanupPromptBuilder = CleanupPromptBuilder()
    ) {
        self.loadAudioBuffer = loadAudioBuffer
        self.loadSpeechModel = loadSpeechModel
        self.transcribe = transcribe
        self.clean = clean
        self.correctionStore = correctionStore
        self.cleanupPromptBuilder = cleanupPromptBuilder
    }

    func rerunTranscription(
        entry: TranscriptionLabEntry,
        speechModelID: String,
        acquirePipeline: () -> Bool,
        releasePipeline: () -> Void
    ) async throws -> String {
        guard acquirePipeline() else {
            throw TranscriptionLabRunnerError.pipelineBusy
        }
        defer { releasePipeline() }

        let audioBuffer = try loadAudioBuffer(entry)
        guard !audioBuffer.isEmpty else {
            throw TranscriptionLabRunnerError.missingAudio
        }

        await loadSpeechModel(speechModelID)

        guard let rawTranscription = await transcribe(audioBuffer) else {
            throw TranscriptionLabRunnerError.transcriptionFailed
        }

        return rawTranscription
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
