import Combine
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
    case qwen35_9b_q4_k_m
    case qwen35_27b_q4_k_m
    case qwen35_35b_a3b_q4_k_m
    case deepseek_r1_qwen_7b_q4_k_m

    var id: String { rawValue }

    static var fast: LocalCleanupModelKind { .qwen35_2b_q4_k_m }
    static var full: LocalCleanupModelKind { .qwen35_4b_q4_k_m }
}

struct CleanupModelDescriptor: Equatable {
    let kind: LocalCleanupModelKind
    let displayName: String
    let sizeDescription: String
    let fileName: String
    let url: String
    let maxTokenCount: Int32
    let recommendation: CleanupModelRecommendation?
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

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    private(set) var activeLLM: LLM?
    private(set) var activeLoadedModelKind: LocalCleanupModelKind?

    static let compactModel = CleanupModelDescriptor(
        kind: .qwen35_0_8b_q4_k_m,
        displayName: "Qwen 3.5 0.8B Q4_K_M (Very fast)",
        sizeDescription: "~535 MB",
        fileName: "Qwen3.5-0.8B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf",
        maxTokenCount: 2048,
        recommendation: .veryFast
    )

    static let recommendedFastModel = CleanupModelDescriptor(
        kind: .qwen35_2b_q4_k_m,
        displayName: "Qwen 3.5 2B Q4_K_M (Fast)",
        sizeDescription: "~1.3 GB",
        fileName: "Qwen3.5-2B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf",
        maxTokenCount: 2048,
        recommendation: .fast
    )

    static let recommendedFullModel = CleanupModelDescriptor(
        kind: .qwen35_4b_q4_k_m,
        displayName: "Qwen 3.5 4B Q4_K_M (Full)",
        sizeDescription: "~2.8 GB",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
        maxTokenCount: 4096,
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
        url: "https://huggingface.co/bartowski/DeepSeek-R1-Distill-Qwen-7B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-7B-Q4_K_M.gguf",
        maxTokenCount: 8192,
        recommendation: nil
    )

    /// Qwen 3.5 9B — dense, a solid step up from 4B for the agent loop while
    /// staying small (~5.7 GB) and fast. Genuine `<tool_call>` tool-caller.
    static let qwen35_9BModel = CleanupModelDescriptor(
        kind: .qwen35_9b_q4_k_m,
        displayName: "Qwen 3.5 9B Q4_K_M (Agent)",
        sizeDescription: "~5.7 GB",
        fileName: "Qwen3.5-9B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf",
        maxTokenCount: 16384,
        recommendation: nil
    )

    /// Qwen 3.5 27B — dense, strongest dense quality that still fits a 48 GB
    /// machine (~16.7 GB). Slower than the MoE since all 27B params are active
    /// per token, but high quality for the agent loop.
    static let qwen35_27BModel = CleanupModelDescriptor(
        kind: .qwen35_27b_q4_k_m,
        displayName: "Qwen 3.5 27B Q4_K_M (Agent)",
        sizeDescription: "~16.7 GB",
        fileName: "Qwen3.5-27B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-27B-GGUF/resolve/main/Qwen3.5-27B-Q4_K_M.gguf",
        maxTokenCount: 16384,
        recommendation: nil
    )

    /// Qwen 3.5 35B-A3B — a Mixture-of-Experts model: 35B total parameters
    /// (large-model reasoning quality) but only ~3B active per token, so it
    /// runs at roughly 9B-dense speed. Added specifically for the agentic
    /// meeting Q&A loop, where reliable `<tool_call>` emission and multi-hop
    /// reasoning matter more than the tiny cleanup models can deliver. Needs
    /// ~22 GB on disk and comfortable headroom on a 32 GB+ machine.
    static let qwen35_35bA3BModel = CleanupModelDescriptor(
        kind: .qwen35_35b_a3b_q4_k_m,
        displayName: "Qwen 3.5 35B-A3B Q4_K_M (Agent)",
        sizeDescription: "~22 GB",
        fileName: "Qwen3.5-35B-A3B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-35B-A3B-GGUF/resolve/main/Qwen3.5-35B-A3B-Q4_K_M.gguf",
        maxTokenCount: 16384,
        recommendation: nil
    )

