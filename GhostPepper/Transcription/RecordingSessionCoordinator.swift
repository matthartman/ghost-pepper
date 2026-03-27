import Foundation

final class RecordingSessionCoordinator {
    private let session: FluidAudioSpeechSession

    private(set) var filteredTranscript: String?

    init(session: FluidAudioSpeechSession) {
        self.session = session
    }

    func appendAudioChunk(_ samples: [Float]) {
        session.appendAudioChunk(samples)
    }

    func finish(spans: [DiarizationSummary.Span]) async -> DiarizationSummary {
        let result = await session.finalize(spans: spans)
        filteredTranscript = result.filteredTranscript
        return result.summary
    }
}
