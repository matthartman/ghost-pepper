import XCTest
import Combine
@testable import GhostPepper

@MainActor
final class ModelManagerTests: XCTestCase {
    func testModelManagerRetriesTimedOutSpeechModelLoadOnce() async {
        let timeoutError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."]
        )
        var attempts = 0
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { _ in
                attempts += 1
                if attempts == 1 {
                    throw timeoutError
                }
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel(name: "openai_whisper-small.en")

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(manager.state, .ready)
        XCTAssertNil(manager.error)
    }

    func testDeleteCachedModelNotifiesObserversForInventoryRefresh() throws {
        let manager = ModelManager(modelName: "openai_whisper-small.en")
        let expectation = expectation(description: "model manager publishes cache deletion")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-tiny.en"))
        manager.deleteCachedModel(model)

        wait(for: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    func testDeleteCachedCurrentModelResetsReadyState() async throws {
        let manager = ModelManager(
            modelName: "openai_whisper-small.en",
            modelLoadOverride: { _ in }
        )

        await manager.loadModel(name: "openai_whisper-small.en")
        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "openai_whisper-small.en"))

        manager.deleteCachedModel(model)

        XCTAssertEqual(manager.state, .idle)
        XCTAssertNil(manager.error)
    }

    func testModelManagerLoadsWhisperCppQuantizedTurboThroughOverride() async {
        var loadedNames: [String] = []
        let manager = ModelManager(
            modelName: "ggml-large-v3-turbo-q5_0",
            modelLoadOverride: { descriptor in
                loadedNames.append(descriptor.name)
            },
            loadRetryDelayOverride: {}
        )

        await manager.loadModel()

        XCTAssertEqual(manager.state, .ready)
        XCTAssertNil(manager.error)
        XCTAssertEqual(loadedNames, ["ggml-large-v3-turbo-q5_0"])
    }

    func testDeleteCachedWhisperCppQuantizedTurboNotifiesObserversForInventoryRefresh() throws {
        let manager = ModelManager(modelName: "openai_whisper-small.en")
        let expectation = expectation(description: "whisper.cpp quantized turbo deletion publishes change")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "ggml-large-v3-turbo-q5_0"))
        manager.deleteCachedModel(model)

        wait(for: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    func testDeleteCachedWhisperCppTurboNotifiesObserversForInventoryRefresh() throws {
        let manager = ModelManager(modelName: "openai_whisper-small.en")
        let expectation = expectation(description: "whisper.cpp turbo deletion publishes change")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "ggml-large-v3-turbo"))
        manager.deleteCachedModel(model)

        wait(for: [expectation], timeout: 1.0)
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }

    func testModelManagerReportsErrorWhenWhisperCppValidationFails() async throws {
        let model = try XCTUnwrap(SpeechModelCatalog.model(named: "ggml-large-v3-turbo-q5_0"))
        let modelURL = WhisperCppSpeechBackend.modelURL(for: model)
        try FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("test".utf8).write(to: modelURL)
        defer { try? FileManager.default.removeItem(at: modelURL) }

        let manager = ModelManager(
            modelName: model.name,
            loadRetryDelayOverride: {},
            whisperCppExecutableURLOverride: {
                URL(fileURLWithPath: "/usr/bin/false")
            }
        )

        await manager.loadModel()

        XCTAssertEqual(manager.state, .error)
        XCTAssertNotNil(manager.error)
    }
}
