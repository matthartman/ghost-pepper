import XCTest
@testable import GhostPepper

final class TranscriptionLabSpeakerProfileStoreTests: XCTestCase {
    func testLoadProfilesReturnsEmptyWhenEntryHasNoSavedProfiles() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabSpeakerProfileStore(directoryURL: fixture.directoryURL)

        XCTAssertEqual(
            try store.loadProfiles(for: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!),
            []
        )
    }

    func testUpsertPersistsProfilesForEntryInSpeakerOrder() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabSpeakerProfileStore(directoryURL: fixture.directoryURL)
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let firstProfile = makeProfile(entryID: entryID, speakerID: "Speaker 1", displayName: "Alice")
        let secondProfile = makeProfile(entryID: entryID, speakerID: "Speaker 0", displayName: "Bob")

        try store.upsert(firstProfile)
        try store.upsert(secondProfile)

        XCTAssertEqual(
            try store.loadProfiles(for: entryID),
            [secondProfile, firstProfile]
        )
    }

    func testUpsertReplacesExistingSpeakerProfile() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabSpeakerProfileStore(directoryURL: fixture.directoryURL)
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!

        try store.upsert(
            makeProfile(
                entryID: entryID,
                speakerID: "Speaker 0",
                displayName: "Speaker 0"
            )
        )
        try store.upsert(
            makeProfile(
                entryID: entryID,
                speakerID: "Speaker 0",
                displayName: "Jesse",
                isMe: true,
                recognizedVoiceID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
            )
        )

        XCTAssertEqual(
            try store.loadProfiles(for: entryID),
            [
                makeProfile(
                    entryID: entryID,
                    speakerID: "Speaker 0",
                    displayName: "Jesse",
                    isMe: true,
                    recognizedVoiceID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
                )
            ]
        )
    }

    func testLoadAllProfilesReturnsProfilesFromEveryEntryInStableOrder() throws {
        let fixture = makeFixture()
        let store = TranscriptionLabSpeakerProfileStore(directoryURL: fixture.directoryURL)
        let firstEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        let secondEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let firstProfile = makeProfile(entryID: firstEntryID, speakerID: "Speaker 1", displayName: "Alice")
        let secondProfile = makeProfile(entryID: secondEntryID, speakerID: "Speaker 0", displayName: "Bob")
        let thirdProfile = makeProfile(entryID: firstEntryID, speakerID: "Speaker 0", displayName: "Carol")

        try store.upsert(firstProfile)
        try store.upsert(secondProfile)
        try store.upsert(thirdProfile)

        XCTAssertEqual(
            try store.loadAllProfiles(),
            [secondProfile, thirdProfile, firstProfile]
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
    }

    private func makeProfile(
        entryID: UUID,
        speakerID: String,
        displayName: String,
        isMe: Bool = false,
        recognizedVoiceID: UUID? = nil
    ) -> TranscriptionLabSpeakerProfile {
        TranscriptionLabSpeakerProfile(
            entryID: entryID,
            speakerID: speakerID,
            displayName: displayName,
            isMe: isMe,
            recognizedVoiceID: recognizedVoiceID,
            evidenceTranscript: "Evidence for \(speakerID)."
        )
    }
}