    static let cleanupModels = [
        compactModel,
        recommendedFastModel,
        recommendedFullModel,
        qwen35_9BModel,
        qwen35_27BModel,
        qwen35_35bA3BModel,
        deepseekR1Qwen7BModel,
    ]
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

    var isReady: Bool { state == .ready }
    var selectedCleanupModelDisplayName: String {
        descriptor(for: selectedCleanupModelKind).displayName
    }

    var hasUsableModelForCurrentPolicy: Bool {
        isModelAvailable(selectedCleanupModelKind)
    }

    private static let timeoutSeconds: TimeInterval = 15.0
    private static let selectedCleanupModelDefaultsKey = "selectedCleanupModelKind"
    private static let systemPromptSentinel = "<|ghost-pepper-system-prefill-split|>"
    private static let userInputSentinel = "<|ghost-pepper-user-prefill-split|>"

    private let defaults: UserDefaults
    private let cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool]
    private let probeExecutionOverride: CleanupModelProbeExecutionOverride?
    private let backendShutdownOverride: (() -> Void)?
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
        cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool] = [:],
        probeExecutionOverride: CleanupModelProbeExecutionOverride? = nil,
        backendShutdownOverride: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.cleanupModelAvailabilityOverrides = cleanupModelAvailabilityOverrides
        self.probeExecutionOverride = probeExecutionOverride
        self.backendShutdownOverride = backendShutdownOverride

        let storedKind = LocalCleanupModelKind(
            rawValue: defaults.string(forKey: Self.selectedCleanupModelDefaultsKey) ?? ""
        ) ?? .qwen35_0_8b_q4_k_m
        let initialKind = selectedCleanupModelKind ?? storedKind
        self.selectedCleanupModelKind = initialKind
        defaults.set(initialKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)
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

    private var modelsDirectory: URL {
        Self.modelsDirectory
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
        return FileManager.default.fileExists(atPath: path.path)
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
        modelKind: LocalCleanupModelKind? = nil
    ) async throws -> AsyncStream<String> {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        await loadModel(kind: requestedModelKind)

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
                thinking: ThinkingMode.suppressed
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
                debugLogger?(
                    .cleanup,
                    "Local cleanup finished in \(String(format: "%.2f", elapsed))s using \(descriptor(for: modelKind).displayName)."
                )
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
            let path = modelPath(for: descriptor.fileName)
            guard !FileManager.default.fileExists(atPath: path.path) else {
                continue
            }

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

    func loadModel(kind: LocalCleanupModelKind) async {
        if activeLoadedModelKind == kind && activeLLM != nil {
            state = .ready
            errorMessage = nil
            return
        }

        if case .loadingModel = state {
            await waitForActiveLoad()
            if activeLoadedModelKind == kind && activeLLM != nil {
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

        if !FileManager.default.fileExists(atPath: path.path) {
            do {
                try await downloadModel(kind: kind, url: descriptor.url, to: path)
            } catch {
                // User-initiated cancellation should drop the row back to
                // "not downloaded" without surfacing a scary red error.
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

        state = .loadingModel(kind: kind)
        activeLLM = nil
        activeLoadedModelKind = nil

        let loadedModel = await Task.detached { () -> LLM? in
            guard let llm = LLM(from: path, maxTokenCount: descriptor.maxTokenCount) else {
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
        state = .ready
        errorMessage = nil
        debugLogger?(.model, "Local cleanup model ready: \(descriptor.displayName).")
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

            return FileManager.default.fileExists(atPath: modelPath(for: descriptor.fileName).path)
                ? descriptor.kind
                : nil
        })
    }

    private func downloadModel(kind: LocalCleanupModelKind, url urlString: String, to destination: URL) async throws {
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
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func model(for modelKind: LocalCleanupModelKind) -> LLM? {
        activeLoadedModelKind == modelKind ? activeLLM : nil
    }

    private func descriptor(for modelKind: LocalCleanupModelKind) -> CleanupModelDescriptor {
        Self.cleanupModels.first(where: { $0.kind == modelKind })!
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

        return FileManager.default.fileExists(atPath: modelPath(for: descriptor(for: modelKind).fileName).path)
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
