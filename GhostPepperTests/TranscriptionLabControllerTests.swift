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
            defaultSpeakerTaggingEnabled: false,
            loadStageTimings: { [:] },
            loadEntries: { [olderEntry, newerEntry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                XCTFail("should not rerun during reload")
                return TranscriptionLabTranscriptionResult(rawTranscription: "")
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
        XCTAssertFalse(controller.usesSpeakerTagging)
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
            defaultSpeakerTaggingEnabled: true,
            defaultCleanupModelKind: .qwen35_2b_q4_k_m,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertEqual(controller.selectedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertTrue(controller.usesSpeakerTagging)
        XCTAssertEqual(controller.selectedCleanupModelKind, .qwen35_2b_q4_k_m)
    }

    func testChangingRerunControlsImmediatelyInvokesSyncCallbacks() {
        var synchronizedSpeechModelIDs: [String] = []
        var synchronizedSpeakerTaggingStates: [Bool] = []
        var synchronizedCleanupModelKinds: [LocalCleanupModelKind] = []
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultSpeakerTaggingEnabled: false,
            defaultCleanupModelKind: .qwen35_4b_q4_k_m,
            loadStageTimings: { [:] },
            loadEntries: { [] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            syncSelectedSpeechModelID: { synchronizedSpeechModelIDs.append($0) },
            syncSpeakerTaggingEnabled: { synchronizedSpeakerTaggingStates.append($0) },
            syncSelectedCleanupModelKind: { synchronizedCleanupModelKinds.append($0) }
        )

        controller.selectedSpeechModelID = "fluid_parakeet-v3"
        controller.usesSpeakerTagging = true
        controller.selectedCleanupModelKind = .qwen35_2b_q4_k_m

        XCTAssertEqual(synchronizedSpeechModelIDs, ["fluid_parakeet-v3"])
        XCTAssertEqual(synchronizedSpeakerTaggingStates, [true])
        XCTAssertEqual(synchronizedCleanupModelKinds, [.qwen35_2b_q4_k_m])
    }

    func testStageRerunsUpdateExperimentOutputs() async {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        var executedCleanupPrompt: String?
        var executedSpeechModelID: String?
        var executedSpeakerTaggingEnabled: Bool?
        var executedCleanupModelKind: LocalCleanupModelKind?
        var executedCleanupIncludesWindowContext: Bool?
        var cleanupInputText: String?
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
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultSpeakerTaggingEnabled: false,
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
            runTranscription: { rerunEntry, speechModelID, speakerTaggingEnabled in
                XCTAssertEqual(rerunEntry.id, entry.id)
                executedSpeechModelID = speechModelID
                executedSpeakerTaggingEnabled = speakerTaggingEnabled
                try? await Task.sleep(nanoseconds: 20_000_000)
                return TranscriptionLabTranscriptionResult(
                    rawTranscription: "raw rerun",
                    diarizationSummary: diarizationSummary,
                    speakerTaggedTranscript: SpeakerTaggedTranscript(
                        segments: [
                            .init(
                                speakerID: "Speaker 0",
                                startTime: 0.0,
                                endTime: 0.6,
                                text: "tagged rerun"
                            )
                        ]
                    ),
                    speakerProfiles: [
                        TranscriptionLabSpeakerProfile(
                            entryID: entry.id,
                            speakerID: "Speaker 0",
                            displayName: "Jesse",
                            isMe: true,
                            recognizedVoiceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"),
                            evidenceTranscript: "tagged rerun"
                        )
                    ]
                )
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
        controller.usesSpeakerTagging = true
        controller.selectedCleanupModelKind = .qwen35_4b_q4_k_m
        controller.usesCapturedOCR = false

        await controller.rerunTranscription()
        await controller.rerunCleanup(prompt: "custom prompt")

        XCTAssertEqual(executedSpeechModelID, "fluid_parakeet-v3")
        XCTAssertEqual(executedSpeakerTaggingEnabled, true)
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
        XCTAssertEqual(
            controller.displayedSpeakerTaggedTranscriptText,
            """
            [Jesse | 0.0s-0.6s]
            tagged rerun
            """
        )
        XCTAssertNil(controller.errorMessage)
        XCTAssertNil(controller.runningStage)
    }

    func testUpdatingLocalSpeakerIdentityAutoSyncsGlobalVoicePrint() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        let recognizedVoiceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        var storedProfiles = [
            TranscriptionLabSpeakerProfile(
                entryID: entry.id,
                speakerID: "Speaker 0",
                displayName: "Recognized Voice 1",
                isMe: false,
                recognizedVoiceID: recognizedVoiceID,
                evidenceTranscript: "Original evidence"
            )
        ]
        var recognizedVoices = [
            makeRecognizedVoiceProfile(
                id: recognizedVoiceID,
                displayName: "Recognized Voice 1",
                isMe: false
            )
        ]
        var savedProfiles: [TranscriptionLabSpeakerProfile] = []
        var notifyRecognizedVoicesDidChangeCallCount = 0

        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultSpeakerTaggingEnabled: false,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            loadSpeakerProfiles: { _ in storedProfiles },
            saveSpeakerProfile: { profile in
                storedProfiles = [profile]
                savedProfiles.append(profile)
            },
            loadRecognizedVoices: { recognizedVoices },
            updateGlobalVoiceProfile: { localProfile in
                var updatedProfile = recognizedVoices[0]
                updatedProfile.displayName = localProfile.displayName
                updatedProfile.isMe = localProfile.isMe
                updatedProfile.updatedAt = Date(timeIntervalSince1970: 200)
                recognizedVoices[0] = updatedProfile
                return updatedProfile
            },
            notifyRecognizedVoicesDidChange: {
                notifyRecognizedVoicesDidChangeCallCount += 1
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        controller.updateSpeakerDisplayName("Jesse", for: "Speaker 0")
        XCTAssertEqual(savedProfiles.last?.displayName, "Jesse")
        XCTAssertEqual(controller.displayName(for: "Speaker 0"), "Jesse")
        XCTAssertEqual(recognizedVoices[0].displayName, "Jesse")
        XCTAssertFalse(controller.hasPendingGlobalVoiceUpdate(for: "Speaker 0"))

        controller.setSpeakerIsMe(true, for: "Speaker 0")
        XCTAssertEqual(savedProfiles.last?.isMe, true)
        XCTAssertTrue(recognizedVoices[0].isMe)
        XCTAssertFalse(controller.hasPendingGlobalVoiceUpdate(for: "Speaker 0"))
        XCTAssertEqual(notifyRecognizedVoicesDidChangeCallCount, 2)
    }

    func testSelectedEntrySpeakerProfilesPreferLatestRecognizedVoiceData() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        let recognizedVoiceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!
        let storedProfiles = [
            TranscriptionLabSpeakerProfile(
                entryID: entry.id,
                speakerID: "Speaker 0",
                displayName: "Old local name",
                isMe: false,
                recognizedVoiceID: recognizedVoiceID,
                evidenceTranscript: "Yeah."
            )
        ]
        let recognizedVoices = [
            RecognizedVoiceProfile(
                id: recognizedVoiceID,
                displayName: "Jesse Vincent",
                isMe: true,
                embedding: [1, 0, 0],
                updateCount: 3,
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 20),
                evidenceTranscript: "And that have been around a long time."
            )
        ]

        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultSpeakerTaggingEnabled: false,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            loadSpeakerProfiles: { _ in storedProfiles },
            loadRecognizedVoices: { recognizedVoices }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertEqual(controller.displayName(for: "Speaker 0"), "Jesse Vincent")
        XCTAssertEqual(
            controller.speakerProfilesInDisplayOrder,
            [
                TranscriptionLabSpeakerProfile(
                    entryID: entry.id,
                    speakerID: "Speaker 0",
                    displayName: "Jesse Vincent",
                    isMe: true,
                    recognizedVoiceID: recognizedVoiceID,
                    evidenceTranscript: "And that have been around a long time."
                )
            ]
        )
    }

    func testHistorySpeakerIdentityEditsSyncRecognizedVoiceImmediately() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        let recognizedVoiceID = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
        var storedProfiles = [
            TranscriptionLabSpeakerProfile(
                entryID: entry.id,
                speakerID: "Speaker 0",
                displayName: "Recognized Voice 1",
                isMe: false,
                recognizedVoiceID: recognizedVoiceID,
                evidenceTranscript: "Yeah."
            )
        ]
        var recognizedVoices = [
            makeRecognizedVoiceProfile(
                id: recognizedVoiceID,
                displayName: "Recognized Voice 1",
                isMe: false,
                evidenceTranscript: "And that have been around a long time."
            )
        ]
        var notifyRecognizedVoicesDidChangeCallCount = 0

        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultSpeakerTaggingEnabled: false,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            },
            loadSpeakerProfiles: { _ in storedProfiles },
            saveSpeakerProfile: { profile in
                storedProfiles = [profile]
            },
            loadRecognizedVoices: { recognizedVoices },
            updateGlobalVoiceProfile: { localProfile in
                var updatedProfile = recognizedVoices[0]
                updatedProfile.displayName = localProfile.displayName
                updatedProfile.isMe = localProfile.isMe
                updatedProfile.evidenceTranscript = localProfile.evidenceTranscript
                updatedProfile.updatedAt = Date(timeIntervalSince1970: 200)
                recognizedVoices[0] = updatedProfile
                return updatedProfile
            },
            notifyRecognizedVoicesDidChange: {
                notifyRecognizedVoicesDidChangeCallCount += 1
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        controller.updateSpeakerDisplayName("Jesse", for: "Speaker 0")
        controller.setSpeakerIsMe(true, for: "Speaker 0")

        XCTAssertEqual(recognizedVoices[0].displayName, "Jesse")
        XCTAssertTrue(recognizedVoices[0].isMe)
        XCTAssertEqual(recognizedVoices[0].evidenceTranscript, "And that have been around a long time.")
        XCTAssertEqual(notifyRecognizedVoicesDidChangeCallCount, 2)
        XCTAssertEqual(controller.displayName(for: "Speaker 0"), "Jesse")
        XCTAssertFalse(controller.hasPendingGlobalVoiceUpdate(for: "Speaker 0"))
    }

    func testDisplayedExperimentOutputsDefaultToOriginalOutputs() {
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)"
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: SpeechModelCatalog.defaultModelID,
            defaultSpeakerTaggingEnabled: false,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
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
            defaultSpeakerTaggingEnabled: false,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
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
            defaultSpeakerTaggingEnabled: false,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(rawTranscription: "")
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        XCTAssertNil(controller.diarizationVisualization)
    }

    func testExperimentDiarizationVisualizationOverridesArchivedSummaryAfterRerun() async {
        let archivedSummary = DiarizationSummary(
            spans: [
                .init(speakerID: "Speaker 0", startTime: 0.0, endTime: 0.5, isKept: true),
            ],
            mergedKeptSpans: [
                .init(startTime: 0.0, endTime: 0.5),
            ],
            targetSpeakerID: "Speaker 0",
            targetSpeakerDuration: 0.5,
            keptAudioDuration: 0.5,
            usedFallback: false,
            fallbackReason: nil
        )
        let experimentSummary = DiarizationSummary(
            spans: [
                .init(speakerID: "Speaker 1", startTime: 0.0, endTime: 1.0, isKept: true),
            ],
            mergedKeptSpans: [
                .init(startTime: 0.0, endTime: 1.0),
            ],
            targetSpeakerID: "Speaker 1",
            targetSpeakerDuration: 1.0,
            keptAudioDuration: 1.0,
            usedFallback: false,
            fallbackReason: nil
        )
        let entry = makeEntry(
            createdAt: Date(),
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 2B (fast cleanup)",
            audioDuration: 1.5,
            diarizationSummary: archivedSummary,
            speakerFilteringEnabled: true,
            speakerFilteringRan: true,
            speakerFilteringUsedFallback: false
        )
        let controller = TranscriptionLabController(
            defaultSpeechModelID: "fluid_parakeet-v3",
            defaultSpeakerTaggingEnabled: true,
            loadStageTimings: { [:] },
            loadEntries: { [entry] },
            audioURLForEntry: { _ in URL(fileURLWithPath: "/tmp/sample.bin") },
            runTranscription: { _, _, _ in
                TranscriptionLabTranscriptionResult(
                    rawTranscription: "rerun",
                    diarizationSummary: experimentSummary,
                    speakerTaggedTranscript: SpeakerTaggedTranscript(
                        segments: [
                            .init(speakerID: "Speaker 1", startTime: 0.0, endTime: 1.0, text: "rerun")
                        ]
                    )
                )
            },
            runCleanup: { _, _, _, _, _ in
                TranscriptionLabCleanupResult(correctedTranscription: "", cleanupUsedFallback: false)
            }
        )

        controller.reloadEntries()
        controller.selectEntry(entry.id)

        await controller.rerunTranscription()

        XCTAssertEqual(controller.diarizationVisualization?.targetSpeakerID, "Speaker 1")
        XCTAssertEqual(controller.diarizationVisualization?.keptAudioDuration, 1.0)
        XCTAssertEqual(
            controller.displayedSpeakerTaggedTranscriptText,
            """
            [Speaker 1 | 0.0s-1.0s]
            rerun
            """
        )
    }

    func testDiarizationVisualizationTracksSpeakerIDsInDisplayOrder() {
        let visualization = TranscriptionLabController.DiarizationVisualization(
            audioDuration: 2.0,
            targetSpeakerID: "Speaker 1",
            keptAudioDuration: 1.0,
            usedFallback: false,
            fallbackReason: nil,
            spans: [
                .init(speakerID: "Speaker 1", startTime: 0.0, endTime: 0.4, isKept: true),
                .init(speakerID: "Speaker 0", startTime: 0.4, endTime: 0.8, isKept: false),
                .init(speakerID: "Speaker 1", startTime: 0.8, endTime: 1.2, isKept: true),
                .init(speakerID: "Speaker 2", startTime: 1.2, endTime: 2.0, isKept: false),
            ]
        )

        XCTAssertEqual(
            visualization.speakerIDsInDisplayOrder,
            ["Speaker 1", "Speaker 0", "Speaker 2"]
        )
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

    private func makeRecognizedVoiceProfile(
        id: UUID,
        displayName: String,
        isMe: Bool,
        evidenceTranscript: String = "Sample evidence"
    ) -> RecognizedVoiceProfile {
        RecognizedVoiceProfile(
            id: id,
            displayName: displayName,
            isMe: isMe,
            embedding: Array(repeating: 0.25, count: 256),
            updateCount: 1,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 100),
            evidenceTranscript: evidenceTranscript
        )
    }
}
