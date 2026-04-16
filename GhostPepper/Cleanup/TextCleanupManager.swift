import Combine
import Foundation
import RunAnywhere
import LlamaCPPRuntime

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

#if DEBUG
let SHOW_LATENCY_BADGE = true
#else
let SHOW_LATENCY_BADGE = false
#endif

@MainActor
final class TextCleanupManager: ObservableObject, TextCleaningManaging {
    @Published private(set) var state: CleanupModelState = .idle
    @Published private(set) var errorMessage: String?
    @Published var selectedCleanupModelKind: LocalCleanupModelKind {
        didSet {
            defaults.set(selectedCleanupModelKind.rawValue, forKey: Self.selectedCleanupModelDefaultsKey)
        }
    }

    var debugLogger: ((DebugLogCategory, String) -> Void)?

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

    static let cleanupModels = [
        compactModel,
        recommendedFastModel,
        recommendedFullModel,
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

    private let defaults: UserDefaults
    private let cleanupModelAvailabilityOverrides: [LocalCleanupModelKind: Bool]
    private let probeExecutionOverride: CleanupModelProbeExecutionOverride?
    private let backendShutdownOverride: (() -> Void)?
    private let probeExecutionGate = CleanupProbeExecutionGate()

    private var registeredModelIDs: Set<LocalCleanupModelKind> = []
    private(set) var backendInitializationFailed = false

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

    func deleteCachedModel(kind: LocalCleanupModelKind) {
        Task {
            var didMutatePublishedState = false
            var deletionError: String?

            if activeLoadedModelKind == kind {
                try? await RunAnywhere.unloadModel()
                activeLoadedModelKind = nil
            }

            do {
                try await RunAnywhere.deleteStoredModel(kind.rawValue, framework: .llamaCpp)
            } catch let sdkError as SDKError where sdkError.code == .modelNotFound {
                debugLogger?(.model, "Cleanup model already absent from cache: \(kind.rawValue)")
            } catch {
                deletionError = "Failed to delete cached cleanup model: \(error.localizedDescription)"
                debugLogger?(.model, deletionError!)
            }

            if let deletionError {
                state = .error
                errorMessage = deletionError
                didMutatePublishedState = true
            } else {
                let nextState: CleanupModelState = activeLoadedModelKind == nil ? .idle : .ready
                if state != nextState {
                    state = nextState
                    didMutatePublishedState = true
                }

                if errorMessage != nil {
                    errorMessage = nil
                    didMutatePublishedState = true
                }
            }

            if didMutatePublishedState == false {
                objectWillChange.send()
            }
        }
    }

    func clean(text: String, prompt: String? = nil, modelKind: LocalCleanupModelKind? = nil) async throws -> String {
        let requestedModelKind = modelKind ?? selectedCleanupModelKind
        await loadModel(kind: requestedModelKind)

        guard activeLoadedModelKind == requestedModelKind else {
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

            guard activeLoadedModelKind == modelKind else {
                debugLogger?(
                    .cleanup,
                    "Skipped local cleanup probe because model \(modelKind) was not ready."
                )
                await probeExecutionGate.release()
                throw CleanupModelProbeError.modelUnavailable(modelKind)
            }

            let start = ContinuousClock.now
            do {
                let rawOutput = try await withTimeout(seconds: Self.timeoutSeconds) {
                    try await self.runInference(
                        text: text,
                        prompt: prompt,
                        modelKind: modelKind,
                        thinkingMode: thinkingMode
                    )
                }
                let elapsed = ContinuousClock.now - start
                let elapsedMs = Int(elapsed.components.seconds * 1000 + Int64(Double(elapsed.components.attoseconds) / 1e15))
                let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                debugLogger?(
                    .cleanup,
                    "Local cleanup finished in \(String(format: "%.2f", elapsedSeconds))s using \(descriptor(for: modelKind).displayName)."
                )
                if SHOW_LATENCY_BADGE {
                    print("[MetalRT] Cleanup: \(elapsedMs)ms (\(descriptor(for: modelKind).displayName))")
                }
                await probeExecutionGate.release()
                return CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: descriptor(for: modelKind).displayName,
                    rawOutput: rawOutput,
                    elapsed: elapsedSeconds
                )
            } catch {
                let elapsed = ContinuousClock.now - start
                let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                debugLogger?(
                    .cleanup,
                    "Local cleanup failed after \(String(format: "%.2f", elapsedSeconds))s: \(error.localizedDescription)"
                )
                await probeExecutionGate.release()
                throw error
            }
        } catch {
            throw error
        }
    }

