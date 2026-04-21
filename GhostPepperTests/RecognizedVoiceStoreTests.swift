import XCTest
@testable import GhostPepper

final class RecognizedVoiceStoreTests: XCTestCase {
    func testLoadProfilesReturnsEmptyWhenIndexDoesNotExist() throws {
        let fixture = makeFixture()
        let store = RecognizedVoiceStore(directoryURL: fixture.directoryURL)

        XCTAssertEqual(try store.loadProfiles(), [])
    }

    func testUpsertPersistsProfilesNewestFirst() throws {
        let fixture = makeFixture()
        let store = RecognizedVoiceStore(directoryURL: fixture.directoryURL)
        let olderProfile = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Voice A",
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newerProfile = makeProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            displayName: "Voice B",
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        try store.upsert(olderProfile)
        try store.upsert(newerProfile)

        XCTAssertEqual(
            try store.loadProfiles().map(\.id),
            [newerProfile.id, olderProfile.id]
        )
    }

    func testUpsertReplacesExistingProfileWithSameID() throws {
        let fixture = makeFixture()
        let store = RecognizedVoiceStore(directoryURL: fixture.directoryURL)
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        try store.upsert(
            makeProfile(
                id: profileID,
                displayName: "Old Name",
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        )
        try store.upsert(
            makeProfile(
                id: profileID,
                displayName: "New Name",
                isMe: true,
                updatedAt: Date(timeIntervalSince1970: 300)
            )
        )

        XCTAssertEqual(
            try store.loadProfiles(),
            [
                makeProfile(
                    id: profileID,
                    displayName: "New Name",
                    isMe: true,
                    updatedAt: Date(timeIntervalSince1970: 300)
                )
            ]
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
        id: UUID = UUID(),
        displayName: String,
        isMe: Bool = false,
        updatedAt: Date
    ) -> RecognizedVoiceProfile {
        RecognizedVoiceProfile(
            id: id,
            displayName: displayName,
            isMe: isMe,
            embedding: Array(repeating: 0.25, count: 256),
            updateCount: 1,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt,
            evidenceTranscript: "This is sample evidence."
        )
    }
}
