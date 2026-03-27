import XCTest
@testable import GhostPepper

private final class SpyCleanupBackend: CleanupBackend {
    var cleanedInputs: [(text: String, prompt: String, modelKind: LocalCleanupModelKind?)] = []
    var nextResult: Result<String, Error>

    init(nextResult: Result<String, Error>) {
        self.nextResult = nextResult
    }

    func clean(text: String, prompt: String, modelKind: LocalCleanupModelKind?) async throws -> String {
        cleanedInputs.append((text: text, prompt: prompt, modelKind: modelKind))
        return try nextResult.get()
    }
}

@MainActor
final class TextCleanerTests: XCTestCase {
    func testPreferredTranscriptionsPreserveConfiguredPhraseBeforeCleanup() async throws {
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

        XCTAssertEqual(result, "ghost pepper is ready")
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(rawTranscription: "Ghost Pepper is ready", normalizedTranscription: "Ghost Pepper is ready")]
        )
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
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(rawTranscription: "chat gbt fixes text", normalizedTranscription: "ChatGPT fixes text")]
        )
    }

    func testCleanerFallsBackToCorrectedRawTextWhenBackendFails() async {
        let localBackend = SpyCleanupBackend(nextResult: .failure(CleanupBackendError.unavailable))
        let cleaner = TextCleaner(
            localBackend: localBackend
        )
        let text = "Keep this exactly as spoken."

        let result = await cleaner.clean(text: text, prompt: "unused prompt")

        XCTAssertEqual(result, text)
        XCTAssertEqual(
            localBackend.cleanedInputs.map(\.text),
            [TextCleaner.formatCleanupInput(rawTranscription: text, normalizedTranscription: text)]
        )
    }

    func testCleanupInputWrapsRawAndNormalizedTranscription() {
        let formatted = TextCleaner.formatCleanupInput(
            rawTranscription: "chat gbt fixes text",
            normalizedTranscription: "ChatGPT fixes text"
        )

        XCTAssertTrue(formatted.contains("<TRANSCRIPTION_INPUT>"))
        XCTAssertTrue(formatted.contains("<RAW_TRANSCRIPTION>chat gbt fixes text</RAW_TRANSCRIPTION>"))
        XCTAssertTrue(formatted.contains("<NORMALIZED_TRANSCRIPTION>ChatGPT fixes text</NORMALIZED_TRANSCRIPTION>"))
        XCTAssertTrue(formatted.contains("</TRANSCRIPTION_INPUT>"))
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

    func testPreferredTranscriptionsDoNotRewriteCleanupOutput() async throws {
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

        XCTAssertEqual(result, "ghost-pepper is ready")
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

    func testCleanerStripsUnterminatedLeadingThinkBlockFromCleanupOutput() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .success(
                """
                <think>
                internal reasoning that never closes
                """
            )
        )
        let cleaner = TextCleaner(
            localBackend: localBackend
        )

        let result = await cleaner.clean(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result, "")
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

        XCTAssertEqual(result, "ghost-pepper is ready")
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Pre-cleanup corrections") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Cleanup LLM transcript") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("System prompt") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("User input") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Raw model output") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Final cleaned output") }))
        XCTAssertTrue(sensitiveMessages.contains(where: { $0.contains("Post-cleanup corrections") }))
    }

    func testCleanerReportsModelAndPostProcessingDurations() async {
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
        let cleaner = TextCleaner(localBackend: localBackend)

        let result = await cleaner.cleanWithPerformance(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result.text, "Final cleaned text")
        XCTAssertNotNil(result.performance.modelCallDuration)
        XCTAssertNotNil(result.performance.postProcessDuration)
    }

    func testCleanerCanForceSpecificCleanupModelKind() async {
        let localBackend = SpyCleanupBackend(nextResult: .success("cleaned"))
        let cleaner = TextCleaner(localBackend: localBackend)

        _ = await cleaner.cleanWithPerformance(
            text: "raw text",
            prompt: "unused prompt",
            modelKind: .fast
        )

        XCTAssertEqual(localBackend.cleanedInputs.map(\.modelKind), [.fast])
    }

    func testCleanerMarksFallbackAndPreservesTranscriptForUnusableModelOutput() async {
        let localBackend = SpyCleanupBackend(
            nextResult: .failure(CleanupBackendError.unusableOutput(rawOutput: "..."))
        )
        let cleaner = TextCleaner(localBackend: localBackend)

        let result = await cleaner.cleanWithPerformance(text: "raw text", prompt: "unused prompt")

        XCTAssertEqual(result.text, "raw text")
        XCTAssertTrue(result.usedFallback)
        XCTAssertNotNil(result.performance.modelCallDuration)
        XCTAssertEqual(result.transcript?.prompt, "unused prompt")
        XCTAssertEqual(
            result.transcript?.inputText,
            TextCleaner.formatCleanupInput(
                rawTranscription: "raw text",
                normalizedTranscription: "raw text"
            )
        )
        XCTAssertEqual(result.transcript?.rawOutput, "...")
    }
}
