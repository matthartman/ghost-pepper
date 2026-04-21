@preconcurrency import AVFoundation
import Foundation
import FluidAudio

protocol RecordingTranscriptionSession: AnyObject {
    var allowsBatchFallback: Bool { get }
    var supportsConcurrentFinalization: Bool { get }
    func appendAudioChunk(_ samples: [Float])
    func finishTranscription() async -> String?
    func cancel()
}

private final class OrderedChunkProcessor {
    private let queue = DispatchQueue(
        label: "GhostPepper.OrderedChunkProcessor.queue",
        qos: .userInitiated
    )
    private let group = DispatchGroup()

    func enqueue(_ operation: @escaping () -> Void) {
        group.enter()
        queue.async { [group] in
            defer { group.leave() }
            operation()
        }
    }

    func waitForDrain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [group] in
                group.wait()
                continuation.resume()
            }
        }
    }
}

struct StreamingRecordingHandle: Sendable {
    let appendAudioChunk: @Sendable ([Float]) async -> Void
    let finishTranscription: @Sendable () async throws -> String
    let cancel: @Sendable () async -> Void
    let cleanup: @Sendable () async -> Void
}

final class SlidingWindowRecordingTranscriptionSession: RecordingTranscriptionSession, @unchecked Sendable {
    private static let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    private let handleTask: Task<StreamingRecordingHandle, Error>
    private let fullBufferTranscription: (@Sendable ([Float]) async -> String?)?
    private let stateQueue = DispatchQueue(
        label: "GhostPepper.SlidingWindowRecordingTranscriptionSession.state"
    )

    private var isCancelled = false
    private var isFinishing = false
    private var didCleanup = false
    private var appendTask: Task<Void, Never>?
    private var bufferedSamples: [Float] = []

    var allowsBatchFallback: Bool {
        fullBufferTranscription == nil
    }
    let supportsConcurrentFinalization = true

    init(
        fullBufferTranscription: (@Sendable ([Float]) async -> String?)? = nil,
        handleFactory: @escaping @Sendable () async throws -> StreamingRecordingHandle
    ) {
        self.fullBufferTranscription = fullBufferTranscription
        handleTask = Task {
            try await handleFactory()
        }
    }

    convenience init(
        models: AsrModels,
        config: SlidingWindowAsrConfig = .streaming,
        fullBufferTranscription: (@Sendable ([Float]) async -> String?)? = nil
    ) {
        self.init(fullBufferTranscription: fullBufferTranscription) {
            let manager = SlidingWindowAsrManager(config: config)
            try await manager.start(models: models, source: .microphone)

            return StreamingRecordingHandle(
                appendAudioChunk: { samples in
                    guard let buffer = Self.makePCMBuffer(from: samples) else {
                        return
                    }
                    await manager.streamAudio(buffer)
                },
                finishTranscription: {
                    try await manager.finish()
                },
                cancel: {
                    await manager.cancel()
                },
                cleanup: {
                    await manager.cleanup()
                }
            )
        }
    }

    func appendAudioChunk(_ samples: [Float]) {
        guard samples.isEmpty == false else {
            return
        }

        let shouldProcess = stateQueue.sync { () -> Bool in
            guard isCancelled == false, isFinishing == false else {
                return false
            }
            bufferedSamples.append(contentsOf: samples)
            let previousTask = appendTask
            appendTask = Task {
                _ = await previousTask?.value
                guard let handle = try? await handleTask.value else {
                    return
                }
                await handle.appendAudioChunk(samples)
            }
            return true
        }

        guard shouldProcess else {
            return
        }
    }

