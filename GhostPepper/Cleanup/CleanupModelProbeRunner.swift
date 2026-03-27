import Foundation

enum CleanupModelProbeThinkingMode: String, CaseIterable, Equatable, Sendable {
    case none
    case suppressed
    case enabled
}

struct CleanupModelProbeRawResult: Equatable, Sendable {
    let modelKind: LocalCleanupModelKind
    let modelDisplayName: String
    let rawOutput: String
    let elapsed: TimeInterval
}

struct CleanupModelProbeTranscript: Equatable, Sendable {
    let modelKind: LocalCleanupModelKind
    let modelDisplayName: String
    let thinkingMode: CleanupModelProbeThinkingMode
    let input: String
    let correctedInput: String
    let modelInput: String
    let finalPrompt: String
    let rawModelOutput: String
    let sanitizedOutput: String
    let finalOutput: String
    let elapsed: TimeInterval
}

enum CleanupModelProbeError: Error, LocalizedError {
    case modelUnavailable(LocalCleanupModelKind)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable(let modelKind):
            return "Cleanup model \(modelKind) is not loaded."
        }
    }
}

@MainActor
struct CleanupModelProbeRunner {
    typealias Execute = @MainActor (_ input: String, _ prompt: String, _ modelKind: LocalCleanupModelKind, _ thinkingMode: CleanupModelProbeThinkingMode) async throws -> CleanupModelProbeRawResult

    private let correctionStore: CorrectionStore
    private let promptBuilder: CleanupPromptBuilder
    private let execute: Execute

    init(
        correctionStore: CorrectionStore = CorrectionStore(),
        promptBuilder: CleanupPromptBuilder = CleanupPromptBuilder(),
        execute: @escaping Execute
    ) {
        self.correctionStore = correctionStore
        self.promptBuilder = promptBuilder
        self.execute = execute
    }

    func run(
        input: String,
        modelKind: LocalCleanupModelKind,
        thinkingMode: CleanupModelProbeThinkingMode,
        prompt: String? = nil,
        windowContext: OCRContext? = nil
    ) async throws -> CleanupModelProbeTranscript {
        let activePrompt = prompt ?? TextCleaner.defaultPrompt
        let finalPrompt = promptBuilder.buildPrompt(
            basePrompt: activePrompt,
            windowContext: windowContext,
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard,
            includeWindowContext: windowContext != nil
        )
        let correctionEngine = DeterministicCorrectionEngine(
            preferredTranscriptions: correctionStore.preferredTranscriptions,
            commonlyMisheard: correctionStore.commonlyMisheard
        )
        let correctedInput = correctionEngine.applyPreCleanupCorrections(to: input)
        let modelInput = TextCleaner.formatCleanupInput(userInput: correctedInput)
        let rawResult = try await execute(modelInput, finalPrompt, modelKind, thinkingMode)
        let sanitizedOutput = TextCleaner.sanitizeCleanupOutput(rawResult.rawOutput)
        let finalOutput = correctionEngine.applyPostCleanupCorrections(to: sanitizedOutput)

        return CleanupModelProbeTranscript(
            modelKind: rawResult.modelKind,
            modelDisplayName: rawResult.modelDisplayName,
            thinkingMode: thinkingMode,
            input: input,
            correctedInput: correctedInput,
            modelInput: modelInput,
            finalPrompt: finalPrompt,
            rawModelOutput: rawResult.rawOutput,
            sanitizedOutput: sanitizedOutput,
            finalOutput: finalOutput,
            elapsed: rawResult.elapsed
        )
    }
}
