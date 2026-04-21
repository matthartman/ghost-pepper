import XCTest
@testable import GhostPepper

final class SpeakerIdentityResolverTests: XCTestCase {
    func testResolveCreatesRecognizedVoiceForUnmatchedSpeaker() {
        let entryID = UUID()
        let now = Date(timeIntervalSince1970: 100)
        let resolver = SpeakerIdentityResolver(
            matchDistanceThreshold: 0.2,
            minimumEmbeddingDuration: 1.0
        )

        let resolution = resolver.resolve(
            entryID: entryID,
            speakers: [
                SpeakerIdentityInput(
                    speakerID: "Speaker 0",
                    audioDuration: 2.4,
                    evidenceTranscript: "This is the transcript for speaker zero.",
                    embedding: [1, 0, 0]
                )
            ],
            existingLocalProfiles: [],
            recognizedVoices: [],
            now: now
        )

        XCTAssertEqual(resolution.recognizedVoices.count, 1)
        XCTAssertEqual(resolution.localProfiles.count, 1)

        let recognizedVoice = try? XCTUnwrap(resolution.recognizedVoices.first)
        XCTAssertEqual(recognizedVoice?.displayName, "Recognized Voice 1")
        XCTAssertEqual(recognizedVoice?.isMe, false)
        XCTAssertEqual(recognizedVoice?.embedding, [1, 0, 0])
        XCTAssertEqual(recognizedVoice?.updateCount, 1)
        XCTAssertEqual(
            recognizedVoice?.evidenceTranscript,
            "This is the transcript for speaker zero."
        )
        XCTAssertEqual(recognizedVoice?.createdAt, now)
        XCTAssertEqual(recognizedVoice?.updatedAt, now)

        let localProfile = try? XCTUnwrap(resolution.localProfiles.first)
        XCTAssertEqual(localProfile?.entryID, entryID)
        XCTAssertEqual(localProfile?.speakerID, "Speaker 0")
        XCTAssertEqual(localProfile?.displayName, "Recognized Voice 1")
        XCTAssertEqual(localProfile?.recognizedVoiceID, recognizedVoice?.id)
        XCTAssertEqual(localProfile?.evidenceTranscript, "This is the transcript for speaker zero.")
    }

    func testResolveMatchesExistingRecognizedVoiceAndPreservesExistingLocalOverride() {
        let entryID = UUID()
        let existingVoiceID = UUID()
        let oldTime = Date(timeIntervalSince1970: 10)
        let now = Date(timeIntervalSince1970: 20)
        let resolver = SpeakerIdentityResolver(
            matchDistanceThreshold: 0.2,
            minimumEmbeddingDuration: 1.0
        )

        let resolution = resolver.resolve(
            entryID: entryID,
            speakers: [
                SpeakerIdentityInput(
                    speakerID: "Speaker 1",
                    audioDuration: 3.1,
                    evidenceTranscript: "Updated evidence from this session.",
                    embedding: [1, 0, 0]
                )
            ],
            existingLocalProfiles: [
                TranscriptionLabSpeakerProfile(
                    entryID: entryID,
                    speakerID: "Speaker 1",
                    displayName: "Jesse (room mic)",
                    isMe: true,
                    recognizedVoiceID: existingVoiceID,
                    evidenceTranscript: "Old evidence"
                )
            ],
            recognizedVoices: [
                RecognizedVoiceProfile(
                    id: existingVoiceID,
                    displayName: "Jesse",
                    isMe: true,
                    embedding: [1, 0, 0],
                    updateCount: 2,
                    createdAt: oldTime,
                    updatedAt: oldTime,
                    evidenceTranscript: "Original evidence"
                )
            ],
            now: now
        )

        XCTAssertEqual(resolution.recognizedVoices.count, 1)
        XCTAssertEqual(resolution.localProfiles.count, 1)

        let recognizedVoice = try? XCTUnwrap(resolution.recognizedVoices.first)
        XCTAssertEqual(recognizedVoice?.id, existingVoiceID)
        XCTAssertEqual(recognizedVoice?.displayName, "Jesse")
        XCTAssertEqual(recognizedVoice?.isMe, true)
        XCTAssertEqual(recognizedVoice?.updateCount, 3)
        XCTAssertEqual(recognizedVoice?.createdAt, oldTime)
        XCTAssertEqual(recognizedVoice?.updatedAt, now)
        XCTAssertEqual(recognizedVoice?.evidenceTranscript, "Updated evidence from this session.")
        XCTAssertEqual(recognizedVoice?.embedding, [1, 0, 0])

        let localProfile = try? XCTUnwrap(resolution.localProfiles.first)
        XCTAssertEqual(localProfile?.displayName, "Jesse (room mic)")
        XCTAssertEqual(localProfile?.isMe, true)
        XCTAssertEqual(localProfile?.recognizedVoiceID, existingVoiceID)
        XCTAssertEqual(localProfile?.evidenceTranscript, "Updated evidence from this session.")
    }

    func testResolveLeavesShortSpeakerUnlinkedWhenNoReliableVoicePrintCanBeBuilt() {
        let entryID = UUID()
        let resolver = SpeakerIdentityResolver(
            matchDistanceThreshold: 0.2,
            minimumEmbeddingDuration: 1.0
        )

        let resolution = resolver.resolve(
            entryID: entryID,
            speakers: [
                SpeakerIdentityInput(
                    speakerID: "Speaker 2",
                    audioDuration: 0.4,
                    evidenceTranscript: "Brief interruption.",
                    embedding: [0, 1, 0]
                )
            ],
            existingLocalProfiles: [],
            recognizedVoices: [],
            now: Date(timeIntervalSince1970: 30)
        )

        XCTAssertTrue(resolution.recognizedVoices.isEmpty)
        XCTAssertEqual(
            resolution.localProfiles,
            [
                TranscriptionLabSpeakerProfile(
                    entryID: entryID,
                    speakerID: "Speaker 2",
                    displayName: "Speaker 2",
                    isMe: false,
                    recognizedVoiceID: nil,
                    evidenceTranscript: "Brief interruption."
                )
            ]
        )
    }
}
