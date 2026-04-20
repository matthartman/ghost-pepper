import Foundation
import FluidAudio
import WhisperKit

/// Manages local speech model lifecycle: download, load, and readiness state.
@MainActor
final class ModelManager: ObservableObject {
    typealias ModelLoadOverride = @MainActor (SpeechModelDescriptor) async throws -> Void
    typealias RetryDelayOverride = @MainActor () async -> Void

    private(set) var whisperKit: WhisperKit?
    private var fluidAudioManager: AsrManager?
    private var sortformerModels: SortformerModels?
    /// Stored as `Any?` because `Qwen3AsrManager` is `@available(macOS 15, *)`
    /// and the app deploys to macOS 14. Cast at use sites under `#available`.
    private var qwen3AsrManagerStorage: Any?

    @Published private(set) var state: ModelManagerState = .idle
    @Published private(set) var downloadProgress: Double?
    private(set) var modelName: String
    @Published private(set) var error: Error?

    var debugLogger: ((DebugLogCategory, String) -> Void)?

    var isReady: Bool {
        state == .ready
    }

    static let availableModels = SpeechModelCatalog.availableModels
    private static let retryDelayNanoseconds: UInt64 = 500_000_000

    var cachedModelNames: Set<String> {
        Self.availableModels.reduce(into: Set<String>()) { names, model in
            if Self.modelIsCached(model) {
                names.insert(model.name)
            }
        }
    }

    private let modelLoadOverride: ModelLoadOverride?
    private let loadRetryDelayOverride: RetryDelayOverride?

    init(
        modelName: String = SpeechModelCatalog.defaultModelID,
        modelLoadOverride: ModelLoadOverride? = nil,
        loadRetryDelayOverride: RetryDelayOverride? = nil
    ) {
        self.modelName = modelName
        self.modelLoadOverride = modelLoadOverride
        self.loadRetryDelayOverride = loadRetryDelayOverride
    }

    func loadModel(name: String? = nil) async {
        let requestedName = name ?? modelName
        guard let requestedModel = SpeechModelCatalog.model(named: requestedName) else {
            let missingModelError = NSError(
                domain: "GhostPepper.ModelManager",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Unknown speech model \(requestedName)"]
            )
            error = missingModelError
            state = .error
            return
        }

        if requestedName != modelName && state == .ready {
            resetLoadedModels()
        } else if state == .ready {
            return
        }
        modelName = requestedName

        guard state == .idle || state == .error else { return }

        state = .loading
        error = nil
        debugLogger?(.model, "Loading speech model \(modelName).")

        do {
            do {
                try await loadRequestedModel(requestedModel)
            } catch {
                guard Self.isRetryableLoadError(error) else {
                    throw error
                }

                debugLogger?(.model, "Speech model \(modelName) load timed out. Retrying once.")
                clearLoadedModelInstances()
                await retryLoadDelay()
                try await loadRequestedModel(requestedModel)
            }
            self.state = .ready
            debugLogger?(.model, "Speech model \(modelName) loaded successfully.")
        } catch {
            self.error = error
            self.state = .error
            debugLogger?(.model, "Speech model \(modelName) failed to load: \(error.localizedDescription)")
        }
    }

