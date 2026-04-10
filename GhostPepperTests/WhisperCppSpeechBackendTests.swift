import XCTest
@testable import GhostPepper

@MainActor
final class WhisperCppSpeechBackendTests: XCTestCase {
    func testModelURLBuildsPathInsideWhisperCppCacheDirectory() {
        let model = makeTestModel(cachePathComponents: ["unit-tests", "path-check", "model.bin"])

        let modelURL = WhisperCppSpeechBackend.modelURL(for: model)

        XCTAssertTrue(modelURL.path.contains("/Application Support/GhostPepper/whisper-cpp-models/"))
        XCTAssertTrue(modelURL.path.hasSuffix("/unit-tests/path-check/model.bin"))
    }

    func testLoadModelFailsWhenUncachedModelHasNoDownloadURL() async {
        let model = makeTestModel(
            cachePathComponents: ["unit-tests", UUID().uuidString, "missing-download.bin"],
            downloadURL: nil
        )
        let backend = WhisperCppSpeechBackend(executableURLOverride: {
            URL(fileURLWithPath: "/usr/bin/true")
        })

        await XCTAssertThrowsErrorAsync(try await backend.loadModel(model) { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Missing download URL"))
        }
    }

    func testLoadModelFailsBeforeDownloadingWhenRuntimeIsMissing() async {
        let model = makeTestModel(
            cachePathComponents: ["unit-tests", UUID().uuidString, "runtime-missing.bin"],
            downloadURL: "https://example.com/should-not-download.bin"
        )
        let backend = WhisperCppSpeechBackend(executableURLOverride: { nil })

        await XCTAssertThrowsErrorAsync(try await backend.loadModel(model) { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("whisper.cpp runtime not found"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: WhisperCppSpeechBackend.modelURL(for: model).path))
    }

    func testLoadModelFailsWhenRuntimeIsMissingEvenIfModelIsCached() async throws {
        let model = makeTestModel(cachePathComponents: ["unit-tests", UUID().uuidString, "cached.bin"])
        let cachedURL = try cacheModelFile(for: model)
        defer { try? FileManager.default.removeItem(at: cachedURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let backend = WhisperCppSpeechBackend(executableURLOverride: { nil })

        await XCTAssertThrowsErrorAsync(try await backend.loadModel(model) { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("whisper.cpp runtime not found"))
        }
    }

    func testLoadModelReturnsCachedURLWhenRuntimeExists() async throws {
        let model = makeTestModel(cachePathComponents: ["unit-tests", UUID().uuidString, "cached.bin"])
        let cachedURL = try cacheModelFile(for: model)
        defer { try? FileManager.default.removeItem(at: cachedURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let backend = WhisperCppSpeechBackend(executableURLOverride: {
            URL(fileURLWithPath: "/usr/bin/true")
        })

        let loadedURL = try await backend.loadModel(model) { _ in }

        XCTAssertEqual(loadedURL, cachedURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: validationMarkerURL(for: model).path))
    }

    func testLoadModelFailsWhenValidationCommandReturnsNonZero() async throws {
        let model = makeTestModel(cachePathComponents: ["unit-tests", UUID().uuidString, "invalid.bin"])
        let cachedURL = try cacheModelFile(for: model)
        defer { try? FileManager.default.removeItem(at: cachedURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let backend = WhisperCppSpeechBackend(executableURLOverride: {
            URL(fileURLWithPath: "/usr/bin/false")
        })

        await XCTAssertThrowsErrorAsync(try await backend.loadModel(model) { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("whisper.cpp exited with status"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: validationMarkerURL(for: model).path))
    }

    func testLoadModelSkipsValidationForCachedModelWithValidationMarker() async throws {
        let model = makeTestModel(cachePathComponents: ["unit-tests", UUID().uuidString, "validated.bin"])
        let cachedURL = try cacheModelFile(for: model)
        let markerURL = validationMarkerURL(for: model)
        try Data().write(to: markerURL)
        defer { try? FileManager.default.removeItem(at: cachedURL.deletingLastPathComponent().deletingLastPathComponent()) }

        let backend = WhisperCppSpeechBackend(executableURLOverride: {
            URL(fileURLWithPath: "/usr/bin/false")
        })

        let loadedURL = try await backend.loadModel(model) { _ in }

        XCTAssertEqual(loadedURL, cachedURL)
    }

    func testDeleteCachedModelRemovesValidationMarker() throws {
        let model = makeTestModel(cachePathComponents: ["unit-tests", UUID().uuidString, "delete-marker.bin"])
        let cachedURL = try cacheModelFile(for: model)
        let markerURL = validationMarkerURL(for: model)
        try Data().write(to: markerURL)
        defer { try? FileManager.default.removeItem(at: cachedURL.deletingLastPathComponent().deletingLastPathComponent()) }

        WhisperCppSpeechBackend.deleteCachedModel(model)

        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testTranscriptionOverrideReceivesWhisperCppInputs() async throws {
        let expectedModelURL = URL(fileURLWithPath: "/tmp/test-model.bin")
        let backend = WhisperCppSpeechBackend(
            transcriptionOverride: { model, modelURL, audioBuffer, language in
                XCTAssertEqual(model.name, "ggml-large-v3-turbo-q5_0")
                XCTAssertEqual(modelURL, expectedModelURL)
                XCTAssertEqual(audioBuffer, [0.1, 0.2, 0.3])
                XCTAssertEqual(language, "en")
                return " override transcript "
            },
            executableURLOverride: { nil }
        )

        let transcript = try await backend.transcribe(
            model: SpeechModelCatalog.whisperCppLargeV3TurboQuantized,
            modelURL: expectedModelURL,
            audioBuffer: [0.1, 0.2, 0.3],
            language: "en"
        )

        XCTAssertEqual(transcript, " override transcript ")
    }

    private func makeTestModel(
        cachePathComponents: [String],
        downloadURL: String? = "https://example.com/test-model.bin"
    ) -> SpeechModelDescriptor {
        SpeechModelDescriptor(
            name: "unit-test-whisper-cpp-model-\(UUID().uuidString)",
            pickerTitle: "Test",
            variantName: "test",
            sizeDescription: "~1 MB",
            pickerLabelOverride: nil,
            statusNameOverride: nil,
            backend: .whisperCpp,
            cachePathComponents: cachePathComponents,
            downloadURL: downloadURL,
            fluidAudioVariant: nil
        )
    }

    private func cacheModelFile(for model: SpeechModelDescriptor) throws -> URL {
        let url = WhisperCppSpeechBackend.modelURL(for: model)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: url)
        return url
    }

    private func validationMarkerURL(for model: SpeechModelDescriptor) -> URL {
        WhisperCppSpeechBackend.modelURL(for: model).appendingPathExtension("validated")
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
