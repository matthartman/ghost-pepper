import XCTest
@testable import GhostPepper

final class AudioRecorderTests: XCTestCase {
    func testBufferStartsEmpty() {
        let recorder = AudioRecorder()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testBufferClearsOnReset() {
        let recorder = AudioRecorder()
        recorder.audioBuffer = [1.0, 2.0, 3.0]
        recorder.resetBuffer()
        XCTAssertTrue(recorder.audioBuffer.isEmpty)
    }

    func testAudioBufferSerializationRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = try AudioRecorder.serializeAudioBuffer(samples)
        let decoded = try AudioRecorder.deserializeAudioBuffer(from: data)

        XCTAssertEqual(decoded, samples)
    }

    func testPlayableArchiveSerializationCreatesWAVDataThatRoundTripsSamples() throws {
        let samples: [Float] = [0.25, -0.5, 0.75, 0.0]

        let data = try AudioRecorder.serializePlayableArchiveAudioBuffer(samples)
        let riffHeader = String(decoding: data.prefix(4), as: UTF8.self)
        let waveHeader = String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self)
        let decoded = try AudioRecorder.deserializeArchivedAudioBuffer(from: data)

        XCTAssertEqual(riffHeader, "RIFF")
        XCTAssertEqual(waveHeader, "WAVE")
        XCTAssertEqual(decoded.count, samples.count)
        for (decodedSample, expectedSample) in zip(decoded, samples) {
            XCTAssertEqual(decodedSample, expectedSample, accuracy: 0.0001)
        }
    }

    func testConvertedSamplesAreDeliveredToChunkCallback() throws {
        let recorder = AudioRecorder()
        var deliveredChunks: [[Float]] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredChunks.append(chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredChunks, [[0.1, 0.2], [0.3, 0.4]])
    }

    func testChunkDeliveryStillAccumulatesFinalAudioBuffer() throws {
        let recorder = AudioRecorder()
        var deliveredSamples: [Float] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredSamples.append(contentsOf: chunk)
        }

        recorder.test_convert(samples: [0.1, 0.2])
        recorder.test_convert(samples: [0.3, 0.4])

        XCTAssertEqual(deliveredSamples, [0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(recorder.audioBuffer, [0.1, 0.2, 0.3, 0.4])
    }

    func testResetForDeviceChangePreservesExistingBuffer() {
        let recorder = AudioRecorder()
        recorder.test_convert(samples: [0.1, 0.2, 0.3])
        XCTAssertFalse(recorder.audioBuffer.isEmpty)

        recorder.resetForDeviceChange()

        // Buffer lives on the recorder, not the engine, so it persists across resets.
        // It gets cleared when startRecording() calls resetBuffer().
        XCTAssertEqual(recorder.audioBuffer.count, 3)
    }

    func testResetForDeviceChangeAllowsNewChunkDelivery() {
        let recorder = AudioRecorder()
        recorder.resetForDeviceChange()

        var deliveredChunks: [[Float]] = []
        recorder.onConvertedAudioChunk = { chunk in
            deliveredChunks.append(chunk)
        }

        recorder.test_convert(samples: [0.5, 0.6])

        XCTAssertEqual(deliveredChunks, [[0.5, 0.6]])
        XCTAssertEqual(recorder.audioBuffer, [0.5, 0.6])
    }
}
