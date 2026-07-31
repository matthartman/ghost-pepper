import Combine
import CryptoKit
import Foundation
import LLM

private extension CleanupModelProbeThinkingMode {
    var llmThinkingMode: ThinkingMode {
        switch self {
        case .none:
            return .none
        case .suppressed:
            return .suppressed
        case .enabled:
            return .enabled
        }
    }
}

enum CleanupPurpose {
    case realtime
    case summarization
}

struct CleanupPurposeConfig {
    let maxTokenCount: Int32
    let timeoutSeconds: TimeInterval
}

enum CleanupModelState: Equatable {
    case idle
    case downloading(kind: LocalCleanupModelKind, progress: Double)
    case loadingModel(kind: LocalCleanupModelKind)
    case ready
    case error
}

protocol TextCleaningManaging: AnyObject {
    func clean(text: String, prompt: String?, modelKind: LocalCleanupModelKind?) async throws -> String
}

typealias CleanupModelProbeExecutionOverride = @MainActor (
    _ text: String,
    _ prompt: String,
    _ modelKind: LocalCleanupModelKind,
    _ thinkingMode: CleanupModelProbeThinkingMode
) async throws -> CleanupModelProbeRawResult

enum CleanupModelRecommendation: Equatable {
    case veryFast
    case fast
    case full

    var label: String {
        switch self {
        case .veryFast:
            return "Very fast"
        case .fast:
            return "Fast"
        case .full:
            return "Full"
        }
    }
}

enum LocalCleanupModelKind: String, CaseIterable, Equatable, Identifiable {
    case qwen35_0_8b_q4_k_m
    case qwen35_2b_q4_k_m
    case qwen35_4b_q4_k_m
    case deepseek_r1_qwen_7b_q4_k_m
    case gemma4_12b_it_optiq_4bit_mlx

    var id: String { rawValue }

    static var fast: LocalCleanupModelKind { .qwen35_2b_q4_k_m }
    static var full: LocalCleanupModelKind { .qwen35_4b_q4_k_m }
    static var wikiDefault: LocalCleanupModelKind { .qwen35_4b_q4_k_m }
}

enum CleanupModelRuntime: Equatable {
    case gguf
    case mlxRepository(repoID: String)
}

struct CleanupModelDescriptor: Equatable {
    let kind: LocalCleanupModelKind
    let displayName: String
    let sizeDescription: String
    let fileName: String
    let url: String
    let expectedSHA256: String
    let expectedByteCount: Int64
    let maxTokenCount: Int32
    let recommendation: CleanupModelRecommendation?
    let runtime: CleanupModelRuntime

    init(
        kind: LocalCleanupModelKind,
        displayName: String,
        sizeDescription: String,
        fileName: String,
        url: String,
        expectedSHA256: String,
        expectedByteCount: Int64,
        maxTokenCount: Int32,
        recommendation: CleanupModelRecommendation?,
        runtime: CleanupModelRuntime = .gguf
    ) {
        self.kind = kind
        self.displayName = displayName
        self.sizeDescription = sizeDescription
        self.fileName = fileName
        self.url = url
        self.expectedSHA256 = expectedSHA256
        self.expectedByteCount = expectedByteCount
        self.maxTokenCount = maxTokenCount
        self.recommendation = recommendation
        self.runtime = runtime
    }
}

actor CleanupProbeExecutionGate {
    private var isRunning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            isRunning = false
            return
        }

        waiters.removeFirst().resume()
    }
}

@MainActor
final class TextCleanupManager: ObservableObject, TextCleaningManaging {
    private struct HuggingFaceModelInfo: Decodable {
        let siblings: [Sibling]

        struct Sibling: Decodable {
            let rfilename: String
            let size: Int64?
        }
    }

    private struct PreparedPromptContext {
        let modelKind: LocalCleanupModelKind
        let plan: CleanupPromptPrefillPlan
    }

    @Published private(set) var state: CleanupModelState = .idle
    @Published private(set) var errorMessage: String?
    @Published var selectedCleanupModelKind: LocalCleanupModelKind {
        didSet {
            defaults.set(selectedCleanupModelKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)
        }
    }

