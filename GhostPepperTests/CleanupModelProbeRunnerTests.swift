import XCTest
@testable import GhostPepper

@MainActor
final class CleanupModelProbeRunnerTests: XCTestCase {
    func testCLIParsesOneShotArguments() throws {
        let command = try CleanupModelProbeCLI.parse(arguments: [
            "--model", "fast",
            "--input", "Okay, it's running now.",
            "--thinking", "suppressed",
            "--window-context", "Terminal says hello"
        ])

        XCTAssertEqual(command.modelKind, .fast)
        XCTAssertEqual(command.input, "Okay, it's running now.")
        XCTAssertEqual(command.thinkingMode, .suppressed)
        XCTAssertEqual(command.windowContext, "Terminal says hello")
        XCTAssertFalse(command.isInteractive)
    }

    func testCLIFormatsTranscriptForOneShotRuns() {
        let transcript = CleanupModelProbeTranscript(
            modelKind: .fast,
            modelDisplayName: TextCleanupManager.recommendedFastModel.displayName,
            thinkingMode: .none,
            input: "Okay, it's running now.",
            modelInputText: "Okay, it's running now.",
            modelInput: TextCleaner.formatCleanupInput(userInput: "Okay, it's running now."),
            finalPrompt: "System prompt",
            rawModelOutput: "<think>\nReasoning",
            sanitizedOutput: "",
            finalOutput: "",
            elapsed: 1.25
        )

        let formatted = CleanupModelProbeCLI.format(transcript)

        XCTAssertTrue(formatted.contains("Model: \(TextCleanupManager.recommendedFastModel.displayName) [fast]"))
        XCTAssertTrue(formatted.contains("Thinking mode: none"))
        XCTAssertTrue(formatted.contains("Prompt:\nSystem prompt"))
        XCTAssertTrue(formatted.contains("Raw model output:\n<think>\nReasoning"))
        XCTAssertTrue(formatted.contains("Sanitized model output:\n"))
        XCTAssertTrue(formatted.contains("Final cleaned output:\n"))
    }

    func testCLIExitsInteractiveModeOnQuitOrEOF() {
        XCTAssertTrue(CleanupModelProbeCLI.shouldExitInteractive(input: ":quit"))
        XCTAssertTrue(CleanupModelProbeCLI.shouldExitInteractive(input: nil))
        XCTAssertFalse(CleanupModelProbeCLI.shouldExitInteractive(input: "keep going"))
    }

    func testRunnerCapturesRawAndSanitizedStagesSeparately() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let runner = CleanupModelProbeRunner(
            correctionStore: CorrectionStore(defaults: defaults),
            promptBuilder: CleanupPromptBuilder(),
            execute: { input, prompt, modelKind, thinkingMode in
                XCTAssertEqual(
                    input,
                    TextCleaner.formatCleanupInput(userInput: "Okay, it's running now.")
                )
                XCTAssertEqual(prompt, TextCleaner.defaultPrompt)
                XCTAssertEqual(modelKind, .fast)
                XCTAssertEqual(thinkingMode, .none)

                return CleanupModelProbeRawResult(
                    modelKind: .fast,
                    modelDisplayName: TextCleanupManager.recommendedFastModel.displayName,
                    rawOutput: """
                    <think>
                    Okay, the user said "Okay, it's running now."
                    """,
                    elapsed: 1.25
                )
            }
        )

        let transcript = try! await runner.run(
            input: "Okay, it's running now.",
            modelKind: .fast,
            thinkingMode: .none
        )

