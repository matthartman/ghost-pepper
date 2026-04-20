import XCTest
@testable import GhostPepper

final class FluidAudioSpeechSessionTests: XCTestCase {
    func testFinalizeFallsBackWhenNoUsableSpeakerSpansAreProvided() async {
        let transcriptionCallCount = LockedValue(0)
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { _ in
                await transcriptionCallCount.withValue { $0 += 1 }
                return "unexpected"
            }
        )

        session.appendAudioChunk(Array(0..<10).map(Float.init))

        let result = await session.finalize(spans: [])

        XCTAssertNil(result.filteredTranscript)
        XCTAssertTrue(result.summary.usedFallback)
        XCTAssertEqual(result.summary.fallbackReason, .noUsableSpeakerSpans)
        XCTAssertNil(result.summary.targetSpeakerID)
        XCTAssertTrue(result.summary.spans.isEmpty)
        XCTAssertTrue(result.summary.mergedKeptSpans.isEmpty)
        let transcriptionCallCountValue = await transcriptionCallCount.get()
        XCTAssertEqual(transcriptionCallCountValue, 0)
    }

    func testFinalizeSelectsEarliestSubstantialSpeakerKeepsTargetSpansAndMergesNearbyGaps() async {
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

    func testFinalizeUsesSpeakerIDTiebreakWhenSpeakersShareTheSameTimestamps() async {
        let capturedAudio = LockedValue<[Float]>([])
        let session = FluidAudioSpeechSession(
            sampleRate: 10,
            transcribeFilteredAudio: { audio in
                await capturedAudio.set(audio)
                return "kept transcript"
            }
        )

        session.appendAudioChunk(Array(0..<10).map(Float.init))

        let result = await session.finalize(
            spans: [
                .init(speakerID: "speaker-b", startTime: 0.0, endTime: 0.8),
                .init(speakerID: "speaker-a", startTime: 0.0, endTime: 0.8),
            ]
        )

        XCTAssertEqual(result.filteredTranscript, "kept transcript")
        XCTAssertEqual(result.summary.targetSpeakerID, "speaker-a")
        XCTAssertFalse(result.summary.usedFallback)
        XCTAssertEqual(result.summary.spans.map(\.speakerID), ["speaker-a", "speaker-b"])
        XCTAssertEqual(result.summary.spans.map(\.isKept), [true, false])
        let captured = await capturedAudio.get()
        XCTAssertEqual(captured, Array(0..<8).map(Float.init))
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
