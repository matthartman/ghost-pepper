import Foundation

/// Identifies the source of an audio chunk in dual-stream capture.
enum AudioStreamSource {
    case mic
    case system
}

/// A timestamped audio chunk from one of the two capture streams.
struct TaggedAudioChunk {
    let source: AudioStreamSource
    let samples: [Float]
    let timestamp: TimeInterval // seconds since capture start
}

/// Coordinates simultaneous mic + system audio capture for meeting transcription.
/// Mic audio = "Me", system audio = "Others" — provides free basic diarization.
final class DualStreamCapture {
    var onAudioChunk: ((TaggedAudioChunk) -> Void)?

    private let micRecorder = AudioRecorder()
    private let systemRecorder = SystemAudioRecorder()
    private var startTime: Date?
    private var isActive = false

    /// Starts both mic and system audio capture simultaneously.
    func start() async throws {
        guard !isActive else { return }

        startTime = Date()
        isActive = true

        micRecorder.onConvertedAudioChunk = { [weak self] samples in
            guard let self = self, let start = self.startTime else { return }
            let chunk = TaggedAudioChunk(
                source: .mic,
                samples: samples,
                timestamp: Date().timeIntervalSince(start)
            )
            self.onAudioChunk?(chunk)
        }

        systemRecorder.onConvertedAudioChunk = { [weak self] samples in
            guard let self = self, let start = self.startTime else { return }
            let chunk = TaggedAudioChunk(
                source: .system,
                samples: samples,
                timestamp: Date().timeIntervalSince(start)
            )
            self.onAudioChunk?(chunk)
        }

        // Start both recorders. Mic uses AVAudioEngine, system uses ScreenCaptureKit.
        try micRecorder.startRecording()
        try await systemRecorder.startRecording()
    }

    /// Stops both capture streams and returns the full buffers.
    func stop() async -> (micBuffer: [Float], systemBuffer: [Float]) {
        guard isActive else { return ([], []) }
        isActive = false

        let micBuffer = await micRecorder.stopRecording()
        let systemBuffer = await systemRecorder.stopRecording()

        micRecorder.onConvertedAudioChunk = nil
        systemRecorder.onConvertedAudioChunk = nil
        startTime = nil

        return (micBuffer, systemBuffer)
    }

    /// Cancels both streams without waiting for buffered audio to flush.
    func cancelImmediately() {
        guard isActive else { return }
        isActive = false

        micRecorder.cancelRecordingImmediately()
        systemRecorder.cancelRecordingImmediately()
        micRecorder.onConvertedAudioChunk = nil
        systemRecorder.onConvertedAudioChunk = nil
        startTime = nil
    }

    /// Whether dual-stream capture is currently active.
    var capturing: Bool { isActive }

    /// Elapsed time since capture started, or 0 if not active.
    var elapsed: TimeInterval {
        guard let start = startTime else { return 0 }
        return Date().timeIntervalSince(start)
    }
}
