import Foundation

/// A transcribed segment from one audio stream chunk.
struct ChunkedTranscriptResult {
    let source: AudioStreamSource
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

/// Accumulates audio from DualStreamCapture in per-stream buffers, drains them
/// every `chunkInterval` seconds, transcribes each chunk, and emits results.
///
/// Memory-efficient: after transcription, chunk audio is written to disk and
/// released from memory. Only one chunk pair (~3.7 MB) lives in RAM at a time.
final class ChunkedTranscriptionPipeline {
    /// Called on the main queue when a new transcript segment is available.
    var onSegmentTranscribed: ((ChunkedTranscriptResult) -> Void)?

    /// Called when chunk audio is saved to disk (for optional post-meeting diarization).
    var onChunkSaved: ((URL, AudioStreamSource) -> Void)?

    private let transcriber: SpeechTranscriber
    private let chunkInterval: TimeInterval
    private let overlapDuration: TimeInterval = 1.0 // 1 second overlap for dedup

    private let bufferLock = NSLock()
    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []

    private var chunkTimer: Timer?
    private var chunkIndex: Int = 0
    private var sessionStartTime: Date?
    private var isRunning = false

    private var previousMicTail: String = ""
    private var previousSystemTail: String = ""

    /// Serial queue for transcription tasks to prevent race conditions on tail state.
    private let transcriptionQueue = DispatchQueue(label: "com.whispercat.chunked-transcription", qos: .userInitiated)
    private let transcriptionSemaphore = DispatchSemaphore(value: 1)

    /// Directory for saving chunk WAV files.
    private let chunkDirectory: URL

    private let sampleRate: Double = 16000

    init(transcriber: SpeechTranscriber, chunkDirectory: URL, chunkInterval: TimeInterval = 30.0) {
        self.transcriber = transcriber
        self.chunkDirectory = chunkDirectory
        self.chunkInterval = chunkInterval
    }

    /// Start the chunked pipeline. Call this after DualStreamCapture.start().
    func start() {
        guard !isRunning else { return }
        isRunning = true
        sessionStartTime = Date()
        chunkIndex = 0
        previousMicTail = ""
        previousSystemTail = ""

        // Create chunk directory.
        try? FileManager.default.createDirectory(at: chunkDirectory, withIntermediateDirectories: true)

        // Schedule chunk draining on the main run loop.
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkInterval, repeats: true) { [weak self] _ in
            self?.drainAndTranscribe()
        }
    }

    /// Stop the pipeline and process any remaining audio.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        chunkTimer?.invalidate()
        chunkTimer = nil

        // Process final partial chunk.
        drainAndTranscribe()
    }

    /// Cancels the pipeline without draining buffered audio.
    func cancel() {
        guard isRunning else { return }
        isRunning = false
        chunkTimer?.invalidate()
        chunkTimer = nil

        bufferLock.lock()
        micBuffer = []
        systemBuffer = []
        bufferLock.unlock()
    }

    /// Feed audio chunks from DualStreamCapture into the pipeline.
    func appendAudio(_ chunk: TaggedAudioChunk) {
        bufferLock.lock()
        switch chunk.source {
        case .mic:
            micBuffer.append(contentsOf: chunk.samples)
        case .system:
            systemBuffer.append(contentsOf: chunk.samples)
        }
        bufferLock.unlock()
    }

    // MARK: - Private

    private func drainAndTranscribe() {
        bufferLock.lock()
        let micSamples = micBuffer
        let systemSamples = systemBuffer
        micBuffer = []
        systemBuffer = []
        bufferLock.unlock()

        guard !micSamples.isEmpty || !systemSamples.isEmpty else { return }

        let currentChunkIndex = chunkIndex
        let startTime = TimeInterval(currentChunkIndex) * chunkInterval
        let endTime = startTime + chunkInterval
        chunkIndex += 1

        // Serialize transcription to prevent races on previousMicTail/previousSystemTail.
        transcriptionQueue.async { [weak self, transcriptionSemaphore] in
            transcriptionSemaphore.wait()
            let task = Task { [weak self] in
                guard let self = self else { return }
                defer { transcriptionSemaphore.signal() }

                if !micSamples.isEmpty {
                    await self.processChunk(
                        samples: micSamples,
                        source: .mic,
                        startTime: startTime,
                        endTime: endTime,
                        chunkIndex: currentChunkIndex,
                        previousTail: self.previousMicTail,
                        updateTail: { [weak self] tail in self?.previousMicTail = tail }
                    )
                }

                if !systemSamples.isEmpty {
                    await self.processChunk(
                        samples: systemSamples,
                        source: .system,
                        startTime: startTime,
                        endTime: endTime,
                        chunkIndex: currentChunkIndex,
                        previousTail: self.previousSystemTail,
                        updateTail: { [weak self] tail in self?.previousSystemTail = tail }
                    )
                }
            }
            _ = task
        }
    }

    private func processChunk(
        samples: [Float],
        source: AudioStreamSource,
        startTime: TimeInterval,
        endTime: TimeInterval,
        chunkIndex: Int,
        previousTail: String,
        updateTail: @escaping (String) -> Void
    ) async {
        // Save chunk audio to disk for crash resilience and optional post-meeting diarization.
        let sourceLabel = source == .mic ? "mic" : "system"
        let chunkFile = chunkDirectory.appendingPathComponent("chunk-\(chunkIndex)-\(sourceLabel).wav")
        if let wavData = try? AudioRecorder.serializePlayableArchiveAudioBuffer(samples) {
            try? wavData.write(to: chunkFile)
            onChunkSaved?(chunkFile, source)
        }

        // Transcribe the chunk.
        guard let rawText = await transcriber.transcribe(audioBuffer: samples) else { return }
        let cleaned = SpeechTranscriber.removeArtifacts(from: rawText)
        guard !cleaned.isEmpty else { return }

        // Deduplicate overlap with previous chunk.
        let deduped = deduplicateOverlap(previous: previousTail, current: cleaned)
        guard !deduped.isEmpty else { return }

        // Update tail for next chunk's dedup.
        let words = deduped.split(separator: " ")
        let tail = words.suffix(10).joined(separator: " ")
        updateTail(tail)

        let result = ChunkedTranscriptResult(
            source: source,
            startTime: startTime,
            endTime: endTime,
            text: deduped
        )

        await MainActor.run {
            onSegmentTranscribed?(result)
        }
    }

    /// Remove overlapping text between the tail of the previous chunk and the head of the current chunk.
    private func deduplicateOverlap(previous: String, current: String) -> String {
        guard !previous.isEmpty else { return current }

        let prevWords = previous.lowercased().split(separator: " ")
        let currWords = current.split(separator: " ")
        let currWordsLower = currWords.map { $0.lowercased() }

        // Try matching the last N words of previous with the first N words of current.
        let maxOverlap = min(prevWords.count, currWordsLower.count, 8)

        for overlapLen in stride(from: maxOverlap, through: 2, by: -1) {
            let prevTail = prevWords.suffix(overlapLen)
            let currHead = currWordsLower.prefix(overlapLen)

            if Array(prevTail) == Array(currHead).map({ Substring($0) }) {
                // Found overlap — remove the duplicate head from current.
                let remaining = currWords.dropFirst(overlapLen)
                return remaining.joined(separator: " ")
            }
        }

        return current
    }
}