    private func runInference(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind,
        thinkingMode: CleanupModelProbeThinkingMode
    ) async throws -> String {
        let desc = descriptor(for: modelKind)
        let activeSystemPrompt = systemPrompt(prompt: prompt, thinkingMode: thinkingMode)
        let streamResult = try await RunAnywhere.generateStream(
            text,
            options: LLMGenerationOptions(
                maxTokens: Int(desc.maxTokenCount),
                temperature: 0.1,
                systemPrompt: activeSystemPrompt
            )
        )

        var output = ""
        for try await token in streamResult.stream {
            output += token
        }
        return output
    }

    private func systemPrompt(prompt: String, thinkingMode: CleanupModelProbeThinkingMode) -> String {
        switch thinkingMode {
        case .enabled:
            return """
            \(prompt)

            Thinking mode is enabled for this probe run. You may include reasoning if needed.
            """
        case .none, .suppressed:
            return prompt
        }
    }

    func loadModel() async {
        await loadModel(kind: selectedCleanupModelKind)
    }

    func downloadMissingModels() async {
        if backendInitializationFailed {
            state = .error
            if errorMessage == nil {
                errorMessage = "Cleanup backend initialization failed."
            }
            return
        }

        guard state == .idle || state == .error || state == .ready else { return }

        errorMessage = nil

        for descriptor in Self.cleanupModels {
            registerIfNeeded(kind: descriptor.kind)
            do {
                try await ensureModelRegistration(kind: descriptor.kind)
            } catch {
                self.errorMessage = "Failed to register cleanup model: \(error.localizedDescription)"
                self.state = .error
                debugLogger?(.model, self.errorMessage ?? "Failed to register cleanup model.")
                return
            }

            if !RunAnywhere.isModelDownloaded(descriptor.kind.rawValue, framework: .llamaCpp) {
                do {
                    state = .downloading(kind: descriptor.kind, progress: 0)
                    let progressStream = try await RunAnywhere.downloadModel(descriptor.kind.rawValue)
                    for await progress in progressStream {
                        state = .downloading(kind: descriptor.kind, progress: progress.overallProgress)
                        if progress.stage == .completed { break }
                    }
                } catch {
                    self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                    self.state = .error
                    debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
                    return
                }
            }
        }

        let selectedDesc = descriptor(for: selectedCleanupModelKind)
        state = .loadingModel(kind: selectedCleanupModelKind)

        do {
            try await RunAnywhere.loadModel(selectedCleanupModelKind.rawValue)
            activeLoadedModelKind = selectedCleanupModelKind
            state = .ready
            errorMessage = nil
            debugLogger?(.model, "Local cleanup model ready: \(selectedDesc.displayName) [MetalRT].")
        } catch {
            do {
                state = .downloading(kind: selectedCleanupModelKind, progress: 0)
                let progressStream = try await RunAnywhere.downloadModel(selectedCleanupModelKind.rawValue)
                for await progress in progressStream {
                    state = .downloading(kind: selectedCleanupModelKind, progress: progress.overallProgress)
                    if progress.stage == .completed { break }
                }
                state = .loadingModel(kind: selectedCleanupModelKind)
                try await RunAnywhere.loadModel(selectedCleanupModelKind.rawValue)
                activeLoadedModelKind = selectedCleanupModelKind
                state = .ready
                errorMessage = nil
                debugLogger?(.model, "Local cleanup model ready: \(selectedDesc.displayName) [MetalRT].")
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
            }
        }
    }