        XCTAssertEqual(transcript.modelInputText, "Okay, it's running now.")
        XCTAssertEqual(
            transcript.modelInput,
            TextCleaner.formatCleanupInput(userInput: "Okay, it's running now.")
        )
        XCTAssertEqual(
            transcript.rawModelOutput,
            """
            <think>
            Okay, the user said "Okay, it's running now."
            """
        )
        XCTAssertEqual(transcript.sanitizedOutput, "")
        XCTAssertEqual(transcript.finalOutput, "")
        XCTAssertEqual(transcript.modelDisplayName, TextCleanupManager.recommendedFastModel.displayName)
        XCTAssertEqual(transcript.elapsed, 1.25, accuracy: 0.001)
    }

    func testRunnerWrapsRawInputAndLeavesCorrectionHintsInPrompt() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "chat gbt -> ChatGPT"

        let runner = CleanupModelProbeRunner(
            correctionStore: correctionStore,
            promptBuilder: CleanupPromptBuilder(),
            execute: { input, prompt, _, _ in
                XCTAssertEqual(
                    input,
                    TextCleaner.formatCleanupInput(userInput: "chat gbt fixes text")
                )
                XCTAssertTrue(prompt.contains("Commonly misheard replacements to prefer:"))
                XCTAssertTrue(prompt.contains("- chat gbt -> ChatGPT"))

                return CleanupModelProbeRawResult(
                    modelKind: .fast,
                    modelDisplayName: TextCleanupManager.recommendedFastModel.displayName,
                    rawOutput: "ChatGPT fixes text",
                    elapsed: 0.25
                )
            }
        )

        let transcript = try! await runner.run(
            input: "chat gbt fixes text",
            modelKind: .fast,
            thinkingMode: .suppressed
        )

        XCTAssertEqual(transcript.modelInputText, "chat gbt fixes text")
        XCTAssertEqual(
            transcript.modelInput,
            TextCleaner.formatCleanupInput(userInput: "chat gbt fixes text")
        )
        XCTAssertEqual(transcript.finalOutput, "ChatGPT fixes text")
    }

    func testRunnerBuildsPromptWithOptionalWindowContext() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let runner = CleanupModelProbeRunner(
            correctionStore: CorrectionStore(defaults: defaults),
            promptBuilder: CleanupPromptBuilder(),
            execute: { _, prompt, _, _ in
                XCTAssertTrue(prompt.contains("Use the window OCR only as supporting context"))
                XCTAssertTrue(prompt.contains("<WINDOW-OCR-CONTENT>"))
                XCTAssertTrue(prompt.contains("Terminal says hello"))

                return CleanupModelProbeRawResult(
                    modelKind: .full,
                    modelDisplayName: TextCleanupManager.recommendedFullModel.displayName,
                    rawOutput: "Terminal says hello",
                    elapsed: 0.5
                )
            }
        )

        let transcript = try! await runner.run(
            input: "Terminal says hello",
            modelKind: .full,
            thinkingMode: .suppressed,
            prompt: TextCleaner.defaultPrompt,
            windowContext: OCRContext(windowContents: "Terminal says hello")
        )

        XCTAssertEqual(transcript.finalPrompt, CleanupPromptBuilder().buildPrompt(
            basePrompt: TextCleaner.defaultPrompt,
            windowContext: OCRContext(windowContents: "Terminal says hello"),
            includeWindowContext: true
        ))
        XCTAssertEqual(transcript.finalOutput, "Terminal says hello")
        XCTAssertEqual(transcript.thinkingMode, .suppressed)
    }

    func testRunnerLeavesPromptUnchangedForCompactCleanupModel() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }

        let runner = CleanupModelProbeRunner(
            correctionStore: CorrectionStore(defaults: defaults),
            promptBuilder: CleanupPromptBuilder(),
            execute: { _, prompt, modelKind, _ in
                XCTAssertEqual(modelKind, .qwen35_0_8b_q4_k_m)
                XCTAssertEqual(prompt, "Base prompt")

                return CleanupModelProbeRawResult(
                    modelKind: .qwen35_0_8b_q4_k_m,
                    modelDisplayName: "Qwen 3.5 0.8B Q4_K_M",
                    rawOutput: "Base output",
                    elapsed: 0.5
                )
            }
        )

        let transcript = try! await runner.run(
            input: "Base input",
            modelKind: .qwen35_0_8b_q4_k_m,
            thinkingMode: .suppressed,
            prompt: "Base prompt"
        )

        XCTAssertEqual(transcript.finalPrompt, "Base prompt")
    }
}
