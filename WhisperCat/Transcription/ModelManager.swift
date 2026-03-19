import Foundation
import WhisperKit

/// Manages WhisperKit model lifecycle: download, load, and readiness state.
@MainActor
final class ModelManager: ObservableObject {
    /// The underlying WhisperKit instance, nil until successfully loaded.
    private(set) var whisperKit: WhisperKit?

    /// Current state of the model.
    @Published private(set) var state: ModelManagerState = .idle

    /// The model variant to use for transcription.
    let modelName: String

    /// Any error encountered during model setup.
    @Published private(set) var error: Error?

    /// Whether the model is loaded and ready for transcription.
    var isReady: Bool {
        state == .ready
    }

    init(modelName: String = "openai_whisper-small.en") {
        self.modelName = modelName
    }

    /// Loads the WhisperKit model. Downloads from Hugging Face if not cached.
    /// Call this once at app launch; subsequent calls are no-ops if already ready.
    func loadModel() async {
        guard state == .idle || state == .error else { return }

        state = .loading
        error = nil

        do {
            let config = WhisperKitConfig(
                model: modelName,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            let kit = try await WhisperKit(config)
            self.whisperKit = kit
            self.state = .ready
        } catch {
            self.error = error
            self.state = .error
        }
    }
}

/// Possible states for ModelManager.
enum ModelManagerState: Equatable {
    case idle
    case loading
    case ready
    case error
}
