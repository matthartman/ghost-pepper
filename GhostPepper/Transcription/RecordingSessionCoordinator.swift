import Foundation

protocol RecordingTranscriptionSession: AnyObject {
    func appendAudioChunk(_ samples: [Float])
    func finishTranscription() async -> String?
    func cancel()
}

final class ChunkedRecordingTranscriptionSession: RecordingTranscriptionSession, @unchecked Sendable {
    private let chunkSizeSamples: Int
    private let shiftSamples: Int
    private let transcribeChunk: @Sendable ([Float]) async -> String?
    private let stateQueue = DispatchQueue(
        label: "GhostPepper.ChunkedRecordingTranscriptionSession.state"
    )
    private let group = DispatchGroup()
    private let tailWordCount = 10

    private var bufferedSamples: [Float] = []
    private var previousTail = ""
    private var transcriptSegments: [String] = []
    private var pendingChunkTranscripts: [Int: String] = [:]
    private var nextEnqueuedChunkIndex = 0
    private var nextTranscriptChunkIndex = 0
    private var isCancelled = false
    private var isFinishing = false

    init(
        chunkSizeSamples: Int = 17_920,
        shiftSamples: Int = 8_960,
        transcribeChunk: @escaping @Sendable ([Float]) async -> String?
    ) {
        self.chunkSizeSamples = chunkSizeSamples
        self.shiftSamples = shiftSamples
        self.transcribeChunk = transcribeChunk
    }

    func appendAudioChunk(_ samples: [Float]) {
        guard samples.isEmpty == false else {
            return
        }

        let chunks = stateQueue.sync { () -> [[Float]] in
            guard isCancelled == false, isFinishing == false else {
                return []
            }

            bufferedSamples.append(contentsOf: samples)
            return drainReadyChunks()
        }

        chunks.forEach(enqueueChunk)
    }

    func finishTranscription() async -> String? {
        let finalChunk = stateQueue.sync { () -> [Float]? in
            guard isCancelled == false else {
                return nil
            }

            isFinishing = true
            guard bufferedSamples.isEmpty == false else {
                return nil
            }

            let chunk = bufferedSamples
            bufferedSamples = []
            return chunk
        }

        if let finalChunk {
            enqueueChunk(finalChunk)
        }

        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [group] in
                group.wait()
                continuation.resume()
            }
        }

        return stateQueue.sync {
            guard isCancelled == false else {
                return nil
            }

            let transcript = transcriptSegments.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return transcript.isEmpty ? nil : transcript
        }
    }

    func cancel() {
        stateQueue.sync {
            isCancelled = true
            isFinishing = true
            bufferedSamples = []
            transcriptSegments = []
            pendingChunkTranscripts = [:]
            nextEnqueuedChunkIndex = 0
            nextTranscriptChunkIndex = 0
            previousTail = ""
        }
    }

    private func drainReadyChunks() -> [[Float]] {
        var drainedChunks: [[Float]] = []

        while bufferedSamples.count >= chunkSizeSamples {
            drainedChunks.append(Array(bufferedSamples.prefix(chunkSizeSamples)))
            let samplesToRemove = min(shiftSamples, bufferedSamples.count)
            bufferedSamples.removeFirst(samplesToRemove)
        }

        return drainedChunks
    }

    private func enqueueChunk(_ chunk: [Float]) {
        let chunkIndex = stateQueue.sync { () -> Int in
            let chunkIndex = nextEnqueuedChunkIndex
            nextEnqueuedChunkIndex += 1
            return chunkIndex
        }
        group.enter()

        Task {
            let transcript = await transcribeChunk(chunk)
            stateQueue.async {
                defer { self.group.leave() }
                self.storeCompletedTranscript(transcript, for: chunkIndex)
            }
        }
    }

    private func storeCompletedTranscript(_ transcript: String?, for chunkIndex: Int) {
        guard isCancelled == false else {
            return
        }

        pendingChunkTranscripts[chunkIndex] = transcript?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        flushCompletedTranscripts()
    }

    private func flushCompletedTranscripts() {
        while let cleaned = pendingChunkTranscripts.removeValue(forKey: nextTranscriptChunkIndex) {
            nextTranscriptChunkIndex += 1

            guard cleaned.isEmpty == false else {
                continue
            }

            let deduplicated = deduplicateOverlap(previous: previousTail, current: cleaned)
            guard deduplicated.isEmpty == false else {
                continue
            }

            transcriptSegments.append(deduplicated)
            previousTail = deduplicated
                .split(separator: " ")
                .suffix(tailWordCount)
                .joined(separator: " ")
        }
    }

    private func deduplicateOverlap(previous: String, current: String) -> String {
        guard previous.isEmpty == false else {
            return current
        }

        let previousWords = previous.lowercased().split(separator: " ")
        let currentWords = current.split(separator: " ")
        let currentWordsLower = currentWords.map { $0.lowercased() }
        let maxOverlap = min(previousWords.count, currentWordsLower.count, 8)

        for overlapLength in stride(from: maxOverlap, through: 1, by: -1) {
            let previousTail = previousWords.suffix(overlapLength)
            let currentHead = currentWordsLower.prefix(overlapLength)

            if Array(previousTail) == Array(currentHead).map({ Substring($0) }) {
                return currentWords.dropFirst(overlapLength).joined(separator: " ")
            }
        }

        return current
    }
}

