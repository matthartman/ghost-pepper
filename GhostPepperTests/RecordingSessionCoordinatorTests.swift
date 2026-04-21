import XCTest
@testable import GhostPepper

final class RecordingSessionCoordinatorTests: XCTestCase {
    func testCoordinatorCollectsChunksAndReturnsFinalSummary() async {
        let capturedAudio = LockedValue<[Float]>([])
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { audio in
                await capturedAudio.set(audio)
                return "coordinator transcript"
            }
        )
        let coordinator = RecordingSessionCoordinator(session: session)

        coordinator.appendAudioChunk([0, 1, 2, 3, 4])
        coordinator.appendAudioChunk([5, 6, 7, 8, 9])
        coordinator.appendAudioChunk([10, 11, 12, 13, 14])
        coordinator.appendAudioChunk([15, 16, 17, 18, 19])

        let summary = await coordinator.finish(
            spans: [
                .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.4),
                .init(speakerID: "speaker-b", startTime: 0.4, endTime: 0.7),
                .init(speakerID: "speaker-a", startTime: 0.74, endTime: 1.3),
            ]
        )

        XCTAssertEqual(summary.targetSpeakerID, "speaker-a")
        XCTAssertEqual(summary.targetSpeakerDuration, 0.96, accuracy: 0.0001)
        XCTAssertEqual(summary.keptAudioDuration, 0.96, accuracy: 0.0001)
        XCTAssertFalse(summary.usedFallback)
        XCTAssertEqual(summary.mergedKeptSpans, [
            .init(startTime: 0.0, endTime: 0.4),
            .init(startTime: 0.74, endTime: 1.3),
        ])
        let captured = await capturedAudio.get()
        XCTAssertEqual(captured, [0, 1, 2, 3, 7, 8, 9, 10, 11, 12])
    }

    func testSessionBackedCoordinatorFeedsChunksToBothSessionAndDiarizerProcessor() async {
        let capturedAudio = LockedValue<[Float]>([])
        var processedChunks: [[Float]] = []
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { audio in
                await capturedAudio.set(audio)
                return "coordinator transcript"
            }
        )
        let coordinator = RecordingSessionCoordinator(
            session: session,
            processAudioChunk: { samples in
                processedChunks.append(samples)
            },
            finish: {
                [
                    .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.4),
                    .init(speakerID: "speaker-b", startTime: 0.4, endTime: 0.7),
                    .init(speakerID: "speaker-a", startTime: 0.74, endTime: 1.3),
                ]
            }
        )

        coordinator.appendAudioChunk([0, 1, 2, 3, 4])
        coordinator.appendAudioChunk([5, 6, 7, 8, 9])
        coordinator.appendAudioChunk([10, 11, 12, 13, 14])
        coordinator.appendAudioChunk([15, 16, 17, 18, 19])

        let summary = await coordinator.finish()

        XCTAssertEqual(summary.targetSpeakerID, "speaker-a")
        XCTAssertFalse(summary.usedFallback)
        let captured = await capturedAudio.get()
        XCTAssertEqual(captured, [0, 1, 2, 3, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(processedChunks, [
            [0, 1, 2, 3, 4],
            [5, 6, 7, 8, 9],
            [10, 11, 12, 13, 14],
            [15, 16, 17, 18, 19],
        ])
    }

    func testSessionBackedCoordinatorWaitsForQueuedChunkProcessingBeforeFinishing() async {
        let capturedAudio = LockedValue<[Float]>([])
        let processedChunksQueue = DispatchQueue(label: "RecordingSessionCoordinatorTests.processedChunks")
        var processedChunks: [[Float]] = []
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { audio in
                await capturedAudio.set(audio)
                return "coordinator transcript"
            }
        )
        let coordinator = RecordingSessionCoordinator(
            session: session,
            processAudioChunk: { samples in
                Thread.sleep(forTimeInterval: 0.05)
                processedChunksQueue.sync {
                    processedChunks.append(samples)
                }
            },
            finish: {
                [
                    .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.4),
                    .init(speakerID: "speaker-b", startTime: 0.4, endTime: 0.7),
                    .init(speakerID: "speaker-a", startTime: 0.74, endTime: 1.3),
                ]
            }
        )

        coordinator.appendAudioChunk([0, 1, 2, 3, 4])
        coordinator.appendAudioChunk([5, 6, 7, 8, 9])
        coordinator.appendAudioChunk([10, 11, 12, 13, 14])
        coordinator.appendAudioChunk([15, 16, 17, 18, 19])

        _ = await coordinator.finish()

        let processed = processedChunksQueue.sync { processedChunks }
        XCTAssertEqual(processed, [
            [0, 1, 2, 3, 4],
            [5, 6, 7, 8, 9],
            [10, 11, 12, 13, 14],
            [15, 16, 17, 18, 19],
        ])
    }

    func testChunkedRecordingTranscriptionSessionTranscribesDuringRecordingAndDeduplicatesOverlap() async {
        let transcribedChunks = LockedValue<[String]>([])
        let session = ChunkedRecordingTranscriptionSession(
            chunkSizeSamples: 4,
            shiftSamples: 2,
            transcribeChunk: { samples in
                switch samples {
                case [1, 2, 3, 4]:
                    await transcribedChunks.append("hello there")
                    return "hello there"
                case [3, 4, 5, 6]:
                    await transcribedChunks.append("there world")
                    return "there world"
                case [5, 6]:
                    await transcribedChunks.append("world again")
                    return "world again"
                default:
                    return nil
                }
            }
        )

        session.appendAudioChunk([1, 2])
        session.appendAudioChunk([3, 4])
        session.appendAudioChunk([5, 6])

        let transcript = await session.finishTranscription()

        XCTAssertEqual(transcript, "hello there world again")
        let processed = await transcribedChunks.get()
        XCTAssertEqual(Set(processed), Set(["hello there", "there world", "world again"]))
    }

    func testChunkedRecordingTranscriptionSessionCancelPreventsPendingTranscriptFromReturning() async {
        let session = ChunkedRecordingTranscriptionSession(
            chunkSizeSamples: 4,
            shiftSamples: 4,
            transcribeChunk: { _ in
                try? await Task.sleep(nanoseconds: 50_000_000)
                return "should not be returned"
            }
        )

        session.appendAudioChunk([1, 2, 3, 4])
        session.cancel()

        let transcript = await session.finishTranscription()

        XCTAssertNil(transcript)
    }

    func testSlidingWindowRecordingTranscriptionSessionFlushesQueuedChunksBeforeFinishing() async {
        let appendedChunks = LockedValue<[[Float]]>([])
        let events = LockedValue<[String]>([])
        let session = SlidingWindowRecordingTranscriptionSession {
            StreamingRecordingHandle(
                appendAudioChunk: { samples in
                    await appendedChunks.append(samples)
                },
                finishTranscription: {
                    await events.append("finish")
                    return "stable transcript"
                },
                cancel: {
                    await events.append("cancel")
                },
                cleanup: {
                    await events.append("cleanup")
                }
            )
        }

        session.appendAudioChunk([1, 2])
        session.appendAudioChunk([3, 4])

        let transcript = await session.finishTranscription()

        XCTAssertEqual(transcript, "stable transcript")
        let chunks = await appendedChunks.get()
        let recordedEvents = await events.get()
        XCTAssertEqual(chunks, [[1, 2], [3, 4]])
        XCTAssertEqual(recordedEvents, ["finish", "cleanup"])
    }

    func testSlidingWindowRecordingTranscriptionSessionPrefersFullBufferFinalTranscription() async {
        let fullBuffer = LockedValue<[Float]?>(nil)
        let events = LockedValue<[String]>([])
        let session = SlidingWindowRecordingTranscriptionSession(
            fullBufferTranscription: { samples in
                await fullBuffer.set(samples)
                await events.append("batch")
                return "batch transcript"
            },
            handleFactory: {
                StreamingRecordingHandle(
                    appendAudioChunk: { _ in },
                    finishTranscription: {
                        await events.append("finish")
                        return "streamed transcript"
                    },
                    cancel: {
                        await events.append("cancel")
                    },
                    cleanup: {
                        await events.append("cleanup")
                    }
                )
            }
        )

        session.appendAudioChunk([1, 2])
        session.appendAudioChunk([3, 4])

        let transcript = await session.finishTranscription()

        XCTAssertEqual(transcript, "batch transcript")
        let recordedBuffer = await fullBuffer.get()
        XCTAssertEqual(recordedBuffer, [1, 2, 3, 4])
        let recordedEvents = await events.get()
        XCTAssertEqual(recordedEvents, ["finish", "batch", "cleanup"])
    }

    func testSlidingWindowRecordingTranscriptionSessionDoesNotFallBackToStreamedTranscriptWhenFullBufferTranscriptionFails() async {
        let events = LockedValue<[String]>([])
        let session = SlidingWindowRecordingTranscriptionSession(
            fullBufferTranscription: { _ in
                await events.append("batch")
                return nil
            },
            handleFactory: {
                StreamingRecordingHandle(
                    appendAudioChunk: { _ in },
                    finishTranscription: {
                        await events.append("finish")
                        return "streamed transcript"
                    },
                    cancel: {
                        await events.append("cancel")
                    },
                    cleanup: {
                        await events.append("cleanup")
                    }
                )
            }
        )

        session.appendAudioChunk([1, 2])
        session.appendAudioChunk([3, 4])

        let transcript = await session.finishTranscription()

        XCTAssertNil(transcript)
        let recordedEvents = await events.get()
        XCTAssertEqual(recordedEvents, ["finish", "batch", "cleanup"])
    }

    func testSlidingWindowRecordingTranscriptionSessionCancelPreventsFinalTranscript() async {
        let events = LockedValue<[String]>([])
        let session = SlidingWindowRecordingTranscriptionSession {
            StreamingRecordingHandle(
                appendAudioChunk: { _ in },
                finishTranscription: {
                    await events.append("finish")
                    return "should not be returned"
                },
                cancel: {
                    await events.append("cancel")
                },
                cleanup: {
                    await events.append("cleanup")
                }
            )
        }

        session.appendAudioChunk([1, 2, 3, 4])
        session.cancel()

        let transcript = await session.finishTranscription()

        XCTAssertNil(transcript)
    }
}

private actor LockedValue<Value> {
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        value
    }

    func set(_ value: Value) {
        self.value = value
    }

    func append<Element>(_ newElement: Element) where Value == [Element] {
        value.append(newElement)
    }
}
