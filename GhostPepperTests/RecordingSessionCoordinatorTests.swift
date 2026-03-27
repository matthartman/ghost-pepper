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
}