    func finishTranscription() async -> String? {
        let shouldFinish = stateQueue.sync { () -> Bool in
            guard isCancelled == false else {
                return false
            }

            isFinishing = true
            return true
        }

        guard shouldFinish else {
            return nil
        }

        await waitForPendingAppends()

        guard let handle = try? await handleTask.value else {
            return nil
        }

        let fullBuffer = stateQueue.sync { () -> [Float] in
            let fullBuffer = bufferedSamples
            bufferedSamples = []
            return fullBuffer
        }
        let streamedTranscriptTask = Task<String?, Never> {
            let transcript = try? await handle.finishTranscription()
            return transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let batchTranscriptTask = fullBufferTranscription.map { fullBufferTranscription in
            Task<String?, Never> {
                await fullBufferTranscription(fullBuffer)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let batchTranscript = await batchTranscriptTask?.value
        let streamedTranscript = await streamedTranscriptTask.value
        await cleanupIfNeeded(using: handle)

        if batchTranscriptTask != nil {
            guard let batchTranscript, batchTranscript.isEmpty == false else {
                return nil
            }

            return batchTranscript
        }

        guard let streamedTranscript, streamedTranscript.isEmpty == false else {
            return nil
        }

        return streamedTranscript
    }

    func cancel() {
        let shouldCancel = stateQueue.sync { () -> Bool in
            let shouldCancel = isCancelled == false
            isCancelled = true
            isFinishing = true
            bufferedSamples = []
            return shouldCancel
        }

        guard shouldCancel else {
            return
        }

        Task {
            let pendingTask = stateQueue.sync { appendTask }
            _ = await pendingTask?.value
            guard let handle = try? await handleTask.value else {
                return
            }

            await handle.cancel()
            await self.cleanupIfNeeded(using: handle)
        }
    }

    private func waitForPendingAppends() async {
        let pendingTask = stateQueue.sync { appendTask }
        _ = await pendingTask?.value
    }

    private func cleanupIfNeeded(using handle: StreamingRecordingHandle) async {
        let shouldCleanup = stateQueue.sync { () -> Bool in
            guard didCleanup == false else {
                return false
            }

            didCleanup = true
            return true
        }

        guard shouldCleanup else {
            return
        }

        await handle.cleanup()
    }

    private static func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?.pointee {
            samples.withUnsafeBufferPointer { source in
                if let baseAddress = source.baseAddress {
                    channelData.update(from: baseAddress, count: samples.count)
                }
            }
        }

        return buffer
    }
}

@available(macOS 15, iOS 18, *)
final class QwenRecordingTranscriptionSession: RecordingTranscriptionSession, @unchecked Sendable {
    private static let streamingConfig = Qwen3StreamingConfig(
        minAudioSeconds: 0.5,
        chunkSeconds: 0.5,
        maxAudioSeconds: 30.0,
        language: nil
    )

    private let streamingManager: Qwen3StreamingManager
    private let stateQueue = DispatchQueue(
        label: "GhostPepper.QwenRecordingTranscriptionSession.state"
    )

    private var latestTranscript: String?
    private var isCancelled = false
    private var isFinishing = false
    private var appendTask: Task<Void, Never>?

    let allowsBatchFallback = false
    let supportsConcurrentFinalization = false

    init(asrManager: Qwen3AsrManager) {
        streamingManager = Qwen3StreamingManager(
            asrManager: asrManager,
            config: Self.streamingConfig
        )
    }

    func appendAudioChunk(_ samples: [Float]) {
        guard samples.isEmpty == false else {
            return
        }

        let shouldProcess = stateQueue.sync { () -> Bool in
            guard isCancelled == false, isFinishing == false else {
                return false
            }

            let previousTask = appendTask
            appendTask = Task {
                _ = await previousTask?.value

                let canProcess = stateQueue.sync { () -> Bool in
                    isCancelled == false
                }
                guard canProcess else {
                    return
                }

                let transcript = try? await streamingManager.addAudio(samples)?
                    .transcript
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                stateQueue.sync {
                    guard self.isCancelled == false else {
                        return
                    }

                    if let transcript, transcript.isEmpty == false {
                        self.latestTranscript = transcript
                    }
                }
            }
            return true
        }

        guard shouldProcess else {
            return
        }
    }

    func finishTranscription() async -> String? {
        let shouldFinish = stateQueue.sync { () -> Bool in
            guard isCancelled == false else {
                return false
            }

            isFinishing = true
            return true
        }

        guard shouldFinish else {
            return nil
        }

        let pendingTask = stateQueue.sync { appendTask }
        _ = await pendingTask?.value

        let finalTranscript = try? await streamingManager.finish()
            .transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return stateQueue.sync {
            if let finalTranscript, finalTranscript.isEmpty == false {
                latestTranscript = finalTranscript
            }

            guard let latestTranscript, latestTranscript.isEmpty == false else {
                return nil
            }

            return latestTranscript
        }
    }

    func cancel() {
        let pendingTask = stateQueue.sync { () -> Task<Void, Never>? in
            let shouldReset = isCancelled == false
            isCancelled = true
            isFinishing = true
            latestTranscript = nil
            return shouldReset ? appendTask : nil
        }

        guard let pendingTask else {
            return
        }

        Task {
            _ = await pendingTask.value
            await streamingManager.reset()
        }
    }
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

    let allowsBatchFallback = true
    let supportsConcurrentFinalization = false

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
        let processor = OrderedChunkProcessor()
        appendAudioChunkHandler = { samples in
            session.appendAudioChunk(samples)
            processor.enqueue {
                processAudioChunk(samples)
            }
        }
        finishHandler = {
            await processor.waitForDrain()
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
        let result = await finishResult()
        return result.summary
    }

    func finishResult() async -> FinalizationResult {
        guard let finishHandler else {
            return (
                filteredTranscript: nil,
                summary: DiarizationSummary(
                    spans: [],
                    mergedKeptSpans: [],
                    targetSpeakerID: nil,
                    targetSpeakerDuration: 0,
                    keptAudioDuration: 0,
                    usedFallback: true,
                    fallbackReason: .noUsableSpeakerSpans
                )
            )
        }

        let result = await finishHandler()
        filteredTranscript = result.filteredTranscript
        return result
    }

    func finish(spans: [DiarizationSummary.Span]) async -> DiarizationSummary {
        let result = await finishResult(spans: spans)
        return result.summary
    }

    func finishResult(spans: [DiarizationSummary.Span]) async -> FinalizationResult {
        guard let finishWithSpansHandler else {
            return await finishResult()
        }

        let result = await finishWithSpansHandler(spans)
        filteredTranscript = result.filteredTranscript
        return result
    }
}
