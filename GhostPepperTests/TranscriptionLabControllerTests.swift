import XCTest
@testable import GhostPepper

@MainActor
final class TranscriptionLabControllerTests: XCTestCase {
    func testReloadEntriesSortsEntriesButStartsInBrowserMode() {
        let olderEntry = makeEntry(
            createdAt: Date(timeIntervalSince1970: 10),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        let newerEntry = makeEntry(
            createdAt: Date(timeIntervalSince1970: 20),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)"
        )

        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [olderEntry, newerEntry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in
                XCTFail("should not rerun during reload")
                return ""
            },
            runCleanup: { _, _, _, _, _ in
                XCTFail("should not rerun during reload")
                return TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()

        XCTAssertEqual(controller.entries.map { $0.id }, [newerEntry.id, olderEntry.id])
        XCTAssertNil(controller.selectedEntryID)
        XCTAssertEqual(controller.selectedSpeechModelID, SpeechModelCatalog.defaultModelID)
        XCTAssertEqual(controller.selectedCleanupModelKind, LocalCleanupModelKind.qwen35_4b_q4_k_m)
    }

    func testSelectingEntryDoesNotChangeCurrentRerunModels() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)"
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: "fluid_parakeet-v3",
            defaultCleanupModelKind: .qwen35_2b_q4_k_m,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertEqual(controller.selectedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertEqual(controller.selectedCleanupModelKind, .qwen35_2b_q4_k_m)
    }

    func testChangingRerunModelsImmediatelyInvokesSyncCallbacks() {
        var synchronizedSpeechModelIDs: [String] = []
        var synchronizedCleanupModelKinds: [LocalCleanupModelKind] = []
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultCleanupModelKind: .qwen35_4b_q4_k_m,
            loadStageTimings: { [:] },
            loadEntries: { [] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            syncSelectedSpeechModelID: { synchronizedSpeechModelIDs.append($0) },
            syncSelectedCleanupModelKind: { synchronizedCleanupModelKinds.append($0) }
        )

        controller.selectedSpeechModelID = "fluid_parakeet-v3"
        controller.selectedCleanupModelKind = .qwen35_2b_q4_k_m

        XCTAssertEqual(synchronizedSpeechModelIDs, ["fluid_parakeet-v3"])
        XCTAssertEqual(synchronizedCleanupModelKinds, [.qwen35_2b_q4_k_m])
    }

    func testChangingRerunModelsSupportsWhisperLargeV3Turbo() {
        var synchronizedSpeechModelIDs: [String] = []
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultCleanupModelKind: .qwen35_4b_q4_k_m,
            loadStageTimings: { [:] },
            loadEntries: { [] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            syncSelectedSpeechModelID: { synchronizedSpeechModelIDs.append($0) }
        )

        controller.selectedSpeechModelID = "openai_whisper-large-v3_turbo"

        XCTAssertEqual(synchronizedSpeechModelIDs, ["openai_whisper-large-v3_turbo"])
    }

    func testChangingRerunModelsSupportsWhisperCppLargeV3TurboQuantized() {
        var synchronizedSpeechModelIDs: [String] = []
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultCleanupModelKind: .qwen35_4b_q4_k_m,
            loadStageTimings: { [:] },
            loadEntries: { [] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            syncSelectedSpeechModelID: { synchronizedSpeechModelIDs.append($0) }
        )

        controller.selectedSpeechModelID = "ggml-large-v3-turbo-q5_0"

        XCTAssertEqual(synchronizedSpeechModelIDs, ["ggml-large-v3-turbo-q5_0"])
    }

    func testChangingRerunModelsSupportsWhisperCppLargeV3Turbo() {
        var synchronizedSpeechModelIDs: [String] = []
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultCleanupModelKind: .qwen35_4b_q4_k_m,
            loadStageTimings: { [:] },
            loadEntries: { [] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            syncSelectedSpeechModelID: { synchronizedSpeechModelIDs.append($0) }
        )

        controller.selectedSpeechModelID = "ggml-large-v3-turbo"

        XCTAssertEqual(synchronizedSpeechModelIDs, ["ggml-large-v3-turbo"])
    }

