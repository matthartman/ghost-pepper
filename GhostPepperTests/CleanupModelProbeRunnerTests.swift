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
            modelDisplayName: "Qwen 3.5 2B (fast cleanup)",
            thinkingMode: .none,
            input: "Okay, it's running now.",
            correctedInput: "Okay, it's running now.",
            modelInput: TextCleaner.formatCleanupInput(userInput: "Okay, it's running now."),
            finalPrompt: "System prompt",
            rawModelOutput: "<think>\nReasoning",
            sanitizedOutput: "",
            finalOutput: "",
            elapsed: 1.25
        )

        let formatted = CleanupModelProbeCLI.format(transcript)

        XCTAssertTrue(formatted.contains("Model: Qwen 3.5 2B (fast cleanup) [fast]"))
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
                    modelDisplayName: "Qwen 3.5 2B (fast cleanup)",
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

        XCTAssertEqual(transcript.correctedInput, "Okay, it's running now.")
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
        XCTAssertEqual(transcript.modelDisplayName, "Qwen 3.5 2B (fast cleanup)")
        XCTAssertEqual(transcript.elapsed, 1.25, accuracy: 0.001)
    }

    func testRunnerWrapsRawAndNormalizedInputBeforeModelExecution() async {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer { defaults.removePersistentDomain(forName: #function) }
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "chat gbt -> ChatGPT"

        let runner = CleanupModelProbeRunner(
            correctionStore: correctionStore,
            promptBuilder: CleanupPromptBuilder(),
            execute: { input, _, _, _ in
                XCTAssertEqual(
                    input,
                    TextCleaner.formatCleanupInput(userInput: "ChatGPT fixes text")
                )

                return CleanupModelProbeRawResult(
                    modelKind: .fast,
                    modelDisplayName: "Qwen 3.5 2B (fast cleanup)",
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

        XCTAssertEqual(transcript.correctedInput, "ChatGPT fixes text")
        XCTAssertEqual(
            transcript.modelInput,
            TextCleaner.formatCleanupInput(userInput: "ChatGPT fixes text")
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
                    modelDisplayName: "Qwen 3.5 4B (full cleanup)",
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
}
