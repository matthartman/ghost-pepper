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
            runSpeakerTagging: { _ in
                XCTFail("speaker tagging should be disabled for this rerun")
                return nil
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

        let transcriptionResult = try await runner.rerunTranscription(
            entry: entry,
            speechModelID: "fluid_parakeet-v3",
            speakerTaggingEnabled: false,
            acquirePipeline: { true },
            releasePipeline: {}
        )
        let result = try await runner.rerunCleanup(
            entry: entry,
            rawTranscription: transcriptionResult.rawTranscription,
            cleanupModelKind: .full,
            prompt: TextCleaner.defaultPrompt,
            includeWindowContext: true,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertEqual(loadedSpeechModels, ["fluid_parakeet-v3"])
        XCTAssertEqual(transcribedBuffers, [[0.1, 0.2, 0.3]])
        XCTAssertEqual(transcriptionResult.rawTranscription, "The default should be Quen three point five four b.")
        XCTAssertNil(transcriptionResult.diarizationSummary)
        XCTAssertNil(transcriptionResult.speakerTaggedTranscript)
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
            runSpeakerTagging: { _ in
                XCTFail("should not run speaker tagging when busy")
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
                speakerTaggingEnabled: false,
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
            runSpeakerTagging: { _ in nil },
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
            runSpeakerTagging: { _ in nil },
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

    func testRunnerUsesSpeakerTaggedResultWhenRequested() async throws {
        let diarizationSummary = DiarizationSummary(
            spans: [
                .init(speakerID: "Speaker 0", startTime: 0.0, endTime: 0.6, isKept: true),
                .init(speakerID: "Speaker 1", startTime: 0.6, endTime: 1.0, isKept: false),
            ],
            mergedKeptSpans: [
                .init(startTime: 0.0, endTime: 0.6),
            ],
            targetSpeakerID: "Speaker 0",
            targetSpeakerDuration: 0.6,
            keptAudioDuration: 0.6,
            usedFallback: false,
            fallbackReason: nil
        )
        var transcribeCallCount = 0
        var speakerTaggingCallCount = 0
        let entry = makeEntry()
        let resolvedProfiles = [
            TranscriptionLabSpeakerProfile(
                entryID: entry.id,
                speakerID: "Speaker 0",
                displayName: "Jesse",
                isMe: true,
                recognizedVoiceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000CC"),
                evidenceTranscript: "filtered transcript"
            )
        ]
        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in [0.1, 0.2, 0.3] },
            loadSpeechModel: { _ in },
            transcribe: { _ in
                transcribeCallCount += 1
                return "full transcript"
            },
            runSpeakerTagging: { audioBuffer in
                speakerTaggingCallCount += 1
                XCTAssertEqual(audioBuffer, [0.1, 0.2, 0.3])
                return SpeakerTaggedTranscriptionResult(
                    filteredTranscript: "filtered transcript",
                    diarizationSummary: diarizationSummary,
                    speakerTaggedTranscript: SpeakerTaggedTranscript(
                        segments: [
                            .init(
                                speakerID: "Speaker 0",
                                startTime: 0.0,
                                endTime: 0.6,
                                text: "filtered transcript"
                            )
                        ]
                    )
                )
            },
            resolveSpeakerProfiles: { entryID, audioBuffer, summary, speakerTaggedTranscript in
                XCTAssertEqual(entryID, entry.id)
                XCTAssertEqual(audioBuffer, [0.1, 0.2, 0.3])
                XCTAssertEqual(summary, diarizationSummary)
                XCTAssertEqual(
                    speakerTaggedTranscript,
                    SpeakerTaggedTranscript(
                        segments: [
                            .init(
                                speakerID: "Speaker 0",
                                startTime: 0.0,
                                endTime: 0.6,
                                text: "filtered transcript"
                            )
                        ]
                    )
                )
                return resolvedProfiles
            },
            clean: { _, _, _ in
                XCTFail("cleanup should not run in this test")
                return TextCleanerResult(
                    text: "",
                    performance: TextCleanerPerformance(modelCallDuration: nil, postProcessDuration: nil)
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        let result = try await runner.rerunTranscription(
            entry: entry,
            speechModelID: "fluid_parakeet-v3",
            speakerTaggingEnabled: true,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertEqual(result.rawTranscription, "filtered transcript")
        XCTAssertEqual(result.diarizationSummary, diarizationSummary)
        XCTAssertEqual(
            result.speakerTaggedTranscript,
            SpeakerTaggedTranscript(
                segments: [
                    .init(
                        speakerID: "Speaker 0",
                        startTime: 0.0,
                        endTime: 0.6,
                        text: "filtered transcript"
                    )
                ]
            )
        )
        XCTAssertEqual(result.speakerProfiles, resolvedProfiles)
        XCTAssertEqual(speakerTaggingCallCount, 1)
        XCTAssertEqual(transcribeCallCount, 0)
    }

    func testRunnerIncludesSpeakerTaggedSegmentsForMatchingRecognizedVoice() async throws {
        let recognizedVoiceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
        let diarizationSummary = DiarizationSummary(
            spans: [
                .init(speakerID: "Speaker 0", startTime: 0.0, endTime: 0.6, isKept: true),
                .init(speakerID: "Speaker 1", startTime: 0.6, endTime: 1.1, isKept: false),
            ],
            mergedKeptSpans: [
                .init(startTime: 0.0, endTime: 0.6),
            ],
            targetSpeakerID: "Speaker 0",
            targetSpeakerDuration: 0.6,
            keptAudioDuration: 0.6,
            usedFallback: false,
            fallbackReason: nil
        )
        let speakerTaggedTranscript = SpeakerTaggedTranscript(
            segments: [
                .init(
                    speakerID: "Speaker 0",
                    startTime: 0.0,
                    endTime: 0.6,
                    text: "First Jesse segment."
                ),
                .init(
                    speakerID: "Speaker 1",
                    startTime: 0.6,
                    endTime: 1.1,
                    text: "Second Jesse segment."
                ),
            ]
        )
        var transcribeCallCount = 0
        let entry = makeEntry()
        let resolvedProfiles = [
            TranscriptionLabSpeakerProfile(
                entryID: entry.id,
                speakerID: "Speaker 0",
                displayName: "Jesse Vincent",
                isMe: true,
                recognizedVoiceID: recognizedVoiceID,
                evidenceTranscript: "First Jesse segment."
            ),
            TranscriptionLabSpeakerProfile(
                entryID: entry.id,
                speakerID: "Speaker 1",
                displayName: "Jesse Vincent",
                isMe: true,
                recognizedVoiceID: recognizedVoiceID,
                evidenceTranscript: "Second Jesse segment."
            )
        ]
        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in [0.1, 0.2, 0.3] },
            loadSpeechModel: { _ in },
            transcribe: { _ in
                transcribeCallCount += 1
                return "full transcript"
            },
            runSpeakerTagging: { _ in
                SpeakerTaggedTranscriptionResult(
                    filteredTranscript: "First Jesse segment.",
                    diarizationSummary: diarizationSummary,
                    speakerTaggedTranscript: speakerTaggedTranscript
                )
            },
            resolveSpeakerProfiles: { entryID, _, summary, taggedTranscript in
                XCTAssertEqual(entryID, entry.id)
                XCTAssertEqual(summary, diarizationSummary)
                XCTAssertEqual(taggedTranscript, speakerTaggedTranscript)
                return resolvedProfiles
            },
            clean: { _, _, _ in
                XCTFail("cleanup should not run in this test")
                return TextCleanerResult(
                    text: "",
                    performance: TextCleanerPerformance(modelCallDuration: nil, postProcessDuration: nil)
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        let result = try await runner.rerunTranscription(
            entry: entry,
            speechModelID: "fluid_parakeet-v3",
            speakerTaggingEnabled: true,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertEqual(result.rawTranscription, "First Jesse segment. Second Jesse segment.")
        XCTAssertEqual(result.diarizationSummary, diarizationSummary)
        XCTAssertEqual(result.speakerTaggedTranscript, speakerTaggedTranscript)
        XCTAssertEqual(result.speakerProfiles, resolvedProfiles)
        XCTAssertEqual(transcribeCallCount, 0)
    }

    func testRunnerFallsBackToFullTranscriptionWhenSpeakerTaggingFallsBack() async throws {
        let diarizationSummary = DiarizationSummary(
            spans: [],
            mergedKeptSpans: [],
            targetSpeakerID: nil,
            targetSpeakerDuration: 0,
            keptAudioDuration: 0,
            usedFallback: true,
            fallbackReason: .ambiguousDominantSpeaker
        )
        var transcribeCallCount = 0
        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in [0.1, 0.2, 0.3] },
            loadSpeechModel: { _ in },
            transcribe: { _ in
                transcribeCallCount += 1
                return "full transcript"
            },
            runSpeakerTagging: { _ in
                SpeakerTaggedTranscriptionResult(
                    filteredTranscript: nil,
                    diarizationSummary: diarizationSummary,
                    speakerTaggedTranscript: nil
                )
            },
            clean: { _, _, _ in
                XCTFail("cleanup should not run in this test")
                return TextCleanerResult(
                    text: "",
                    performance: TextCleanerPerformance(modelCallDuration: nil, postProcessDuration: nil)
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        let result = try await runner.rerunTranscription(
            entry: makeEntry(),
            speechModelID: "fluid_parakeet-v3",
            speakerTaggingEnabled: true,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertEqual(result.rawTranscription, "full transcript")
        XCTAssertEqual(result.diarizationSummary, diarizationSummary)
        XCTAssertNil(result.speakerTaggedTranscript)
        XCTAssertEqual(transcribeCallCount, 1)
    }

    func testRunnerRepairsSingleSpeakerTranscriptWhenEmptyFilteredFallbackReturnsBogusSegment() async throws {
        let diarizationSummary = DiarizationSummary(
            spans: [
                .init(speakerID: "Speaker 0", startTime: 2.48, endTime: 4.32, isKept: true)
            ],
            mergedKeptSpans: [
                .init(startTime: 2.48, endTime: 4.32)
            ],
            targetSpeakerID: "Speaker 0",
            targetSpeakerDuration: 1.84,
            keptAudioDuration: 1.84,
            usedFallback: true,
            fallbackReason: .emptyFilteredTranscription
        )
        let entry = makeEntry()
        let repairedSpeakerTaggedTranscript = SpeakerTaggedTranscript(
            segments: [
                .init(
                    speakerID: "Speaker 0",
                    startTime: 2.48,
                    endTime: 4.32,
                    text: "And that have been around a long time."
                )
            ]
        )
        var resolvedSpeakerTaggedTranscript: SpeakerTaggedTranscript?

        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in [0.1, 0.2, 0.3] },
            loadSpeechModel: { _ in },
            transcribe: { _ in
                "And that have been around a long time."
            },
            runSpeakerTagging: { _ in
                SpeakerTaggedTranscriptionResult(
                    filteredTranscript: nil,
                    diarizationSummary: diarizationSummary,
                    speakerTaggedTranscript: SpeakerTaggedTranscript(
                        segments: [
                            .init(
                                speakerID: "Speaker 0",
                                startTime: 2.48,
                                endTime: 4.32,
                                text: "Yeah."
                            )
                        ]
                    )
                )
            },
            resolveSpeakerProfiles: { entryID, _, summary, speakerTaggedTranscript in
                XCTAssertEqual(entryID, entry.id)
                XCTAssertEqual(summary, diarizationSummary)
                resolvedSpeakerTaggedTranscript = speakerTaggedTranscript
                return []
            },
            clean: { _, _, _ in
                XCTFail("cleanup should not run in this test")
                return TextCleanerResult(
                    text: "",
                    performance: TextCleanerPerformance(modelCallDuration: nil, postProcessDuration: nil)
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        let result = try await runner.rerunTranscription(
            entry: entry,
            speechModelID: "fluid_parakeet-v3",
            speakerTaggingEnabled: true,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertEqual(result.rawTranscription, "And that have been around a long time.")
        XCTAssertEqual(result.diarizationSummary, diarizationSummary)
        XCTAssertEqual(result.speakerTaggedTranscript, repairedSpeakerTaggedTranscript)
        XCTAssertEqual(resolvedSpeakerTaggedTranscript, repairedSpeakerTaggedTranscript)
    }

    func testRunnerRepairsSingleSpeakerTranscriptWhenSingleSpeakerFallbackReturnsBogusSegment() async throws {
        let diarizationSummary = DiarizationSummary(
            spans: [
                .init(speakerID: "Speaker 0", startTime: 2.48, endTime: 4.24, isKept: true)
            ],
            mergedKeptSpans: [
                .init(startTime: 2.48, endTime: 4.24)
            ],
            targetSpeakerID: "Speaker 0",
            targetSpeakerDuration: 1.76,
            keptAudioDuration: 1.76,
            usedFallback: true,
            fallbackReason: .singleDetectedSpeaker
        )
        let entry = makeEntry()
        let repairedSpeakerTaggedTranscript = SpeakerTaggedTranscript(
            segments: [
                .init(
                    speakerID: "Speaker 0",
                    startTime: 2.48,
                    endTime: 4.24,
                    text: "And that have been around a long time."
                )
            ]
        )
        var resolvedSpeakerTaggedTranscript: SpeakerTaggedTranscript?

        let runner = TranscriptionLabRunner(
            loadAudioBuffer: { _ in [0.1, 0.2, 0.3] },
            loadSpeechModel: { _ in },
            transcribe: { _ in
                "And that have been around a long time."
            },
            runSpeakerTagging: { _ in
                SpeakerTaggedTranscriptionResult(
                    filteredTranscript: nil,
                    diarizationSummary: diarizationSummary,
                    speakerTaggedTranscript: SpeakerTaggedTranscript(
                        segments: [
                            .init(
                                speakerID: "Speaker 0",
                                startTime: 2.48,
                                endTime: 4.24,
                                text: "Yeah."
                            )
                        ]
                    )
                )
            },
            resolveSpeakerProfiles: { entryID, _, summary, speakerTaggedTranscript in
                XCTAssertEqual(entryID, entry.id)
                XCTAssertEqual(summary, diarizationSummary)
                resolvedSpeakerTaggedTranscript = speakerTaggedTranscript
                return []
            },
            clean: { _, _, _ in
                XCTFail("cleanup should not run in this test")
                return TextCleanerResult(
                    text: "",
                    performance: TextCleanerPerformance(modelCallDuration: nil, postProcessDuration: nil)
                )
            },
            correctionStore: CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        )

        let result = try await runner.rerunTranscription(
            entry: entry,
            speechModelID: "fluid_parakeet-v3",
            speakerTaggingEnabled: true,
            acquirePipeline: { true },
            releasePipeline: {}
        )

        XCTAssertEqual(result.rawTranscription, "And that have been around a long time.")
        XCTAssertEqual(result.diarizationSummary, diarizationSummary)
        XCTAssertEqual(result.speakerTaggedTranscript, repairedSpeakerTaggedTranscript)
        XCTAssertEqual(resolvedSpeakerTaggedTranscript, repairedSpeakerTaggedTranscript)
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
