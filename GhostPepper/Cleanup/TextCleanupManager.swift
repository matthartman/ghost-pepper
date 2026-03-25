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
    case loadingModel
    case ready
    case error
}

protocol TextCleaningManaging: AnyObject {
    func clean(text: String, prompt: String?) async -> String?
}

typealias CleanupModelProbeExecutionOverride = @MainActor (
    _ text: String,
    _ prompt: String,
    _ modelKind: LocalCleanupModelKind,
    _ thinkingMode: CleanupModelProbeThinkingMode
) async throws -> CleanupModelProbeRawResult

enum LocalCleanupModelKind: Equatable {
    case fast
    case full
}

struct CleanupModelDescriptor: Equatable {
    let kind: LocalCleanupModelKind
    let displayName: String
    let sizeDescription: String
    let fileName: String
    let url: String
    let maxTokenCount: Int32
}

@MainActor
final class TextCleanupManager: ObservableObject, TextCleaningManaging {
    @Published private(set) var state: CleanupModelState = .idle
    @Published private(set) var errorMessage: String?
    @Published var localModelPolicy: LocalCleanupModelPolicy {
        didSet {
            defaults.set(localModelPolicy.rawValue, forKey: Self.localModelPolicyDefaultsKey)
            updateReadyStateForCurrentPolicy()
        }
    }

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    /// Fast model for short inputs (< 15 words)
    private(set) var fastLLM: LLM?
    /// Full model for longer inputs
    private(set) var fullLLM: LLM?

    static let fastModel = CleanupModelDescriptor(
        kind: .fast,
        displayName: "Qwen 3 1.7B (fast cleanup)",
        sizeDescription: "~1 GB",
        fileName: "Qwen3-1.7B.Q4_K_M.gguf",
        url: "https://huggingface.co/MaziyarPanahi/Qwen3-1.7B-GGUF/resolve/main/Qwen3-1.7B.Q4_K_M.gguf",
        maxTokenCount: 2048
    )

    static let fullModel = CleanupModelDescriptor(
        kind: .full,
        displayName: "Qwen 3.5 4B (full cleanup)",
        sizeDescription: "~2.5 GB",
        fileName: "Qwen3.5-4B-Q4_K_M.gguf",
        url: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf",
        maxTokenCount: 4096
    )

    static let cleanupModels = [fastModel, fullModel]

    static let shortInputThreshold = 15

    var isReady: Bool { state == .ready }
    var hasUsableModelForCurrentPolicy: Bool {
        switch localModelPolicy {
        case .automatic:
            return hasFastModel || hasFullModel
        case .fastOnly:
            return hasFastModel
        case .fullOnly:
            return hasFullModel
        }
    }

    private static let timeoutSeconds: TimeInterval = 15.0
    private static let localModelPolicyDefaultsKey = "cleanupLocalModelPolicy"

    private let defaults: UserDefaults
    private let fastModelAvailabilityOverride: Bool?
    private let fullModelAvailabilityOverride: Bool?
    private let probeExecutionOverride: CleanupModelProbeExecutionOverride?
    private let backendShutdownOverride: (() -> Void)?

    init(
        defaults: UserDefaults = .standard,
        localModelPolicy: LocalCleanupModelPolicy? = nil,
        fastModelAvailabilityOverride: Bool? = nil,
        fullModelAvailabilityOverride: Bool? = nil,
        probeExecutionOverride: CleanupModelProbeExecutionOverride? = nil,
        backendShutdownOverride: (() -> Void)? = nil
    ) {
        self.defaults = defaults
        self.fastModelAvailabilityOverride = fastModelAvailabilityOverride
        self.fullModelAvailabilityOverride = fullModelAvailabilityOverride
        self.probeExecutionOverride = probeExecutionOverride
        self.backendShutdownOverride = backendShutdownOverride

        let storedPolicy = LocalCleanupModelPolicy(
            rawValue: defaults.string(forKey: Self.localModelPolicyDefaultsKey) ?? ""
        ) ?? .automatic
        let initialPolicy = localModelPolicy ?? storedPolicy
        self.localModelPolicy = initialPolicy
        defaults.set(initialPolicy.rawValue, forKey: Self.localModelPolicyDefaultsKey)
    }

    func selectedModelKind(wordCount: Int, isQuestion: Bool) -> LocalCleanupModelKind? {
        switch localModelPolicy {
        case .automatic:
            if isQuestion || wordCount > Self.shortInputThreshold {
                if hasFullModel {
                    return .full
                }
                if hasFastModel {
                    return .fast
                }
                return nil
            }

            if hasFastModel {
                return .fast
            }
            if hasFullModel {
                return .full
            }
            return nil
        case .fastOnly:
            return hasFastModel ? .fast : nil
        case .fullOnly:
            return hasFullModel ? .full : nil
        }
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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/models", isDirectory: true)
    }

    private func modelPath(for fileName: String) -> URL {
        modelsDirectory.appendingPathComponent(fileName)
    }

    func clean(text: String, prompt: String? = nil) async -> String? {
        let wordCount = text.split(separator: " ").count
        let isQuestion = text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")

        guard let modelKind = selectedModelKind(wordCount: wordCount, isQuestion: isQuestion) else {
            debugLogger?(
                .cleanup,
                "Skipped local cleanup because no usable model was ready for policy \(localModelPolicy.rawValue)."
            )
            return nil
        }

        let activePrompt = prompt ?? TextCleaner.defaultPrompt
        do {
            let result = try await probe(
                text: text,
                prompt: activePrompt,
                modelKind: modelKind,
                thinkingMode: .suppressed
            )
            let cleaned = result.rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == "..." {
                return nil
            }
            return cleaned
        } catch {
            return nil
        }
    }

