import XCTest
@testable import GhostPepper

private final class SpyTextCleaningManager: TextCleaningManaging {
    var cleanedInputs: [(text: String, prompt: String?, modelKind: LocalCleanupModelKind?)] = []
    var nextResult: Result<String, Error> = .failure(CleanupBackendError.unavailable)

    func clean(
        text: String,
        prompt: String?,
        modelKind: LocalCleanupModelKind?,
        timeout: TimeInterval?
    ) async throws -> String {
        cleanedInputs.append((text: text, prompt: prompt, modelKind: modelKind))
        return try nextResult.get()
    }
}

@MainActor
final class CleanupBackendTests: XCTestCase {
    func testLocalBackendUsesSelectedLocalPolicy() async throws {
        let manager = SpyTextCleaningManager()
        manager.nextResult = .success("local result")
        let backend = LocalLLMCleanupBackend(cleanupManager: manager)

        let result = try await backend.clean(text: "hello", prompt: "local prompt", modelKind: nil)

        XCTAssertEqual(result, "local result")
        XCTAssertEqual(manager.cleanedInputs.map(\.text), ["hello"])
        XCTAssertEqual(manager.cleanedInputs.map(\.prompt), ["local prompt"])
        XCTAssertEqual(manager.cleanedInputs.map(\.modelKind), [nil])
    }
}