    @Published var selectedMeetingSummaryModelKind: LocalCleanupModelKind {
        didSet {
            defaults.set(selectedMeetingSummaryModelKind.rawValue, forKey: Self.selectedMeetingSummaryModelDefaultsKey)
        }
    }

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private(set) var activeLLM: LLM?
    private(set) var activeLoadedModelKind: LocalCleanupModelKind?
    private(set) var activeLoadedContextTokenCount: Int32?

    static let compactModel = CleanupModelDescriptor(
        kind: .qwen35_0_8b_q4_k_m,
        displayName: "Qwen 3.5 0.8B Q4_K_M (Very fast)",
        sizeDescription: "~535 MB",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/6ab461498e2023f6e3c1baea90a8f0fe38ab64d0/Qwen3.5-0.8B-Q4_K_M.gguf",
        expectedSHA256: "bd258782e35f7f458f8aced1adc053e6e92e89bc735ba3be89d38a06121dc517",
        expectedByteCount: 532_517_120,
        maxTokenCount: 16_384,
        recommendation: .veryFast
    )

    static let recommendedFastModel = CleanupModelDescriptor(
        kind: .qwen35_2b_q4_k_m,
        displayName: "Qwen 3.5 2B Q4_K_M (Fast)",
        sizeDescription: "~1.3 GB",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf",
        expectedSHA256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223",
        expectedByteCount: 1_280_835_840,
        maxTokenCount: 16_384,
        recommendation: .fast
    )

    static let recommendedFullModel = CleanupModelDescriptor(
        kind: .qwen35_4b_q4_k_m,
        displayName: "Qwen 3.5 4B Q4_K_M (Full)",
        sizeDescription: "~2.8 GB",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf",
        expectedSHA256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4",
        expectedByteCount: 2_740_937_888,
        maxTokenCount: 16_384,
        recommendation: .full
    )

    /// DeepSeek R1 Distill Qwen 7B — Qwen 2.5 7B base distilled from R1
    /// reasoning traces. Stronger chain-of-thought for agent tool-use loops
    /// than vanilla Qwen 4B. Always emits `<think>...</think>` blocks before
    /// answers; the QwenToolCallParser strips those so they don't surface as
    /// visible text. Cleanup-quality is unverified — primarily added for the
    /// agent path.
    static let deepseekR1Qwen7BModel = CleanupModelDescriptor(
        kind: .deepseek_r1_qwen_7b_q4_k_m,
        displayName: "DeepSeek R1 Distill Qwen 7B Q4_K_M",
        sizeDescription: "~4.7 GB",
        fileName: "DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
        url: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/361004151d4f4f6b446dc5e6d46fbf4422a80d5f/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
        expectedSHA256: "731ece8d06dc7eda6f6572997feb9ee1258db0784827e642909d9b565641937b",
        expectedByteCount: 4_683_073_504,
        maxTokenCount: 8192,
        recommendation: nil
    )

    static let gemma4WikiModel = CleanupModelDescriptor(
        kind: .gemma4_12b_it_optiq_4bit_mlx,
        displayName: "Gemma 4 12B Instruct OptiQ 4-bit MLX (Wiki)",
        sizeDescription: "~9 GB",
        fileName: "mlx-community--gemma-4-12B-it-OptiQ-4bit",
        url: "https://huggingface.co/mlx-community/gemma-4-12B-it-OptiQ-4bit",
        expectedSHA256: "",
        expectedByteCount: 0,
        maxTokenCount: 16_384,
        recommendation: nil,
        runtime: .mlxRepository(repoID: "mlx-community/gemma-4-12B-it-OptiQ-4bit")
    )

    static let cleanupModels = [
        compactModel,
        recommendedFastModel,
        recommendedFullModel,
        deepseekR1Qwen7BModel,
        gemma4WikiModel,
    ]
    static let cleanupGenerationModels = cleanupModels.filter { $0.runtime == .gguf }
    static let wikiGenerationModels = cleanupModels
    static let fastModel = recommendedFastModel
    static let fullModel = recommendedFullModel

    static func cleanupModelKind(matchingArchivedName archivedName: String) -> LocalCleanupModelKind {
        if let exactMatch = cleanupModels.first(where: { $0.displayName == archivedName }) {
            return exactMatch.kind
        }

        if archivedName.contains("0.8B") {
            return .qwen35_0_8b_q4_k_m
        }

        if archivedName.contains("2B") || archivedName.contains("1.7B") {
            return .qwen35_2b_q4_k_m
        }

        return .qwen35_4b_q4_k_m
    }

