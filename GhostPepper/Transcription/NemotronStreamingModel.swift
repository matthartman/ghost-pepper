import Foundation
import MLXAudioSTT

protocol NemotronStreamingModel: AnyObject {
    func makeSession(language: String?) -> RecordingTranscriptionSession
}

final class MLXNemotronStreamingModel: NemotronStreamingModel {
    private let model: NemotronASRModel

    init(model: NemotronASRModel) {
        self.model = model
    }

    static func load(repository: String) async throws -> MLXNemotronStreamingModel {
        let model = try await NemotronASRModel.fromPretrained(repository)
        return MLXNemotronStreamingModel(model: model)
    }

    func makeSession(language: String?) -> RecordingTranscriptionSession {
        NemotronRecordingTranscriptionSession(
            backend: MLXNemotronStreamSessionBackend(
                session: model.makeStreamSession(language: language, chunkMs: 1120)
            )
        )
    }
}

private final class MLXNemotronStreamSessionBackend: NemotronStreamSessionBackend {
    private let session: NemotronASRStreamSession

    init(session: NemotronASRStreamSession) {
        self.session = session
    }

    func step(_ samples: [Float]) {
        session.step(samples)
    }

    func finish() -> String {
        session.finish()
        return session.text
    }
}
