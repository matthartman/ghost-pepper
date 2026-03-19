import Foundation
@preconcurrency import WhisperKit

/// Transcribes audio buffers using WhisperKit.
///
/// Serializes transcription requests so only one runs at a time.
/// Requires a `ModelManager` whose model is loaded before calling `transcribe`.
final class WhisperTranscriber {
    private let modelManager: ModelManager
    private let serialQueue = DispatchQueue(label: "com.whispercat.transcriber", qos: .userInitiated)
    private let semaphore = DispatchSemaphore(value: 1)

    /// Whether the underlying model is ready for transcription.
    @MainActor
    var isReady: Bool {
        modelManager.isReady
    }

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    /// Transcribes a 16 kHz mono PCM float audio buffer into text.
    ///
    /// - Parameter audioBuffer: Array of Float samples at 16 kHz sample rate, mono.
    /// - Returns: The transcribed text, or nil if the buffer is empty,
    ///   the model is not ready, or transcription produced no output.
    func transcribe(audioBuffer: [Float]) async -> String? {
        guard !audioBuffer.isEmpty else { return nil }

        let kit: WhisperKit? = await MainActor.run { modelManager.whisperKit }
        guard let whisperKit = kit else { return nil }

        // Serialize concurrent transcription requests
        return await withCheckedContinuation { continuation in
            serialQueue.async { [semaphore] in
                semaphore.wait()
                let task = Task {
                    defer { semaphore.signal() }
                    do {
                        let results: [TranscriptionResult] = try await whisperKit.transcribe(
                            audioArray: audioBuffer
                        )
                        let text = results
                            .map { $0.text }
                            .joined(separator: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : text
                    } catch {
                        return nil as String?
                    }
                }
                let result = Task {
                    await task.value
                }
                Task {
                    let value = await result.value
                    continuation.resume(returning: value)
                }
            }
        }
    }
}
