import Foundation
import LLM

enum CleanupModelState: Equatable {
    case idle
    case downloading(progress: Double)
    case loadingModel
    case ready
    case error
}

protocol TextCleaningManaging: AnyObject {
    func clean(text: String, prompt: String?) async -> String?
}

enum LocalCleanupModelKind: Equatable {
    case fast
    case full
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

    private static let fastModelFileName = "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
    private static let fastModelURL = "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"

    private static let fullModelFileName = "Qwen2.5-3B-Instruct-Q4_K_M.gguf"
    private static let fullModelURL = "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"

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

    init(
        defaults: UserDefaults = .standard,
        localModelPolicy: LocalCleanupModelPolicy? = nil,
        fastModelAvailabilityOverride: Bool? = nil,
        fullModelAvailabilityOverride: Bool? = nil
    ) {
        self.defaults = defaults
        self.fastModelAvailabilityOverride = fastModelAvailabilityOverride
        self.fullModelAvailabilityOverride = fullModelAvailabilityOverride

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
        case .downloading(let progress):
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

        guard let llm = selectedModel(wordCount: wordCount, isQuestion: isQuestion) else {
            debugLogger?(
                .cleanup,
                "Skipped local cleanup because no usable model was ready for policy \(localModelPolicy.rawValue)."
            )
            return nil
        }

        let activePrompt = prompt ?? TextCleaner.defaultPrompt
        llm.template = Template.chatML(activePrompt)
        llm.history = []

        let start = Date()
        do {
            let result = try await withTimeout(seconds: Self.timeoutSeconds) {
                await llm.respond(to: text)
                return llm.output
            }
            let elapsed = Date().timeIntervalSince(start)
            let cleaned = result.trimmingCharacters(in: .whitespacesAndNewlines)
            debugLogger?(
                .cleanup,
                "Local cleanup finished in \(String(format: "%.2f", elapsed))s using \(llm === fastLLM ? "fast" : "full") model."
            )
            if cleaned.isEmpty || cleaned == "..." {
                return nil
            }
            return cleaned
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            debugLogger?(
                .cleanup,
                "Local cleanup failed after \(String(format: "%.2f", elapsed))s: \(error.localizedDescription)"
            )
            return nil
        }
    }

    func loadModel() async {
        guard state == .idle || state == .error else { return }

        errorMessage = nil
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        debugLogger?(.model, "Loading local cleanup models for policy \(localModelPolicy.rawValue).")

        // Download both models if needed
        let fastPath = modelPath(for: Self.fastModelFileName)
        let fullPath = modelPath(for: Self.fullModelFileName)

        let needsFast = !FileManager.default.fileExists(atPath: fastPath.path)
        let needsFull = !FileManager.default.fileExists(atPath: fullPath.path)

        if needsFast || needsFull {
            state = .downloading(progress: 0)
            do {
                if needsFast {
                    try await downloadModel(url: Self.fastModelURL, to: fastPath, progressOffset: 0, progressScale: needsFull ? 0.33 : 1.0)
                }
                if needsFull {
                    try await downloadModel(url: Self.fullModelURL, to: fullPath, progressOffset: needsFast ? 0.33 : 0, progressScale: needsFast ? 0.67 : 1.0)
                }
            } catch {
                self.errorMessage = "Failed to download cleanup model: \(error.localizedDescription)"
                self.state = .error
                debugLogger?(.model, self.errorMessage ?? "Failed to download cleanup model.")
                return
            }
        }

        state = .loadingModel

        // Load fast model first (smaller, quicker to load)
        let fast = await Task.detached { () -> LLM? in
            return LLM(from: fastPath, template: Template.chatML(TextCleaner.defaultPrompt), maxTokenCount: 2048)
        }.value

        if let fast = fast {
            fast.temp = 0.1
            fast.update = { (_: String?) in }
            fast.postprocess = { (_: String) in }
            self.fastLLM = fast
        }

        // Load full model
        let full = await Task.detached { () -> LLM? in
            return LLM(from: fullPath, template: Template.chatML(TextCleaner.defaultPrompt), maxTokenCount: 4096)
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

    private func downloadModel(url urlString: String, to destination: URL, progressOffset: Double, progressScale: Double) async throws {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.state = .downloading(progress: progressOffset + progress * progressScale)
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
