import XCTest
@testable import WhisperCat

@MainActor
final class WhisperTranscriberTests: XCTestCase {

    // MARK: - ModelManager Tests

    func testModelManagerInitialState() {
        let manager = ModelManager()
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isReady)
        XCTAssertNil(manager.whisperKit)
        XCTAssertNil(manager.error)
    }

    func testModelManagerDefaultModelName() {
        let manager = ModelManager()
        XCTAssertEqual(manager.modelName, "openai_whisper-small.en")
    }

    func testModelManagerCustomModelName() {
        let manager = ModelManager(modelName: "openai_whisper-tiny.en")
        XCTAssertEqual(manager.modelName, "openai_whisper-tiny.en")
    }

    func testModelManagerStateEnum() {
        // Verify all states are distinct
        let states: [ModelManagerState] = [.idle, .loading, .ready, .error]
        for (i, a) in states.enumerated() {
            for (j, b) in states.enumerated() {
                if i == j {
                    XCTAssertEqual(a, b)
                } else {
                    XCTAssertNotEqual(a, b)
                }
            }
        }
    }

    // MARK: - WhisperTranscriber Tests

    func testTranscriberReportsNotReadyBeforeModelLoad() {
        let manager = ModelManager()
        let transcriber = WhisperTranscriber(modelManager: manager)
        XCTAssertFalse(transcriber.isReady)
    }

    func testTranscriberEmptyAudioReturnsNil() async {
        let manager = ModelManager()
        let transcriber = WhisperTranscriber(modelManager: manager)
        let result = await transcriber.transcribe(audioBuffer: [])
        XCTAssertNil(result, "Empty audio buffer should return nil")
    }

    func testTranscriberReturnsNilWhenModelNotLoaded() async {
        let manager = ModelManager()
        let transcriber = WhisperTranscriber(modelManager: manager)
        // Non-empty buffer but model not loaded should return nil
        let silence = [Float](repeating: 0.0, count: 16000)
        let result = await transcriber.transcribe(audioBuffer: silence)
        XCTAssertNil(result, "Should return nil when model is not loaded")
    }
}