    private func loadRequestedModel(_ requestedModel: SpeechModelDescriptor) async throws {
        if let modelLoadOverride {
            try await modelLoadOverride(requestedModel)
            return
        }

        switch requestedModel.backend {
        case .whisperKit:
            try await loadWhisperModel(named: requestedModel.name)
        case .fluidAudio:
            switch requestedModel.fluidAudioVariant {
            case .qwen3AsrInt8:
                if #available(macOS 15, iOS 18, *) {
                    try await loadQwen3AsrModel(requestedModel)
                } else {
                    throw NSError(
                        domain: "GhostPepper.ModelManager",
                        code: 501,
                        userInfo: [NSLocalizedDescriptionKey: "Qwen3-ASR requires macOS 15 or later."]
                    )
                }
            case .parakeetV3, .none:
                try await loadFluidAudioModel(requestedModel)
            }
        }
    }

    func transcribe(audioBuffer: [Float], language: String? = nil) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }
        guard let model = SpeechModelCatalog.model(named: modelName) else { return nil }

        do {
            switch model.backend {
            case .whisperKit:
                guard let whisperKit else { return nil }
                let decodeOptions: DecodingOptions? = language.flatMap { lang in
                    var opts = DecodingOptions()
                    opts.language = lang
                    return opts
                }
                let results: [TranscriptionResult] = try await whisperKit.transcribe(audioArray: audioBuffer, decodeOptions: decodeOptions)
                let text = results
                    .map(\.text)
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = SpeechTranscriber.removeArtifacts(from: text)
                return cleaned.isEmpty ? nil : cleaned
            case .fluidAudio:
                switch model.fluidAudioVariant {
                case .qwen3AsrInt8:
                    if #available(macOS 15, iOS 18, *) {
                        guard let manager = qwen3AsrManagerStorage as? Qwen3AsrManager else { return nil }
                        let text: String = try await manager.transcribe(
                            audioSamples: audioBuffer,
                            language: nil as String?
                        )
                        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return cleaned.isEmpty ? nil : cleaned
                    }
                    return nil
                case .parakeetV3, .none:
                    guard let fluidAudioManager else { return nil }
                    let result = try await fluidAudioManager.transcribe(audioBuffer, source: .microphone)
                    let cleaned = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return cleaned.isEmpty ? nil : cleaned
                }
            }
        } catch {
            debugLogger?(.model, "Speech transcription failed for \(modelName): \(error.localizedDescription)")
            return nil
        }
    }

    func makeRecordingSessionCoordinator() async -> RecordingSessionCoordinator? {
        guard let model = SpeechModelCatalog.model(named: modelName),
              model.supportsSpeakerFiltering,
              fluidAudioManager != nil else {
            return nil
        }

        do {
            let diarizerModels = try await loadSortformerModels()
            let diarizer = SortformerDiarizer()
            diarizer.initialize(models: diarizerModels)
            let session = FluidAudioSpeechSession { [weak self] audioBuffer in
                await self?.transcribe(audioBuffer: audioBuffer)
            }

            return RecordingSessionCoordinator(
                session: session,
                processAudioChunk: { samples in
                    do {
                        _ = try diarizer.process(samples: samples)
                    } catch {
                        self.debugLogger?(
                            .model,
                            "Speaker filtering diarization chunk failed: \(error.localizedDescription)"
                        )
                    }
                },
                finish: {
                    do {
                        try diarizer.finalizeSession()
                    } catch {
                        self.debugLogger?(
                            .model,
                            "Speaker filtering diarization finalization failed: \(error.localizedDescription)"
                        )
                        return []
                    }
                    let segments = diarizer.timeline.speakers.values
                        .flatMap { $0.finalizedSegments }
                    return Self.diarizationSpans(from: segments)
                },
                cleanup: {
                    diarizer.cleanup()
                }
            )
        } catch {
            debugLogger?(.model, "Speaker filtering diarizer failed to load: \(error.localizedDescription)")
            return nil
        }
    }

    private func loadWhisperModel(named modelName: String) async throws {
        let modelsDir = Self.whisperModelsDirectory
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let needsDownload = !Self.modelIsCached(SpeechModelCatalog.model(named: modelName)!)
        if needsDownload {
            _ = try await WhisperKit.download(
                variant: modelName,
                downloadBase: modelsDir
            ) { progress in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = progress.fractionCompleted
                }
            }
            downloadProgress = nil
        }

        let config = WhisperKitConfig(
            model: modelName,
            downloadBase: modelsDir,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        whisperKit = try await WhisperKit(config)
    }

    private func loadFluidAudioModel(_ model: SpeechModelDescriptor) async throws {
        guard let fluidAudioVariant = model.fluidAudioVariant else {
            throw NSError(
                domain: "GhostPepper.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Missing FluidAudio variant for \(model.name)"]
            )
        }

        let version: AsrModelVersion
        switch fluidAudioVariant {
        case .parakeetV3:
            version = .v3
        case .qwen3AsrInt8:
            // Routed via loadQwen3AsrModel; should never reach here.
            throw NSError(
                domain: "GhostPepper.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected variant for Parakeet loader"]
            )
        }

        let models = try await AsrModels.downloadAndLoad(version: version) { progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        downloadProgress = nil
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        fluidAudioManager = manager
    }

    @available(macOS 15, iOS 18, *)
    private func loadQwen3AsrModel(_ model: SpeechModelDescriptor) async throws {
        guard let fluidAudioVariant = model.fluidAudioVariant else {
            throw NSError(
                domain: "GhostPepper.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Missing FluidAudio variant for \(model.name)"]
            )
        }

        let qwenVariant: Qwen3AsrVariant
        switch fluidAudioVariant {
        case .qwen3AsrInt8: qwenVariant = .int8
        case .parakeetV3:
            throw NSError(
                domain: "GhostPepper.ModelManager",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected variant for Qwen3-ASR loader"]
            )
        }

        let directory = try await Qwen3AsrModels.download(variant: qwenVariant) { progress in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        downloadProgress = nil
        let manager = Qwen3AsrManager()
        try await manager.loadModels(from: directory)
        qwen3AsrManagerStorage = manager
    }

    private func resetLoadedModels() {
        clearLoadedModelInstances()
        state = .idle
    }

    private func clearLoadedModelInstances() {
        whisperKit = nil
        fluidAudioManager = nil
        sortformerModels = nil
        qwen3AsrManagerStorage = nil
        downloadProgress = nil
    }

    private func retryLoadDelay() async {
        if let loadRetryDelayOverride {
            await loadRetryDelayOverride()
            return
        }

        try? await Task.sleep(nanoseconds: Self.retryDelayNanoseconds)
    }

    private func loadSortformerModels() async throws -> SortformerModels {
        if let sortformerModels {
            return sortformerModels
        }

        let models = try await SortformerModels.loadFromHuggingFace(config: .default)
        sortformerModels = models
        return models
    }

    private static func diarizationSpans(from segments: [DiarizerSegment]) -> [DiarizationSummary.Span] {
        segments
            .map { segment in
                DiarizationSummary.Span(
                    speakerID: segment.speakerLabel,
                    startTime: TimeInterval(segment.startTime),
                    endTime: TimeInterval(segment.endTime)
                )
            }
            .sorted { lhs, rhs in
                if lhs.startTime != rhs.startTime {
                    return lhs.startTime < rhs.startTime
                }

                if lhs.endTime != rhs.endTime {
                    return lhs.endTime < rhs.endTime
                }

                return lhs.speakerID < rhs.speakerID
            }
    }

    private static func isRetryableLoadError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
            return true
        }

        if nsError.localizedDescription.localizedCaseInsensitiveContains("timed out") {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isRetryableLoadError(underlyingError) {
            return true
        }

        return false
    }

    func deleteCachedModel(_ model: SpeechModelDescriptor) {
        Self.removeCachedModelFiles(for: model)

        if model.name == modelName {
            clearLoadedModelInstances()
            state = .idle
            error = nil
            return
        }

        objectWillChange.send()
    }

    private static func removeCachedModelFiles(for model: SpeechModelDescriptor) {
        switch model.backend {
        case .whisperKit:
            let modelPath = model.cachePathComponents.reduce(whisperModelsRootDirectory) { partialURL, component in
                partialURL.appendingPathComponent(component, isDirectory: true)
            }
            try? FileManager.default.removeItem(at: modelPath)
        case .fluidAudio:
            guard let fluidAudioVariant = model.fluidAudioVariant else { return }
            switch fluidAudioVariant {
            case .parakeetV3:
                let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
                try? FileManager.default.removeItem(at: cacheDir)
            case .qwen3AsrInt8:
                break // Qwen3 cache cleanup handled by FluidAudio internally
            }
        }
    }

    private static func modelIsCached(_ model: SpeechModelDescriptor) -> Bool {
        switch model.backend {
        case .whisperKit:
            let modelPath = model.cachePathComponents.reduce(whisperModelsRootDirectory) { partialURL, component in
                partialURL.appendingPathComponent(component, isDirectory: true)
            }
            return FileManager.default.fileExists(atPath: modelPath.path)
        case .fluidAudio:
            guard let fluidAudioVariant = model.fluidAudioVariant else {
                return false
            }
            switch fluidAudioVariant {
            case .parakeetV3:
                return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v3), version: .v3)
            case .qwen3AsrInt8:
                if #available(macOS 15, iOS 18, *) {
                    return Qwen3AsrModels.modelsExist(at: Qwen3AsrModels.defaultCacheDirectory(variant: .int8))
                }
                return false
            }
        }
    }

    private static var whisperModelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/whisper-models", isDirectory: true)
    }

    private static var whisperModelsRootDirectory: URL {
        whisperModelsDirectory.appendingPathComponent("models", isDirectory: true)
    }
}

/// Possible states for ModelManager.
enum ModelManagerState: Equatable {
    case idle
    case loading
    case ready
    case error
}