    func loadModel(kind: LocalCleanupModelKind) async {
        if backendInitializationFailed {
            state = .error
            if errorMessage == nil {
                errorMessage = "Cleanup backend initialization failed."
            }
            return
        }

        if activeLoadedModelKind == kind {
            state = .ready
            errorMessage = nil
            return
        }

        if case .loadingModel = state {
            await waitForActiveLoad()
            if activeLoadedModelKind == kind {
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

        if let override = availabilityOverride(for: kind), override {
            activeLoadedModelKind = kind
            state = .ready
            errorMessage = nil
            return
        }

        errorMessage = nil
        let desc = descriptor(for: kind)
        debugLogger?(.model, "Loading local cleanup model \(desc.displayName).")

        registerIfNeeded(kind: kind)
        do {
            try await ensureModelRegistration(kind: kind)
        } catch {
            errorMessage = "Failed to register cleanup model: \(error.localizedDescription)"
            state = .error
            debugLogger?(.model, errorMessage ?? "Failed to register cleanup model.")
            return
        }

        let previouslyLoaded = activeLoadedModelKind

        state = .loadingModel(kind: kind)
        activeLoadedModelKind = nil

        do {
            if previouslyLoaded != nil {
                try await RunAnywhere.unloadModel()
            }

            try await RunAnywhere.loadModel(kind.rawValue)
            activeLoadedModelKind = kind
            state = .ready
            errorMessage = nil
            debugLogger?(.model, "Local cleanup model ready: \(desc.displayName) [MetalRT].")
        } catch {
            do {
                debugLogger?(.model, "Model not cached, downloading \(desc.displayName)...")
                state = .downloading(kind: kind, progress: 0)
                let progressStream = try await RunAnywhere.downloadModel(kind.rawValue)
                for await progress in progressStream {
                    state = .downloading(kind: kind, progress: progress.overallProgress)
                    if progress.stage == .completed { break }
                }
                state = .loadingModel(kind: kind)
                try await RunAnywhere.loadModel(kind.rawValue)
                activeLoadedModelKind = kind
                state = .ready
                errorMessage = nil
                debugLogger?(.model, "Local cleanup model ready: \(desc.displayName) [MetalRT].")
            } catch {
                errorMessage = "Failed to load the selected cleanup model: \(error.localizedDescription)"
                state = .error
                debugLogger?(.model, "Failed to load model via RunAnywhere: \(error.localizedDescription)")
            }
        }
    }

    func unloadModel() async {
        if activeLoadedModelKind != nil {
            try? await RunAnywhere.unloadModel()
        }
        activeLoadedModelKind = nil
        state = .idle
        errorMessage = nil
        debugLogger?(.model, "Unloaded local cleanup models.")
    }

    func shutdownBackend() {
        Task { await unloadModel() }
        if let backendShutdownOverride {
            backendShutdownOverride()
        }
        debugLogger?(.model, "Shutdown MetalRT backend.")
    }

    func markBackendInitializationFailure(_ message: String) {
        backendInitializationFailed = true
        activeLoadedModelKind = nil
        state = .error
        errorMessage = message
        debugLogger?(.model, message)
    }

    var cachedModelKinds: Set<LocalCleanupModelKind> {
        Set(Self.cleanupModels.compactMap { descriptor in
            if let override = availabilityOverride(for: descriptor.kind) {
                return override ? descriptor.kind : nil
            }

            return RunAnywhere.isModelDownloaded(descriptor.kind.rawValue, framework: .llamaCpp)
                ? descriptor.kind
                : nil
        })
    }

    private func registerIfNeeded(kind: LocalCleanupModelKind) {
        guard !registeredModelIDs.contains(kind) else { return }
        let desc = descriptor(for: kind)
        RunAnywhere.registerModel(
            id: kind.rawValue,
            name: desc.displayName,
            url: URL(string: desc.url)!,
            framework: .llamaCpp,
            memoryRequirement: estimateMemoryRequirement(for: kind),
            supportsThinking: true
        )
        registeredModelIDs.insert(kind)
    }

    private func ensureModelRegistration(kind: LocalCleanupModelKind) async throws {
        for _ in 0..<50 {
            if let models = try? await RunAnywhere.availableModels(),
               models.contains(where: { $0.id == kind.rawValue }) {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        throw NSError(
            domain: "TextCleanupManager",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out while registering cleanup model \(kind.rawValue)."]
        )
    }

    private func descriptor(for modelKind: LocalCleanupModelKind) -> CleanupModelDescriptor {
        Self.cleanupModels.first(where: { $0.kind == modelKind })!
    }

    private func estimateMemoryRequirement(for kind: LocalCleanupModelKind) -> Int64 {
        switch kind {
        case .qwen35_0_8b_q4_k_m: return 600_000_000
        case .qwen35_2b_q4_k_m: return 1_500_000_000
        case .qwen35_4b_q4_k_m: return 2_800_000_000
        }
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

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func isModelAvailable(_ modelKind: LocalCleanupModelKind) -> Bool {
        if let override = availabilityOverride(for: modelKind) {
            return override
        }

        if activeLoadedModelKind == modelKind {
            return true
        }

        return RunAnywhere.isModelDownloaded(modelKind.rawValue, framework: .llamaCpp)
    }
}