    static func config(for purpose: CleanupPurpose) -> CleanupPurposeConfig {
        switch purpose {
        case .realtime:
            return CleanupPurposeConfig(maxTokenCount: 4096, timeoutSeconds: 15.0)
        case .summarization:
            return CleanupPurposeConfig(maxTokenCount: 16384, timeoutSeconds: 90.0)
        }
    }

    var isReady: Bool { state == .ready }
    var selectedCleanupModelDisplayName: String {
        descriptor(for: selectedCleanupModelKind).displayName
    }

    var hasUsableModelForCurrentPolicy: Bool {
        isModelAvailable(selectedCleanupModelKind)
    }

    private static let timeoutSeconds: TimeInterval = 15.0
    private static let selectedCleanupModelDefaultsKey = "selectedCleanupModelKind"
    private static let selectedMeetingSummaryModelDefaultsKey = "selectedMeetingSummaryModelKind"
    private static let systemPromptSentinel = "<|ghost-pepper-system-prefill-split|>"
    private static let userInputSentinel = "<|ghost-pepper-user-prefill-split|>"
    private static let repositoryDownloadMarkerFileName = ".ghostpepper-model-cache-complete"

    private let defaults: UserDefaults
    private let cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool]
    private let probeExecutionOverride: CleanupModelProbeExecutionOverride?
    private let backendShutdownOverride: (() -> Void)?
    private let modelsDirectory: URL
    private let probeExecutionGate = CleanupProbeExecutionGate()
    private var promptPrefillTask: Task<Void, Never>?
    private var preparedPromptContext: PreparedPromptContext?
    /// Tracks the in-flight download/load Task so the UI can cancel it. We
    /// only allow one load at a time (the manager has a single `activeLLM`
    /// slot), so a Task? is sufficient.
    private var activeLoadTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        selectedCleanupModelKind: LocalCleanupModelKind? = nil,
        selectedMeetingSummaryModelKind: LocalCleanupModelKind? = nil,
        cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool] = [:],
        probeExecutionOverride: CleanupModelProbeExecutionOverride? = nil,
        backendShutdownOverride: (() -> Void)? = nil,
        modelsDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.cleanupModelAvailabilityOverrides = cleanupModelAvailabilityOverrides
        self.probeExecutionOverride = probeExecutionOverride
        self.backendShutdownOverride = backendShutdownOverride
        self.modelsDirectory = modelsDirectory ?? Self.modelsDirectory

        let storedKind = LocalCleanupModelKind(
            rawValue: defaults.string(forKey: Self.selectedCleanupModelDefaultsKey) ?? ""
        ) ?? .qwen35_0_8b_q4_k_m
        let initialKind = selectedCleanupModelKind ?? storedKind
        self.selectedCleanupModelKind = initialKind
        defaults.set(initialKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)

        let storedSummaryKind = LocalCleanupModelKind(
            rawValue: defaults.string(forKey: Self.selectedMeetingSummaryModelDefaultsKey) ?? ""
        ) ?? .qwen35_4b_q4_k_m
        let initialSummaryKind = selectedMeetingSummaryModelKind ?? storedSummaryKind
        self.selectedMeetingSummaryModelKind = initialSummaryKind
        defaults.set(initialSummaryKind.rawValue, forKey: Self.selectedMeetingSummaryModelDefaultsKey)
    }

    func selectedModelKind(wordCount: Int, isQuestion: Bool) -> LocalCleanupModelKind? {
        isModelAvailable(selectedCleanupModelKind) ? selectedCleanupModelKind : nil
    }

    var statusText: String {
        switch state {
        case .idle:
            return ""
        case .downloading(_, let progress):
            let pct = Int(progress * 100)
            return "Downloading cleanup models (\(pct)%)..."
        case .loadingModel:
            return "Loading cleanup models..."
        case .ready:
            return ""
        case .error:
            return errorMessage ?? "Cleanup model error"
        }
    }

    private func modelPath(for fileName: String) -> URL {
        modelsDirectory.appendingPathComponent(fileName)
    }

    static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/models", isDirectory: true)
    }

    static func isModelDownloaded(_ kind: LocalCleanupModelKind) -> Bool {
        guard let desc = cleanupModels.first(where: { $0.kind == kind }) else { return false }
        let path = modelsDirectory.appendingPathComponent(desc.fileName)
        return isVerifiedModelFile(path, descriptor: desc)
    }

    func isModelDownloaded(_ kind: LocalCleanupModelKind) -> Bool {
        Self.isModelDownloaded(kind)
    }

    func deleteCachedModel(kind: LocalCleanupModelKind) {
        let desc = descriptor(for: kind)
        let path = modelPath(for: desc.fileName)
        try? FileManager.default.removeItem(at: path)

        if activeLoadedModelKind == kind {
            activeLLM = nil
            activeLoadedModelKind = nil
            activeLoadedContextTokenCount = nil
            state = .idle
            errorMessage = nil
            return
        }

        objectWillChange.send()
    }

    func clean(text: String, prompt: String? = nil, modelKind: LocalCleanupModelKind? = nil) async throws -> String {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        await loadModel(kind: requestedModelKind)

        guard model(for: requestedModelKind) != nil else {
            debugLogger?(
                .cleanup,
                "Skipped local cleanup because model \(requestedModelKind.rawValue) was not ready."
            )
            throw CleanupBackendError.unavailable
        }

        let activePrompt = prompt ?? TextCleaner.defaultPrompt
        do {
            let result = try await probe(
                text: text,
                prompt: activePrompt,
                modelKind: requestedModelKind,
                thinkingMode: .suppressed
            )
            let cleaned = result.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == "..." {
                debugLogger?(
                    .cleanup,
                    """
                    Discarded local cleanup output from \(descriptor(for: requestedModelKind).displayName) because it was unusable:
                    \(result.rawOutput)
                    """
                )
                throw CleanupBackendError.unusableOutput(rawOutput: result.rawOutput)
            }
            return cleaned
        } catch let error as CleanupBackendError {
            throw error
        } catch let error as CleanupModelProbeError {
            switch error {
            case .modelUnavailable:
                throw CleanupBackendError.unavailable
            }
        } catch is CancellationError {
            debugLogger?(
                .cleanup,
                "Local cleanup probe failed before producing usable output: timed out after \(Int(Self.timeoutSeconds))s."
            )
            throw CleanupBackendError.timedOut(seconds: Self.timeoutSeconds)
        } catch {
            debugLogger?(
                .cleanup,
                "Local cleanup probe failed before producing usable output: \(error.localizedDescription)"
            )
            throw CleanupBackendError.unavailable
        }
    }

    /// Streams raw completion tokens from a local Qwen model using a
    /// fully-formed prompt string. The caller is responsible for any
    /// chat-template framing (e.g. Qwen3's `<|im_start|>` markers); this method
    /// passes the prompt straight to the model and yields tokens as they
    /// arrive. Used by `LocalLLMProvider` to drive the agent loop.
    ///
    /// Acquires the same probe gate as `clean()` so concurrent local cleanup
    /// and agent runs don't share KV-cache state.
    func streamCompletion(
        prompt: String,
        modelKind: LocalCleanupModelKind? = nil,
        thinkingMode: ThinkingMode = .suppressed
    ) async throws -> AsyncStream<String> {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        await loadModel(kind: requestedModelKind)
        let requestedDescriptor = descriptor(for: requestedModelKind)

        if case .mlxRepository = requestedDescriptor.runtime {
            throw CleanupBackendError.unsupportedRuntime(
                "\(requestedDescriptor.displayName) is downloaded/selectable, but MLX inference is not wired into Ghost Pepper yet. Choose a GGUF model such as Qwen 3.5 4B, or wire the MLX provider next."
            )
        }

        guard let llm = model(for: requestedModelKind) else {
            debugLogger?(
                .cleanup,
                "Skipped local stream completion because model \(requestedModelKind.rawValue) was not ready."
            )
            throw CleanupBackendError.unavailable
        }

        await probeExecutionGate.acquire()
        await llm.core.resetContext()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let gate = probeExecutionGate
        let task = Task { @MainActor in
            let response = await llm.core.generateResponseStream(
                from: prompt,
                thinking: thinkingMode
            )
            for await token in response {
                if Task.isCancelled { break }
                continuation.yield(token)
            }
            await gate.release()
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    func startPromptPrefill(systemPromptPrefix: String, modelKind: LocalCleanupModelKind? = nil) {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        guard systemPromptPrefix.isEmpty == false else {
            preparedPromptContext = nil
            promptPrefillTask?.cancel()
            promptPrefillTask = nil
            return
        }

        if let preparedPromptContext,
           preparedPromptContext.modelKind == requestedModelKind,
           preparedPromptContext.plan.systemPromptPrefix == systemPromptPrefix {
            return
        }

        promptPrefillTask?.cancel()
        promptPrefillTask = Task { @MainActor [weak self] in
            await self?.prefillPromptContext(
                systemPromptPrefix: systemPromptPrefix,
                modelKind: requestedModelKind
            )
        }
    }

    func cancelPromptPrefill() {
        promptPrefillTask?.cancel()
        promptPrefillTask = nil
        preparedPromptContext = nil
    }

    func probe(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind,
        thinkingMode: CleanupModelProbeThinkingMode
    ) async throws -> CleanupModelProbeRawResult {
        await probeExecutionGate.acquire()
        do {
            if let probeExecutionOverride {
                let result = try await probeExecutionOverride(text, prompt, modelKind, thinkingMode)
                logTokenBudget(text: text, prompt: prompt, modelKind: modelKind, rawOutput: result.rawOutput, elapsed: result.elapsed)
                await probeExecutionGate.release()
                return result
            }

            guard let llm = model(for: modelKind) else {
                debugLogger?(
                    .cleanup,
                    "Skipped local cleanup probe because model \(modelKind) was not ready."
                )
                await probeExecutionGate.release()
                throw CleanupModelProbeError.modelUnavailable(modelKind)
            }

            let start = Date()
            do {
                let preparedCompletionInput: String?
                if let preparedPromptContext,
                   preparedPromptContext.modelKind == modelKind,
                   let completionInput = preparedPromptContext.plan.completionInput(
                    for: prompt,
                    userInput: text
                   ) {
                    preparedCompletionInput = completionInput
                    self.preparedPromptContext = nil
                } else {
                    preparedCompletionInput = nil
                }

                let rawOutput: String
                if let preparedCompletionInput {
                    rawOutput = try await withTimeout(seconds: Self.timeoutSeconds) { [self] in
                        await generateFromPreparedContext(
                            llm: llm,
                            completionInput: preparedCompletionInput,
                            thinkingMode: thinkingMode
                        )
                    }
                } else {
                    rawOutput = try await withTimeout(seconds: Self.timeoutSeconds) {
                        llm.useResolvedTemplate(systemPrompt: prompt)
                        llm.history = []
                        await llm.respond(to: text, thinking: thinkingMode.llmThinkingMode)
                        return llm.output
                    }
                }
                let elapsed = Date().timeIntervalSince(start)
                logTokenBudget(text: text, prompt: prompt, modelKind: modelKind, rawOutput: rawOutput, elapsed: elapsed)
                await probeExecutionGate.release()
                return CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: descriptor(for: modelKind).displayName,
                    rawOutput: rawOutput,
                    elapsed: elapsed
                )
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                debugLogger?(
                    .cleanup,
                    "Local cleanup failed after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)"
                )
                await probeExecutionGate.release()
                throw error
            }
        } catch {
            throw error
        }
    }

    func loadModel() async {
        await loadModel(kind: selectedCleanupModelKind)
    }

    func downloadMissingModels() async {
        guard state == .idle || state == .error || state == .ready else { return }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        for descriptor in Self.cleanupModels {
            guard descriptor.runtime == .gguf else {
                continue
            }
            let path = modelPath(for: descriptor.fileName)
            guard !Self.isVerifiedModelFile(path, descriptor: descriptor) else {
                continue
            }
            try? FileManager.default.removeItem(at: path)

            do {
                try await downloadModel(kind: descriptor.kind, url: descriptor.url, to: path)
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
                return
            }
        }

        state = .idle
        await loadModel()
    }

    func loadModel(kind: LocalCleanupModelKind, contextTokenCount: Int32) async {
        let requestedContext = min(contextTokenCount, descriptor(for: kind).maxTokenCount)

        if activeLoadedModelKind == kind && activeLoadedContextTokenCount == requestedContext && activeLLM != nil {
            state = .ready
            errorMessage = nil
            return
        }

        if case .loadingModel = state {
            await waitForActiveLoad()
            if activeLoadedModelKind == kind && activeLoadedContextTokenCount == requestedContext && activeLLM != nil {
                state = .ready
                errorMessage = nil
                return
            }
        }

        guard state == .idle || state == .error || state == .ready else { return }

        if let override = availabilityOverride(for: kind), !override {
            errorMessage = "Failed to load the selected cleanup model."
            state = .error
            return
        }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        let descriptor = descriptor(for: kind)
        let path = modelPath(for: descriptor.fileName)
        debugLogger?(.model, "Loading local cleanup model \(descriptor.displayName).")

        if FileManager.default.fileExists(atPath: path.path), !Self.isVerifiedModelFile(path, descriptor: descriptor) {
            try? FileManager.default.removeItem(at: path)
            debugLogger?(.model, "Removed local cleanup model with failed integrity check: \(descriptor.displayName).")
        }

        if !FileManager.default.fileExists(atPath: path.path) {
            do {
                try await downloadModel(kind: kind, url: descriptor.url, to: path)
            } catch {
                let nsError = error as NSError
                let isCancelled = error is CancellationError
                    || nsError.code == NSURLErrorCancelled
                    || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                if isCancelled {
                    self.state = .idle
                    self.errorMessage = nil
                    debugLogger?(.model, "Cleanup model download cancelled: \(descriptor.displayName).")
                } else {
                    self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                    self.state = .error
                    debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
                }
                return
            }
        }

        if case .mlxRepository = descriptor.runtime {
            errorMessage = "Downloaded \(descriptor.displayName). MLX inference is not wired into Ghost Pepper yet."
            state = .error
            debugLogger?(.model, errorMessage ?? "MLX model downloaded but runtime unavailable.")
            return
        }

        state = .loadingModel(kind: kind)
        activeLLM = nil
        activeLoadedModelKind = nil
        activeLoadedContextTokenCount = nil

        let loadedModel = await Task.detached { () -> LLM? in
            guard let llm = LLM(from: path, maxTokenCount: requestedContext) else {
                return nil
            }
            llm.useResolvedTemplate(systemPrompt: TextCleaner.defaultPrompt)
            return llm
        }.value

        guard let loadedModel else {
            errorMessage = "Failed to load the selected cleanup model."
            state = .error
            debugLogger?(.model, "Local cleanup model unavailable: \(descriptor.displayName).")
            return
        }

        loadedModel.temp = 0.1
        loadedModel.update = { (_: String?) in }
        loadedModel.postprocess = { (_: String) in }
        activeLLM = loadedModel
        activeLoadedModelKind = kind
        activeLoadedContextTokenCount = requestedContext
        state = .ready
        errorMessage = nil
        debugLogger?(.model, "Local cleanup model ready: \(descriptor.displayName).")
    }

    func loadModel(kind: LocalCleanupModelKind) async {
        await loadModel(kind: kind, contextTokenCount: descriptor(for: kind).maxTokenCount)
    }

    /// Kicks off a tracked `loadModel(kind:)` so callers can later cancel it
    /// via `cancelActiveLoad()`. If a load Task is already in flight for the
    /// same kind, returns without starting a duplicate; otherwise the prior
    /// Task is cancelled and replaced.
    func startLoad(kind: LocalCleanupModelKind) {
        if let activeLoadTask, !activeLoadTask.isCancelled,
           case let .downloading(activeKind, _) = state, activeKind == kind {
            return
        }
        if let activeLoadTask, !activeLoadTask.isCancelled,
           case let .loadingModel(activeKind) = state, activeKind == kind {
            return
        }
        activeLoadTask?.cancel()
        activeLoadTask = Task { @MainActor [weak self] in
            await self?.loadModel(kind: kind)
            self?.activeLoadTask = nil
        }
    }

    /// Cancels whatever the manager is currently downloading or loading.
    /// `URLSession.download(from:)` is cancellation-aware, so the in-flight
    /// transfer aborts at the next suspension point.
    func cancelActiveLoad() {
        activeLoadTask?.cancel()
        activeLoadTask = nil
    }

    /// Surface for UI: is there an active load Task we can cancel? Used to
    /// decide whether to render the cancel affordance — passively-displayed
    /// progress (e.g. a stale `.downloading` from a prior session) shouldn't
    /// show one.
    var isLoadCancellable: Bool {
        guard let activeLoadTask else { return false }
        return !activeLoadTask.isCancelled
    }

    func unloadModel() {
        activeLLM = nil
        activeLoadedModelKind = nil
        activeLoadedContextTokenCount = nil
        state = .idle
        errorMessage = nil
        debugLogger?(.model, "Unloaded local cleanup models.")
    }

    func shutdownBackend() {
        unloadModel()
        if let backendShutdownOverride {
            backendShutdownOverride()
        } else {
            LLM.shutdownBackend()
        }
        debugLogger?(.model, "Shutdown llama backend.")
    }

    var cachedModelKinds: Set<LocalCleanupModelKind> {
        Set(Self.cleanupModels.compactMap { descriptor in
            if let override = availabilityOverride(for: descriptor.kind) {
                return override ? descriptor.kind : nil
            }

            return Self.isPlausibleCachedModelFile(modelPath(for: descriptor.fileName), descriptor: descriptor)
                ? descriptor.kind
                : nil
        })
    }

    private func downloadModel(kind: LocalCleanupModelKind, url urlString: String, to destination: URL) async throws {
        let descriptor = descriptor(for: kind)
        if case .mlxRepository(let repoID) = descriptor.runtime {
            try await downloadHuggingFaceRepository(kind: kind, repoID: repoID, to: destination)
            return
        }

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        state = .downloading(kind: kind, progress: 0)

        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.state = .downloading(kind: kind, progress: progress)
            }
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, _) = try await session.download(from: url)
        guard Self.isVerifiedModelFile(tempURL, descriptor: descriptor) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw URLError(.cannotDecodeContentData)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func model(for modelKind: LocalCleanupModelKind) -> LLM? {
        activeLoadedModelKind == modelKind ? activeLLM : nil
    }

    private func descriptor(for modelKind: LocalCleanupModelKind) -> CleanupModelDescriptor {
        Self.cleanupModels.first(where: { $0.kind == modelKind })!
    }

    /// Logs an estimated token budget (~4 chars/token) so a completion that's
    /// suspiciously short relative to the model's context window — the
    /// signature of hitting `maxTokenCount` mid-generation rather than an
    /// error — is visible in the debug log rather than looking like a normal
    /// success.
    private func logTokenBudget(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind,
        rawOutput: String,
        elapsed: TimeInterval
    ) {
        let promptTokens = Self.estimatedTokenCount(text) + Self.estimatedTokenCount(prompt)
        let outputTokens = Self.estimatedTokenCount(rawOutput)
        let maxTokens = Int(descriptor(for: modelKind).maxTokenCount)
        debugLogger?(
            .cleanup,
            "Local cleanup finished in \(String(format: "%.2f", elapsed))s using \(descriptor(for: modelKind).displayName) — ~\(promptTokens) prompt + ~\(outputTokens) output of \(maxTokens) max tokens."
        )
    }

    private static func estimatedTokenCount(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    private func availabilityOverride(for modelKind: LocalCleanupModelKind) -> Bool? {
        guard !cleanupModelAvailabilityOverrides.isEmpty else {
            return nil
        }

        return cleanupModelAvailabilityOverrides[modelKind] ?? false
    }

    private func waitForActiveLoad() async {
        while case .loadingModel = state {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func prefillPromptContext(
        systemPromptPrefix: String,
        modelKind: LocalCleanupModelKind
    ) async {
        await loadModel(kind: modelKind)
        await probeExecutionGate.acquire()
        guard let llm = model(for: modelKind) else {
            preparedPromptContext = nil
            await probeExecutionGate.release()
            return
        }

        let sentinelPrompt = systemPromptPrefix + Self.systemPromptSentinel
        llm.useResolvedTemplate(systemPrompt: sentinelPrompt)
        llm.history = []
        let processedPrompt = llm.preprocess(
            Self.userInputSentinel,
            [],
            .suppressed
        )
        guard let plan = CleanupPromptPrefillPlan(
            systemPromptPrefix: systemPromptPrefix,
            processedPrompt: processedPrompt,
            systemPromptSentinel: Self.systemPromptSentinel,
            userInputSentinel: Self.userInputSentinel
        ) else {
            preparedPromptContext = nil
            await probeExecutionGate.release()
            return
        }

        await llm.core.resetContext()
        let prepared = await llm.core.prepareContext(for: plan.contextPrefix)
        preparedPromptContext = prepared
            ? PreparedPromptContext(modelKind: modelKind, plan: plan)
            : nil
        await probeExecutionGate.release()
    }

    private func generateFromPreparedContext(
        llm: LLM,
        completionInput: String,
        thinkingMode: CleanupModelProbeThinkingMode
    ) async -> String {
        llm.setOutput(to: "")
        llm.setThinking(to: "")

        let response = await llm.core.generateResponseStream(
            from: completionInput,
            thinking: thinkingMode.llmThinkingMode
        )

        var output = ""
        for await content in response {
            output += content
        }

        llm.setOutput(to: output)
        return output
    }

    private func isModelAvailable(_ modelKind: LocalCleanupModelKind) -> Bool {
        if let override = availabilityOverride(for: modelKind) {
            return override
        }

        if activeLoadedModelKind == modelKind && activeLLM != nil {
            return true
        }

        let descriptor = descriptor(for: modelKind)
        return Self.isVerifiedModelFile(modelPath(for: descriptor.fileName), descriptor: descriptor)
    }

    private static func isVerifiedModelFile(_ url: URL, descriptor: CleanupModelDescriptor) -> Bool {
        if case .mlxRepository = descriptor.runtime {
            return isVerifiedRepository(url)
        }

        guard isPlausibleCachedModelFile(url, descriptor: descriptor) else { return false }
        return (try? sha256Hex(of: url)) == descriptor.expectedSHA256
    }

    private static func isPlausibleCachedModelFile(_ url: URL, descriptor: CleanupModelDescriptor) -> Bool {
        if case .mlxRepository = descriptor.runtime {
            return isVerifiedRepository(url)
        }

        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              Int64(values.fileSize ?? -1) == descriptor.expectedByteCount else {
            return false
        }
        return true
    }

    private static func isVerifiedRepository(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent(repositoryDownloadMarkerFileName).path
        )
    }

    private func downloadHuggingFaceRepository(kind: LocalCleanupModelKind, repoID: String, to destination: URL) async throws {
        guard let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID)") else {
            throw URLError(.badURL)
        }

        state = .downloading(kind: kind, progress: 0)
        let (infoData, _) = try await URLSession.shared.data(from: apiURL)
        let info = try JSONDecoder().decode(HuggingFaceModelInfo.self, from: infoData)
        let files = info.siblings.filter { sibling in
            !sibling.rfilename.hasPrefix(".") && !sibling.rfilename.hasSuffix(".md")
        }

        guard !files.isEmpty else {
            throw URLError(.fileDoesNotExist)
        }

        let tempDirectory = modelsDirectory.appendingPathComponent("\(destination.lastPathComponent).download", isDirectory: true)
        try? FileManager.default.removeItem(at: tempDirectory)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        do {
            let knownTotalBytes = files.compactMap(\.size).reduce(Int64(0), +)
            var completedBytes: Int64 = 0

            for file in files {
                try Task.checkCancellation()
                guard let encodedFile = file.rfilename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(encodedFile)") else {
                    throw URLError(.badURL)
                }
                let localURL = tempDirectory.appendingPathComponent(file.rfilename)
                try FileManager.default.createDirectory(
                    at: localURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let (downloadedURL, _) = try await URLSession.shared.download(from: fileURL)
                try? FileManager.default.removeItem(at: localURL)
                try FileManager.default.moveItem(at: downloadedURL, to: localURL)
                completedBytes += file.size ?? 0
                if knownTotalBytes > 0 {
                    state = .downloading(kind: kind, progress: min(0.99, Double(completedBytes) / Double(knownTotalBytes)))
                }
            }

            let marker = tempDirectory.appendingPathComponent(Self.repositoryDownloadMarkerFileName)
            try Data("repo=\(repoID)\ndownloadedAt=\(ISO8601DateFormatter().string(from: Date()))\n".utf8).write(to: marker)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempDirectory, to: destination)
            state = .downloading(kind: kind, progress: 1)
        } catch {
            try? FileManager.default.removeItem(at: tempDirectory)
            throw error
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Download Progress

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:) call
    }
}
