import XCTest
@testable import GhostPepper

@MainActor
final class TranscriptionLabRunnerTests: XCTestCase {
    func testRunnerRerunsSavedAudioWithStoredOCRContext() async throws {
        let entry = TranscriptionLabEntry(
            id: UUID(),
            createdAt: Date(),
            audioFileName: "sample.bin",
            audioDuration: 1.5,
            windowContext: OCRContext(windowContents: "Qwen 3.5 4B"),
            rawTranscription: "raw",
            correctedTranscription: "corrected",
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)",
            cleanupUsedFallback: false
        )
        var loadedSpeechModels: [String] = []
        var transcribedBuffers: [[Float]] = []
        var cleanedPrompts: [String] = []
        let correctionStore = CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { archivedEntry in
                XCTAssertEqual(archivedEntry.id, entry.id)
                return [0.1, 0.2, 0.3]
            },
            loadSpeechModel: { modelID in
                loadedSpeechModels.append(modelID)
            },
            transcribe: { audioBuffer in
                transcribedBuffers.append(audioBuffer)
                return "The default should be Quen three point five four b."
            },
            clean: { text, prompt, modelKind in
                XCTAssertEqual(text, "The default should be Quen three point five four b.")
                XCTAssertEqual(modelKind, .full)
                cleanedPrompts.append(prompt)
                return TextCleanerResult(
                    text: "The default should be Qwen 3.5 4B.",
                    performance: TextCleanerPerformance(
                        modelCallDuration: 0.4,
                        postProcessDuration: 0.01
                    ),
                    transcript: TextCleanerTranscript(
                        prompt: prompt,
                        inputText: TextCleaner.formatCleanupInput(
                            userInput: "The default should be Quen three point five four b."
                        ),
                        rawOutput: "The default should be Qwen 3.5 4B."
                    )
                )
            },
            correctionStore: correctionStore
        )

        let rawTranscription = try await runner.rerunTranscription(
            entry: entry,
            speechModelID: "fluid_parakeet-v3",
            acquirePipeline: { true },
            releasePipeline: {}
        )
        let result = try await runner.rerunCleanup(
            entry: entry,
            rawTranscription: rawTranscription,
            cleanupModelKind: .full,
            prompt: TextCleaner.defaultPrompt,
            includeWindowContext: true,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertEqual(loadedSpeechModels, ["fluid_parakeet-v3"])
        XCTAssertEqual(transcribedBuffers, [[0.1, 0.2, 0.3]])
        XCTAssertEqual(rawTranscription, "The default should be Quen three point five four b.")
        XCTAssertEqual(result.correctedTranscription, "The default should be Qwen 3.5 4B.")
        XCTAssertFalse(result.cleanupUsedFallback)
        XCTAssertEqual(
            result.transcript?.inputText,
            TextCleaner.formatCleanupInput(
                userInput: "The default should be Quen three point five four b."
            )
        )
        XCTAssertEqual(result.transcript?.rawModelOutput, "The default should be Qwen 3.5 4B.")
        XCTAssertTrue(cleanedPrompts[0].contains("Qwen 3.5 4B"))
        XCTAssertTrue(result.transcript?.prompt.contains("Qwen 3.5 4B") == true)
    }

    func testRunnerReturnsBusyWhenPipelineCannotBeAcquired() async {
        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in
                XCTFail("should not load audio when busy")
                return []
            },
            loadSpeechModel: { _ in
                XCTFail("should not load model when busy")
            },
            transcribe: { _ in
                XCTFail("should not transcribe when busy")
                return nil
            },
            clean: { _, _, _ in
                XCTFail("should not clean when busy")
                return TextCleanerResult(
                    text: "",
                    performance: TextCleanerPerformance(modelCallDuration: nil, postProcessDuration: nil)
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        do {
            _ = try await runner.rerunTranscription(
                entry: makeEntry(),
                speechModelID: "fluid_parakeet-v3",
                acquirePipeline: { false },
                releasePipeline: {}
            )
            XCTFail("Expected busy error")
        } catch {
            XCTAssertEqual(error as? TranscriptionLabRunnerError, .pipelineBusy)
        }
    }

    func testRunnerReportsCleanupFallbackWhenModelDidNotRun() async throws {
        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in [0.1] },
            loadSpeechModel: { _ in },
            transcribe: { _ in "raw text" },
            clean: { _, _, _ in
                TextCleanerResult(
                    text: "raw text",
                    performance: TextCleanerPerformance(
                        modelCallDuration: nil,
                        postProcessDuration: 0.01
                    ),
                    usedFallback: true
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        let result = try await runner.rerunCleanup(
            entry: makeEntry(),
            rawTranscription: "raw text",
            cleanupModelKind: .fast,
            prompt: TextCleaner.defaultPrompt,
            includeWindowContext: false,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertTrue(result.cleanupUsedFallback)
        XCTAssertEqual(result.correctedTranscription, "raw text")
        XCTAssertEqual(result.transcript?.inputText, "raw text")
        XCTAssertTrue(result.transcript?.prompt.contains("window text") == false)
        XCTAssertNil(result.transcript?.rawModelOutput)
    }

    func testRunnerReportsCleanupFallbackWhenModelReturnedUnusableOutput() async throws {
        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in [0.1] },
            loadSpeechModel: { _ in },
            transcribe: { _ in "raw text" },
            clean: { _, prompt, _ in
                TextCleanerResult(
                    text: "raw text",
                    performance: TextCleanerPerformance(
                        modelCallDuration: 0.02,
                        postProcessDuration: 0.01
                    ),
                    transcript: TextCleanerTranscript(
                        prompt: prompt,
                        inputText: TextCleaner.formatCleanupInput(userInput: "raw text"),
                        rawOutput: "..."
                    ),
                    usedFallback: true
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        let result = try await runner.rerunCleanup(
            entry: makeEntry(),
            rawTranscription: "raw text",
            cleanupModelKind: .fast,
            prompt: TextCleaner.defaultPrompt,
            includeWindowContext: false,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertTrue(result.cleanupUsedFallback)
        XCTAssertEqual(result.correctedTranscription, "raw text")
        XCTAssertEqual(
            result.transcript?.inputText,
            TextCleaner.formatCleanupInput(userInput: "raw text")
        )
        XCTAssertEqual(result.transcript?.rawModelOutput, "...")
    }

    private func makeEntry() -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: UUID(),
            createdAt: Date(),
            audioFileName: "sample.bin",
            audioDuration: 1.0,
            windowContext: OCRContext(windowContents: "window text"),
            rawTranscription: "raw",
            correctedTranscription: "corrected",
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)",
            cleanupUsedFallback: false
        )
    }
}
