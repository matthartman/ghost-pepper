import XCTest
@testable import GhostPepper

final class FluidAudioSpeechSessionTests: XCTestCase {
    func testFinalizeSelectsDominantSpeakerKeepsTargetSpansAndMergesNearbyGaps() async {
        let capturedAudio = LockedValue<[Float]>([])
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { audio in
                await capturedAudio.set(audio)
                return "kept transcript"
            }
        )

        session.appendAudioChunk([0, 1, 2, 3, 4])
        session.appendAudioChunk([5, 6, 7, 8, 9])
        session.appendAudioChunk([10, 11, 12, 13, 14])
        session.appendAudioChunk([15, 16, 17, 18, 19])

        let result = await session.finalize(
            spans: [
                .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.2),
                .init(speakerID: "speaker-b", startTime: 0.2, endTime: 0.8),
                .init(speakerID: "speaker-a", startTime: 0.8, endTime: 1.1),
                .init(speakerID: "speaker-c", startTime: 1.1, endTime: 1.3),
                .init(speakerID: "speaker-a", startTime: 1.34, endTime: 1.6),
                .init(speakerID: "speaker-a", startTime: 1.62, endTime: 1.8),
            ]
        )

        XCTAssertEqual(result.filteredTranscript, "kept transcript")
        XCTAssertEqual(result.summary.targetSpeakerID, "speaker-a")
        XCTAssertEqual(result.summary.targetSpeakerDuration, 0.94, accuracy: 0.0001)
        XCTAssertEqual(result.summary.keptAudioDuration, 0.96, accuracy: 0.0001)
        XCTAssertFalse(result.summary.usedFallback)
        XCTAssertNil(result.summary.fallbackReason)
        XCTAssertEqual(result.summary.spans.map(\.isKept), [true, false, true, false, true, true])
        XCTAssertEqual(result.summary.mergedKeptSpans, [
            .init(startTime: 0.0, endTime: 0.2),
            .init(startTime: 0.8, endTime: 1.1),
            .init(startTime: 1.34, endTime: 1.8),
        ])
        let captured = await capturedAudio.get()
        XCTAssertEqual(captured, [0, 1, 8, 9, 10, 13, 14, 15, 16, 17])
    }

    func testFinalizeSelectsDominantSpeakerWhenAnEarlierSpeakerCrossesThreshold() async {
        let capturedAudio = LockedValue<[Float]>([])
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { audio in
                await capturedAudio.set(audio)
                return "dominant speaker transcript"
            }
        )

        session.appendAudioChunk(Array(0..<50).map(Float.init))

        let result = await session.finalize(
            spans: [
                .init(speakerID: "speaker-a", startTime: 0.4, endTime: 0.9),
                .init(speakerID: "speaker-a", startTime: 1.2, endTime: 1.7),
                .init(speakerID: "speaker-b", startTime: 2.0, endTime: 4.4),
            ]
        )

        XCTAssertEqual(result.filteredTranscript, "dominant speaker transcript")
        XCTAssertEqual(result.summary.targetSpeakerID, "speaker-b")
        XCTAssertEqual(result.summary.targetSpeakerDuration, 2.4, accuracy: 0.0001)
        XCTAssertEqual(result.summary.keptAudioDuration, 2.4, accuracy: 0.0001)
        XCTAssertFalse(result.summary.usedFallback)
        XCTAssertEqual(result.summary.spans.map(\.isKept), [false, false, true])
        XCTAssertEqual(result.summary.mergedKeptSpans, [
            .init(startTime: 2.0, endTime: 4.4),
        ])
        let captured = await capturedAudio.get()
        XCTAssertEqual(captured, Array(20..<44).map(Float.init))
    }

    func testFinalizeFallsBackWhenSpeakerDurationsAreTooCloseToCall() async {
        let transcriptionCallCount = LockedValue(0)
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { _ in
                await transcriptionCallCount.withValue { $0 += 1 }
                return "unexpected"
            }
        )

        session.appendAudioChunk(Array(0..<40).map(Float.init))

        let result = await session.finalize(
            spans: [
                .init(speakerID: "speaker-a", startTime: 0.0, endTime: 1.8),
                .init(speakerID: "speaker-b", startTime: 1.8, endTime: 3.4),
            ]
        )

        XCTAssertNil(result.filteredTranscript)
        XCTAssertTrue(result.summary.usedFallback)
        XCTAssertEqual(result.summary.fallbackReason, .ambiguousDominantSpeaker)
        XCTAssertNil(result.summary.targetSpeakerID)
        XCTAssertTrue(result.summary.mergedKeptSpans.isEmpty)
        let transcriptionCallCountValue = await transcriptionCallCount.get()
        XCTAssertEqual(transcriptionCallCountValue, 0)
    }

    func testFinalizeFallsBackWhenNoSpeakerReachesThreshold() async {
        let transcriptionCallCount = LockedValue(0)
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { _ in
                await transcriptionCallCount.withValue { $0 += 1 }
                return "unexpected"
            }
        )

        session.appendAudioChunk(Array(0..<10).map(Float.init))

        let result = await session.finalize(
            spans: [
                .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.2),
                .init(speakerID: "speaker-b", startTime: 0.3, endTime: 0.65),
            ]
        )

        XCTAssertNil(result.filteredTranscript)
        XCTAssertTrue(result.summary.usedFallback)
        XCTAssertEqual(result.summary.fallbackReason, .noSpeakerReachedThreshold)
        XCTAssertEqual(result.summary.targetSpeakerID, nil)
        XCTAssertTrue(result.summary.mergedKeptSpans.isEmpty)
        let transcriptionCallCountValue = await transcriptionCallCount.get()
        XCTAssertEqual(transcriptionCallCountValue, 0)
    }

    func testFinalizeFallsBackWhenKeptAudioIsShorterThanMinimumDuration() async {
        let transcriptionCallCount = LockedValue(0)
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { _ in
                await transcriptionCallCount.withValue { $0 += 1 }
                return "unexpected"
            }
        )

        session.appendAudioChunk(Array(0..<10).map(Float.init))

        let result = await session.finalize(
            spans: [
                .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.3),
                .init(speakerID: "speaker-a", startTime: 0.35, endTime: 0.6),
                .init(speakerID: "speaker-b", startTime: 0.6, endTime: 0.9),
            ]
        )

        XCTAssertNil(result.filteredTranscript)
        XCTAssertEqual(result.summary.targetSpeakerID, "speaker-a")
        XCTAssertEqual(result.summary.targetSpeakerDuration, 0.55, accuracy: 0.0001)
        XCTAssertEqual(result.summary.keptAudioDuration, 0.6, accuracy: 0.0001)
        XCTAssertTrue(result.summary.usedFallback)
        XCTAssertEqual(result.summary.fallbackReason, .insufficientKeptAudio)
        let transcriptionCallCountValue = await transcriptionCallCount.get()
        XCTAssertEqual(transcriptionCallCountValue, 0)
    }

    func testFinalizeFallsBackWhenFilteredTranscriptionIsEmpty() async {
        let transcriptionCallCount = LockedValue(0)
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { _ in
                await transcriptionCallCount.withValue { $0 += 1 }
                return "   "
            }
        )

        session.appendAudioChunk(Array(0..<20).map(Float.init))

        let result = await session.finalize(
            spans: [
                .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.4),
                .init(speakerID: "speaker-b", startTime: 0.4, endTime: 0.6),
                .init(speakerID: "speaker-a", startTime: 0.6, endTime: 1.1),
            ]
        )

        XCTAssertNil(result.filteredTranscript)
        XCTAssertEqual(result.summary.targetSpeakerID, "speaker-a")
        XCTAssertEqual(result.summary.keptAudioDuration, 0.9, accuracy: 0.0001)
        XCTAssertTrue(result.summary.usedFallback)
        XCTAssertEqual(result.summary.fallbackReason, .emptyFilteredTranscription)
        let transcriptionCallCountValue = await transcriptionCallCount.get()
        XCTAssertEqual(transcriptionCallCountValue, 1)
    }

    func testFinalizeFallsBackWhenOnlyOneSpeakerIsDetected() async {
        let transcriptionCallCount = LockedValue(0)
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { _ in
                await transcriptionCallCount.withValue { $0 += 1 }
                return "Yeah."
            }
        )

        session.appendAudioChunk(Array(repeating: 0, count: 46))

        let result = await session.finalize(
            spans: [
                .init(speakerID: "Speaker 0", startTime: 2.48, endTime: 4.24),
            ]
        )

        XCTAssertNil(result.filteredTranscript)
        XCTAssertTrue(result.summary.usedFallback)
        XCTAssertEqual(result.summary.fallbackReason, .singleDetectedSpeaker)
        XCTAssertEqual(result.summary.targetSpeakerID, "Speaker 0")
        XCTAssertEqual(result.summary.keptAudioDuration, 1.76, accuracy: 0.0001)
        XCTAssertEqual(result.summary.spans.map(\.isKept), [true])
        let transcriptionCallCountValue = await transcriptionCallCount.get()
        XCTAssertEqual(transcriptionCallCountValue, 0)
    }

    func testSpeakerTaggedTranscriptTranscribesMergedSpeakerSpansInTimelineOrder() async {
        let capturedAudio = LockedValue<[[Float]]>([])
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { audio in
                await capturedAudio.withValue { $0.append(audio) }
                switch audio {
                case [0, 1, 2, 3]:
                    return "speaker a one"
                case [4, 5, 6, 7, 8]:
                    return "speaker b"
                case [9, 10, 11, 12, 13, 14, 15]:
                    return "speaker a two"
                default:
                    return nil
                }
            }
        )

        session.appendAudioChunk(Array(0..<16).map(Float.init))

        let transcript = await session.speakerTaggedTranscript(
            spans: [
                .init(speakerID: "Speaker A", startTime: 0.0, endTime: 0.2),
                .init(speakerID: "Speaker A", startTime: 0.2, endTime: 0.4),
                .init(speakerID: "Speaker B", startTime: 0.4, endTime: 0.9),
                .init(speakerID: "Speaker A", startTime: 0.9, endTime: 1.3),
                .init(speakerID: "Speaker A", startTime: 1.32, endTime: 1.6),
            ]
        )

        XCTAssertEqual(
            transcript,
            SpeakerTaggedTranscript(
                segments: [
                    .init(
                        speakerID: "Speaker A",
                        startTime: 0.0,
                        endTime: 0.4,
                        text: "speaker a one"
                    ),
                    .init(
                        speakerID: "Speaker B",
                        startTime: 0.4,
                        endTime: 0.9,
                        text: "speaker b"
                    ),
                    .init(
                        speakerID: "Speaker A",
                        startTime: 0.9,
                        endTime: 1.6,
                        text: "speaker a two"
                    ),
                ]
            )
        )
        let recordedAudio = await capturedAudio.get()
        XCTAssertEqual(
            recordedAudio,
            [
                [0, 1, 2, 3],
                [4, 5, 6, 7, 8],
                [9, 10, 11, 12, 13, 14, 15],
            ]
        )
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

    func withValue(_ update: (inout Value) -> Void) {
        update(&value)
    }
}