    func probe(
        text: String,
        prompt: String,
        modelKind: LocalCleanupModelKind,
        thinkingMode: CleanupModelProbeThinkingMode
    ) async throws -> CleanupModelProbeRawResult {
        if let probeExecutionOverride {
            return try await probeExecutionOverride(text, prompt, modelKind, thinkingMode)
        }

        guard let llm = model(for: modelKind) else {
            debugLogger?(
                .cleanup,
                "Skipped local cleanup probe because model \(modelKind) was not ready."
            )
            throw CleanupModelProbeError.modelUnavailable(modelKind)
        }

        llm.useResolvedTemplate(systemPrompt: prompt)
        llm.history = []

        let start = Date()
        do {
            let rawOutput = try await withTimeout(seconds: Self.timeoutSeconds) {
                await llm.respond(to: text, thinking: thinkingMode.llmThinkingMode)
                return llm.output
            }
            let elapsed = Date().timeIntervalSince(start)
            debugLogger?(
                .cleanup,
                "Local cleanup finished in \(String(format: "%.2f", elapsed))s using \(modelKind == .fast ? "fast" : "full") model."
            )
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
            throw error
        }
    }

    func loadModel() async {
        guard state == .idle || state == .error else { return }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        debugLogger?(.model, "Loading local cleanup models for policy \(localModelPolicy.rawValue).")

        // Download both models if needed
        let fastPath = modelPath(for: Self.fastModel.fileName)
        let fullPath = modelPath(for: Self.fullModel.fileName)

        let needsFast = !FileManager.default.fileExists(atPath: fastPath.path)
        let needsFull = !FileManager.default.fileExists(atPath: fullPath.path)

        if needsFast || needsFull {
            do {
                if needsFast {
                    try await downloadModel(
                        kind: .fast,
                        url: Self.fastModel.url,
                        to: fastPath
                    )
                }
                if needsFull {
                    try await downloadModel(
                        kind: .full,
                        url: Self.fullModel.url,
                        to: fullPath
                    )
                }
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
                return
            }
        }

        state = .loadingModel

        let fastModel = Self.fastModel
        let fullModel = Self.fullModel

        // Load fast model first (smaller, quicker to load)
        let fast = await Task.detached { () -> LLM? in
            guard let llm = LLM(from: fastPath, maxTokenCount: fastModel.maxTokenCount) else {
                return nil
            }
            llm.useResolvedTemplate(systemPrompt: TextCleaner.defaultPrompt)
            return llm
        }.value

        if let fast = fast {
            fast.temp = 0.1
            fast.update = { (_: String?) in }
            fast.postprocess = { (_: String) in }
            self.fastLLM = fast
        }

        // Load full model
        let full = await Task.detached { () -> LLM? in
            guard let llm = LLM(from: fullPath, maxTokenCount: fullModel.maxTokenCount) else {
                return nil
            }
            llm.useResolvedTemplate(systemPrompt: TextCleaner.defaultPrompt)
            return llm
        }.value

        if let full = full {
            full.temp = 0.1
            full.update = { (_: String?) in }
            full.postprocess = { (_: String) in }
            self.fullLLM = full
        }
        updateReadyStateForCurrentPolicy()
    }

    func unloadModel() {
        fastLLM = nil
        fullLLM = nil
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

    var loadedModelKinds: Set<LocalCleanupModelKind> {
        var kinds = Set<LocalCleanupModelKind>()
        if fastLLM != nil {
            kinds.insert(.fast)
        }
        if fullLLM != nil {
            kinds.insert(.full)
        }
        return kinds
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

    private var hasFastModel: Bool {
        fastModelAvailabilityOverride ?? (fastLLM != nil)
    }

    private var hasFullModel: Bool {
        fullModelAvailabilityOverride ?? (fullLLM != nil)
    }

    private func selectedModel(wordCount: Int, isQuestion: Bool) -> LLM? {
        switch selectedModelKind(wordCount: wordCount, isQuestion: isQuestion) {
        case .fast:
            return fastLLM
        case .full:
            return fullLLM
        case nil:
            return nil
        }
    }

    private func model(for modelKind: LocalCleanupModelKind) -> LLM? {
        switch modelKind {
        case .fast:
            return fastLLM
        case .full:
            return fullLLM
        }
    }

    private func descriptor(for modelKind: LocalCleanupModelKind) -> CleanupModelDescriptor {
        switch modelKind {
        case .fast:
            return Self.fastModel
        case .full:
            return Self.fullModel
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

    private func updateReadyStateForCurrentPolicy() {
        if hasUsableModelForCurrentPolicy {
            state = .ready
            errorMessage = nil
            debugLogger?(
                .model,
                "Local cleanup models ready. fastLoaded=\(hasFastModel) fullLoaded=\(hasFullModel) policy=\(localModelPolicy.rawValue)."
            )
            return
        }

        guard fastLLM != nil || fullLLM != nil || state == .loadingModel else {
            return
        }

        errorMessage = "Failed to load the selected cleanup model."
        state = .error
        debugLogger?(
            .model,
            "Local cleanup models unavailable for policy \(localModelPolicy.rawValue). fastLoaded=\(hasFastModel) fullLoaded=\(hasFullModel)."
        )
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