final class RecordingSessionCoordinator {
    typealias FinalizationResult = (filteredTranscript: String?, summary: DiarizationSummary)

    private let appendAudioChunkHandler: ([Float]) -> Void
    private let finishHandler: (() async -> FinalizationResult)?
    private let finishWithSpansHandler: (([DiarizationSummary.Span]) async -> FinalizationResult)?

    private(set) var filteredTranscript: String?

    init(session: FluidAudioSpeechSession) {
        appendAudioChunkHandler = session.appendAudioChunk
        finishHandler = nil
        finishWithSpansHandler = { spans in
            let result = await session.finalize(spans: spans)
            return (filteredTranscript: result.filteredTranscript, summary: result.summary)
        }
    }

    init(
        session: FluidAudioSpeechSession,
        processAudioChunk: @escaping ([Float]) -> Void,
        finish: @escaping () -> [DiarizationSummary.Span],
        cleanup: @escaping () -> Void = {}
    ) {
        appendAudioChunkHandler = { samples in
            session.appendAudioChunk(samples)
            processAudioChunk(samples)
        }
        finishHandler = {
            let result = await session.finalize(spans: finish())
            cleanup()
            return (filteredTranscript: result.filteredTranscript, summary: result.summary)
        }
        finishWithSpansHandler = nil
    }

    init(
        appendAudioChunk: @escaping ([Float]) -> Void,
        finish: @escaping () async -> FinalizationResult
    ) {
        appendAudioChunkHandler = appendAudioChunk
        finishHandler = finish
        finishWithSpansHandler = nil
    }

    func appendAudioChunk(_ samples: [Float]) {
        appendAudioChunkHandler(samples)
    }

    func finish() async -> DiarizationSummary {
        guard let finishHandler else {
            return DiarizationSummary(
                spans: [],
                mergedKeptSpans: [],
                targetSpeakerID: nil,
                targetSpeakerDuration: 0,
                keptAudioDuration: 0,
                usedFallback: true,
                fallbackReason: .noUsableSpeakerSpans
            )
        }

        let result = await finishHandler()
        filteredTranscript = result.filteredTranscript
        return result.summary
    }

    func finish(spans: [DiarizationSummary.Span]) async -> DiarizationSummary {
        guard let finishWithSpansHandler else {
            return await finish()
        }

        let result = await finishWithSpansHandler(spans)
        filteredTranscript = result.filteredTranscript
        return result.summary
    }
}
