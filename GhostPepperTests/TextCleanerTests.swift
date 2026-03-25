import XCTest
@testable import GhostPepper

private final class SpyCleanupBackend: CleanupBackend {
    var cleanedInputs: [(text: String, prompt: String)] = []
    var nextResult: Result<String, Error>

    init(nextResult: Result<String, Error>) {
        self.nextResult = nextResult
    }

    func clean(text: String, prompt: String) async throws -> String {
        cleanedInputs.append((text: text, prompt: prompt))
        return try nextResult.get()
    }
}

@MainActor
final class TextCleanerTests: XCTestCase {
    func testPreferredTranscriptionsPreserveConfiguredPhrase() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.preferredTranscriptionsText = "Ghost Pepper"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "Ghost Pepper is ready", prompt: "unused prompt")

        XCTAssertEqual(result, "Ghost Pepper is ready")
        XCTAssertEqual(localBackend.cleanedInputs.map(\.text), ["Ghost Pepper is ready"])
    }

    func testCommonlyMisheardReplacementAppliesBeforeCleanup() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "chat gbt -> ChatGPT"
        let localBackend = SpyCleanupBackend(nextResult: .success("ChatGPT fixes text"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "chat gbt fixes text", prompt: "unused prompt")

        XCTAssertEqual(result, "ChatGPT fixes text")
        XCTAssertEqual(localBackend.cleanedInputs.map(\.text), ["ChatGPT fixes text"])
    }

    func testCleanerFallsBackToCorrectedRawTextWhenBackendFails() async {
        let localBackend = SpyCleanupBackend(nextResult: .failure(CleanupBackendError.unavailable))
        let cleaner = TextCleaner(
            localBackend: localBackend
        )
        let text = "Keep this exactly as spoken."

        let result = await cleaner.clean(text: text, prompt: "unused prompt")

        XCTAssertEqual(result, text)
        XCTAssertEqual(localBackend.cleanedInputs.map(\.text), [text])
    }

    func testDeterministicCorrectionsStillApplyWhenNoCleanupBackendIsAvailable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "just see -> Jesse"
        let localBackend = SpyCleanupBackend(nextResult: .failure(CleanupBackendError.unavailable))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "just see approved it", prompt: "unused prompt")

        XCTAssertEqual(result, "Jesse approved it")
    }

    func testPreferredTranscriptionsRestoreSpacingAfterCleanupMutatesPhrase() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.preferredTranscriptionsText = "Ghost Pepper"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost-pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "Ghost Pepper is ready", prompt: "unused prompt")

        XCTAssertEqual(result, "Ghost Pepper is ready")
    }

    func testCommonlyMisheardReplacementTreatsSpecialCharactersLiterally() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "environment -> $HOME C:\\\\temp"
        let localBackend = SpyCleanupBackend(nextResult: .failure(CleanupBackendError.unavailable))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )

        let result = await cleaner.clean(text: "environment", prompt: "unused prompt")

        XCTAssertEqual(result, #"$HOME C:\\temp"#)
    }

    func testCleanerStripsThinkBlocksFromCleanupOutput() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .success(
                """
                <think>
                internal reasoning
                </think>

                Final cleaned text
                """
            )
        )
        let cleaner = TextCleaner(
            localBackend: localBackend
        )

        let result = await cleaner.clean(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result, "Final cleaned text")
    }

    func testCleanerLogsPromptInputAndCorrectionStagesToSensitiveLogger() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "chat gbt -> ChatGPT"
        correctionStore.preferredTranscriptionsText = "Ghost Pepper"
        let localBackend = SpyCleanupBackend(nextResult: .success("ghost-pepper is ready"))
        let cleaner = TextCleaner(
            localBackend: localBackend,
            correctionStore: correctionStore
        )
        var sensitiveMessages: [String] = []
        cleaner.sensitiveDebugLogger = { _, message in
            sensitiveMessages.append(message)
        }

        let result = await cleaner.clean(
            text: "chat gbt is ready",
            prompt: "Use OCR context if present."
        )

        XCTAssertEqual(result, "Ghost Pepper is ready")
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Pre-cleanup corrections") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Cleanup prompt") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Cleanup LLM input") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Cleanup LLM raw output") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Post-cleanup corrections") }))
    }
}
