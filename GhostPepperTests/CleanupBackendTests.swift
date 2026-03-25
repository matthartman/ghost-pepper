import XCTest
@testable import GhostPepper

private final class SpyTextCleaningManager: TextCleaningManaging {
    var cleanedInputs: [(text: String, prompt: String?)] = []
    var nextResult: String?

    func clean(text: String, prompt: String?) async -> String? {
        cleanedInputs.append((text: text, prompt: prompt))
        return nextResult
    }
}

@MainActor
final class CleanupBackendTests: XCTestCase {
    func testLocalBackendUsesSelectedLocalPolicy() async throws {
        let manager = SpyTextCleaningManager()
        manager.nextResult = "local result"
        let backend = LocalLLMCleanupBackend(cleanupManager: manager)

        let result = try await backend.clean(text: "hello", prompt: "local prompt")

        XCTAssertEqual(result, "local result")
        XCTAssertEqual(manager.cleanedInputs.map(\.text), ["hello"])
        XCTAssertEqual(manager.cleanedInputs.map(\.prompt), ["local prompt"])
    }
}
