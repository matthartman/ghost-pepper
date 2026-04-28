import XCTest
@testable import GhostPepper

final class TranscriptionLabStoreTests: XCTestCase {
    func testEntryRoundTripsThroughJSON() throws {
        let entry = TranscriptionLabEntry(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            createdAt: Date(timeIntervalSince1970: 1_742_950_000),
            audioFileName: "sample-audio.bin",
            audioDuration: 2.5,
            windowContext: OCRContext(windowContents: "Qwen 3.5 4B"),
            rawTranscription: "The default is Qwen 3.5 4B.",
            correctedTranscription: "The default is Qwen 3.5 4B.",
            speechModelID: "fluid_parakeet-v3",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)",
            cleanupUsedFallback: false,
            speakerFilteringEnabled: true,
            speakerFilteringRan: true,
            speakerFilteringUsedFallback: false,
            diarizationSummary: makeDiarizationSummary()
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TranscriptionLabEntry.self, from: encoded)

        XCTAssertEqual(decoded, entry)
    }

    func testStoreReturnsEntriesNewestFirst() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )

        let olderEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 100),
            audioFileName: "older.bin"
        )
        let newerEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 200),
            audioFileName: "newer.bin"
        )

        try store.insert(olderEntry, audioData: Data([0x01]), stageTimings: makeStageTimings())
        try store.insert(newerEntry, audioData: Data([0x02]), stageTimings: makeStageTimings())

        let entries = try store.loadEntries()

        XCTAssertEqual(entries.map(\.id), [newerEntry.id, olderEntry.id])
    }

    func testStorePrunesOldestEntryWhenCapacityExceeded() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 2
        )

        let firstEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            createdAt: Date(timeIntervalSince1970: 100),
            audioFileName: "first.bin"
        )
        let secondEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            createdAt: Date(timeIntervalSince1970: 200),
            audioFileName: "second.bin"
        )
        let thirdEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            createdAt: Date(timeIntervalSince1970: 300),
            audioFileName: "third.bin"
        )

        try store.insert(firstEntry, audioData: Data([0x01]), stageTimings: makeStageTimings())
        try store.insert(secondEntry, audioData: Data([0x02]), stageTimings: makeStageTimings())
        try store.insert(thirdEntry, audioData: Data([0x03]), stageTimings: makeStageTimings())

        let entries = try store.loadEntries()

        XCTAssertEqual(entries.map(\.id), [thirdEntry.id, secondEntry.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL(named: "first.bin").path))
    }

    func testStoreLoadsEmptyArchiveWhenIndexDoesNotExist() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )

        let entries = try store.loadEntries()

        XCTAssertTrue(entries.isEmpty)
    }

    func testStorePrunesRecordingsThatDisplayAsZeroSecondsOnLoad() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )
        let shortEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!,
            createdAt: Date(timeIntervalSince1970: 300),
            audioFileName: "too-short.wav",
            audioDuration: 0.04
        )
        let visibleEntry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000052")!,
            createdAt: Date(timeIntervalSince1970: 200),
            audioFileName: "visible.wav",
            audioDuration: 0.1
        )
        let indexURL = fixture.directoryURL.appendingPathComponent("transcription-lab-index.json")
        let timingsURL = fixture.directoryURL.appendingPathComponent("transcription-lab-timings.json")
        let shortTiming = TranscriptionLabStageTimings(transcriptionDuration: 0.01, cleanupDuration: nil)
        let visibleTiming = makeStageTimings()

        try FileManager.default.createDirectory(
            at: fixture.directoryURL.appendingPathComponent("audio", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data([0x01]).write(to: fixture.audioURL(named: shortEntry.audioFileName))
        try Data([0x02]).write(to: fixture.audioURL(named: visibleEntry.audioFileName))
        try JSONEncoder().encode([shortEntry, visibleEntry]).write(to: indexURL)
        try JSONEncoder().encode([
            shortEntry.id.uuidString: shortTiming,
            visibleEntry.id.uuidString: visibleTiming
        ]).write(to: timingsURL)

        let entries = try store.loadEntries()

        XCTAssertEqual(entries.map(\.id), [visibleEntry.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioURL(named: shortEntry.audioFileName).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioURL(named: visibleEntry.audioFileName).path))
        XCTAssertNil(try store.loadStageTimings()[shortEntry.id])
        XCTAssertEqual(try store.loadStageTimings()[visibleEntry.id], visibleTiming)
        XCTAssertEqual(
            try JSONDecoder().decode([TranscriptionLabEntry].self, from: Data(contentsOf: indexURL)).map(\.id),
            [visibleEntry.id]
        )
    }

    func testStorePersistsStageTimingsForNewEntries() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )
        let entry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
            createdAt: Date(timeIntervalSince1970: 123),
            audioFileName: "timed.bin"
        )
        let stageTimings = TranscriptionLabStageTimings(
            transcriptionDuration: 0.31,
            cleanupDuration: 0.72
        )

        try store.insert(entry, audioData: Data([0x01]), stageTimings: stageTimings)

        XCTAssertEqual(
            try store.loadStageTimings()[entry.id],
            stageTimings
        )
    }

    func testStoreDropsUnreadableEntryIndexWithoutPreservingOldEntries() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )
        let legacyIndexURL = fixture.directoryURL.appendingPathComponent("transcription-lab-index.json")

        try Data("""
        [
          {
            "id": "00000000-0000-0000-0000-000000000041",
            "createdAt": 123,
            "audioFileName": "legacy.wav",
            "audioDuration": 1.0,
            "rawTranscription": "legacy",
            "correctedTranscription": "legacy",
            "speechModelID": "fluid_parakeet-v3",
            "cleanupModelName": "Qwen 3.5 2B (fast cleanup)",
            "cleanupUsedFallback": false
          }
        ]
        """.utf8).write(to: legacyIndexURL)

        XCTAssertEqual(try store.loadEntries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyIndexURL.path))
    }

    func testInsertRecoversFromUnreadableLegacyArchiveState() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )
        let indexURL = fixture.directoryURL.appendingPathComponent("transcription-lab-index.json")
        let timingsURL = fixture.directoryURL.appendingPathComponent("transcription-lab-timings.json")

        try Data("not-json".utf8).write(to: indexURL)
        try Data("still-not-json".utf8).write(to: timingsURL)

        let entry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
            createdAt: Date(timeIntervalSince1970: 999),
            audioFileName: "recovered.wav"
        )

        try store.insert(entry, audioData: Data([0x01, 0x02]), stageTimings: makeStageTimings())

        XCTAssertEqual(try store.loadEntries(), [entry])
        XCTAssertEqual(try store.loadStageTimings()[entry.id], makeStageTimings())
    }

    func testTranscriptionLabEntryRoundTripsDiarizationSummary() throws {
        let entry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!,
            createdAt: Date(timeIntervalSince1970: 456),
            audioFileName: "diarized.wav"
        )

        let encoded = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TranscriptionLabEntry.self, from: encoded)

        XCTAssertEqual(decoded.diarizationSummary, entry.diarizationSummary)
        XCTAssertEqual(decoded.speakerFilteringEnabled, true)
        XCTAssertEqual(decoded.speakerFilteringRan, true)
        XCTAssertEqual(decoded.speakerFilteringUsedFallback, false)
    }

    func testTranscriptionLabStorePersistsDiarizationSummary() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabStore(
            directoryURL: fixture.directoryURL,
            maxEntries: 50
        )
        let entry = makeEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!,
            createdAt: Date(timeIntervalSince1970: 789),
            audioFileName: "persisted-diarized.wav"
        )

        try store.insert(entry, audioData: Data([0x01]), stageTimings: makeStageTimings())

        let entries = try store.loadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].diarizationSummary, entry.diarizationSummary)
        XCTAssertEqual(entries[0].speakerFilteringEnabled, true)
        XCTAssertEqual(entries[0].speakerFilteringRan, true)
        XCTAssertEqual(entries[0].speakerFilteringUsedFallback, false)
    }

    private func makeEntry(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        audioFileName: String,
        audioDuration: TimeInterval = 1.5
    ) -> TranscriptionLabEntry {
        TranscriptionLabEntry(
            id: id,
            createdAt: createdAt,
            audioFileName: audioFileName,
            audioDuration: audioDuration,
            windowContext: OCRContext(windowContents: "Terminal says hello"),
            rawTranscription: "raw text",
            correctedTranscription: "corrected text",
            speechModelID: "openai_whisper-small.en",
            cleanupModelName: "Qwen 3.5 4B (full cleanup)",
            cleanupUsedFallback: false,
            speakerFilteringEnabled: true,
            speakerFilteringRan: true,
            speakerFilteringUsedFallback: false,
            diarizationSummary: makeDiarizationSummary()
        )
    }

    private func makeFixture() -> Fixture {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        return Fixture(directoryURL: directoryURL)
    }

    private struct Fixture {
        let directoryURL: URL

        func audioURL(named fileName: String) -> URL {
            directoryURL.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(fileName)
        }
    }

    private func makeStageTimings() -> TranscriptionLabStageTimings {
        TranscriptionLabStageTimings(
            transcriptionDuration: 0.25,
            cleanupDuration: 0.55
        )
    }

    private func makeDiarizationSummary() -> DiarizationSummary {
        DiarizationSummary(
            spans: [
                DiarizationSummary.Span(speakerID: "speaker-a", startTime: 0.0, endTime: 0.6, isKept: true),
                DiarizationSummary.Span(speakerID: "speaker-b", startTime: 0.7, endTime: 1.0, isKept: false)
            ],
            mergedKeptSpans: [
                DiarizationSummary.MergedSpan(startTime: 0.0, endTime: 0.6)
            ],
            targetSpeakerID: "speaker-a",
            targetSpeakerDuration: 0.6,
            keptAudioDuration: 0.6,
            usedFallback: false,
            fallbackReason: nil
        )
    }
}