    func testStageRerunsUpdateExperimentOutputs() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        var executedCleanupPrompt: String?
        var executedSpeechModelID: String?
        var executedCleanupModelKind: LocalCleanupModelKind?
        var executedCleanupIncludesWindowContext: Bool?
        var cleanupInputText: String?
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: {
                [
                    entry.id: TranscriptionLabStageTimings(
                        transcriptionDuration: 0.42,
                        cleanupDuration: 0.91
                    )
                ]
            },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { rerunEntry, speechModelID in
                XCTAssertEqual(rerunEntry.id, entry.id)
                executedSpeechModelID = speechModelID
                try? await Task.sleep(nanoseconds: 20_000_000)
                return "raw rerun"
            },
            runCleanup: { rerunEntry, rawText, cleanupModelKind, prompt, includeWindowContext in
                XCTAssertEqual(rerunEntry.id, entry.id)
                cleanupInputText = rawText
                executedCleanupPrompt = prompt
                executedCleanupModelKind = cleanupModelKind
                executedCleanupIncludesWindowContext = includeWindowContext
                try? await Task.sleep(nanoseconds: 20_000_000)
                return TranscriptionLabCleanupResult(
                    correctedTranscription: "clean rerun",
                    cleanupUsedFallback: false,
                    transcript: TranscriptionLabCleanupTranscript(
                        prompt: prompt,
                        inputText: rawText,
                        rawModelOutput: "clean rerun raw"
                    )
                )
            }
        )
        controller.reloadEntries()
        controller.selectEntry(entry.id)
        controller.selectedSpeechModelID = "fluid_parakeet-v3"
        controller.selectedCleanupModelKind = .qwen35_4b_q4_k_m
        controller.usesCapturedOCR = false

        await controller.rerunTranscription()
        await controller.rerunCleanup(prompt: "custom prompt")

        XCTAssertEqual(executedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertEqual(cleanupInputText, "raw rerun")
        XCTAssertEqual(executedCleanupPrompt, "custom prompt")
        XCTAssertEqual(executedCleanupModelKind, .qwen35_4b_q4_k_m)
        XCTAssertEqual(executedCleanupIncludesWindowContext, false)
        XCTAssertEqual(controller.experimentRawTranscription, "raw rerun")
        XCTAssertEqual(controller.experimentCorrectedTranscription, "clean rerun")
        XCTAssertEqual(controller.originalTranscriptionDuration, 0.42)
        XCTAssertEqual(controller.originalCleanupDuration, 0.91)
        XCTAssertNotNil(controller.experimentTranscriptionDuration)
        XCTAssertNotNil(controller.experimentCleanupDuration)
        XCTAssertEqual(controller.latestCleanupTranscript?.prompt, "custom prompt")
        XCTAssertEqual(controller.latestCleanupTranscript?.inputText, "raw rerun")
        XCTAssertEqual(controller.latestCleanupTranscript?.rawModelOutput, "clean rerun raw")
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.runningStage)
    }

    func testStageRerunsUseWhisperLargeV3TurboSelection() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        var executedSpeechModelID: String?
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, speechModelID in
                executedSpeechModelID = speechModelID
                return "raw rerun"
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)
        controller.selectedSpeechModelID = "openai_whisper-large-v3_turbo"

        await controller.rerunTranscription()

        XCTAssertEqual(executedSpeechModelID, "openai_whisper-large-v3_turbo")
        XCTAssertEqual(controller.experimentRawTranscription, "raw rerun")
    }

    func testStageRerunsUseWhisperCppLargeV3TurboQuantizedSelection() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        var executedSpeechModelID: String?
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, speechModelID in
                executedSpeechModelID = speechModelID
                return "whisper.cpp rerun"
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)
        controller.selectedSpeechModelID = "ggml-large-v3-turbo-q5_0"

        await controller.rerunTranscription()

        XCTAssertEqual(executedSpeechModelID, "ggml-large-v3-turbo-q5_0")
        XCTAssertEqual(controller.experimentRawTranscription, "whisper.cpp rerun")
    }

    func testStageRerunsUseWhisperCppLargeV3TurboSelection() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        var executedSpeechModelID: String?
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, speechModelID in
                executedSpeechModelID = speechModelID
                return "whisper.cpp full rerun"
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)
        controller.selectedSpeechModelID = "ggml-large-v3-turbo"

        await controller.rerunTranscription()

        XCTAssertEqual(executedSpeechModelID, "ggml-large-v3-turbo")
        XCTAssertEqual(controller.experimentRawTranscription, "whisper.cpp full rerun")
    }

    func testDisplayedExperimentOutputsDefaultToOriginalOutputs() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertEqual(controller.displayedExperimentRawTranscription, "raw")
        XCTAssertEqual(controller.displayedExperimentCorrectedTranscription, "corrected")
    }

    func testDiarizationVisualizationUsesArchivedSummaryForSelectedEntry() {
        let diarizationSummary = DiarizationSummary(
            spans: [
                .init(speakerID: "Speaker 0", startTime: 0.0, endTime: 0.6, isKept: true),
                .init(speakerID: "Speaker 1", startTime: 0.6, endTime: 1.0, isKept: false),
                .init(speakerID: "Speaker 0", startTime: 1.0, endTime: 1.5, isKept: true)
            ],
            mergedKeptSpans: [
                .init(startTime: 0.0, endTime: 0.6),
                .init(startTime: 1.0, endTime: 1.5)
            ],
            targetSpeakerID: "Speaker 0",
            targetSpeakerDuration: 1.1,
            keptAudioDuration: 1.1,
            usedFallback: false,
            fallbackReason: nil
        )
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)",
            audioDuration: 1.5,
            diarizationSummary: diarizationSummary,
            speakerFilteringEnabled: true,
            speakerFilteringRan: true,
            speakerFilteringUsedFallback: false
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertEqual(
            controller.diarizationVisualization,
            .init(
                audioDuration: 1.5,
                targetSpeakerID: "Speaker 0",
                keptAudioDuration: 1.1,
                usedFallback: false,
                fallbackReason: nil,
                spans: [
                    .init(speakerID: "Speaker 0", startTime: 0.0, endTime: 0.6, isKept: true),
                    .init(speakerID: "Speaker 1", startTime: 0.6, endTime: 1.0, isKept: false),
                    .init(speakerID: "Speaker 0", startTime: 1.0, endTime: 1.5, isKept: true)
                ]
            )
        )
    }

    func testDiarizationVisualizationIsHiddenWithoutArchivedSummary() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _ in "" },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertNil(controller.diarizationVisualization)
    }

    func testTranscriptionLabTextDiffMarksInsertedAndRemovedRuns() {
        let diff = TranscriptionLabTextDiff.segments(
            from: "the quick brown fox",
            to: "the slower brown fox"
        )

        XCTAssertEqual(
            diff,
            [
                .init(kind: .unchanged, text: "the"),
                .init(kind: .removed, text: "quick"),
                .init(kind: .inserted, text: "slower"),
                .init(kind: .unchanged, text: "brown fox")
            ]
        )
    }

    func testTranscriptionLabTextDiffRefinesSingleCharacterChangeWithinToken() {
        let diff = TranscriptionLabTextDiff.segments(
            from: "delegation,",
            to: "delegation."
        )

        XCTAssertEqual(
            diff,
            [
                .init(kind: .unchanged, text: "delegation"),
                .init(kind: .removed, text: ","),
                .init(kind: .inserted, text: ".")
            ]
        )
    }

    private func makeEntry(
        createdAt: Date,
        speechModelID: String,
        cleanupModelName: String,
        audioDuration: TimeInterval = 1.25,
        diarizationSummary: DiarizationSummary? = nil,
        speakerFilteringEnabled: Bool = false,
        speakerFilteringRan: Bool = false,
        speakerFilteringUsedFallback: Bool = false
    ) -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: UUID(),
            createdAt: createdAt,
            audioFileName: "sample.bin",
            audioDuration: audioDuration,
            windowContext: OCRContext(windowContents: "Qwen 3.5 4B"),
            rawTranscription: "raw",
            correctedTranscription: "corrected",
            speechModelID: speechModelID,
            cleanupModelName: cleanupModelName,
            cleanupUsedFallback: false,
            speakerFilteringEnabled: speakerFilteringEnabled,
            speakerFilteringRan: speakerFilteringRan,
            speakerFilteringUsedFallback: speakerFilteringUsedFallback,
            diarizationSummary: diarizationSummary
        )
    }
}
