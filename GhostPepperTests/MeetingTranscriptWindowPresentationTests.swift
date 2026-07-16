import AppKit
import XCTest
@testable import GhostPepper

final class MeetingTranscriptWindowPresentationTests: XCTestCase {
    func testWindowStaysNormalWhenFloatingPreferenceIsDisabled() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: false,
                hasActiveRecording: true
            ),
            .normal
        )
    }

    func testWindowFloatsWhenRecordingAndFloatingPreferenceIsEnabled() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: true,
                hasActiveRecording: true
            ),
            .floating
        )
    }

    func testWindowReturnsToNormalWhenNoMeetingIsRecording() {
        XCTAssertEqual(
            MeetingTranscriptWindowPresentation.windowLevel(
                shouldFloatWhileRecording: true,
                hasActiveRecording: false
            ),
            .normal
        )
    }
}

@MainActor
final class MeetingTranscriptSpeakerLabelTests: XCTestCase {
    func testReplaceSpeakerDisplayNameUpdatesMatchingRemoteSegmentsOnly() {
        let transcript = MeetingTranscript(meetingName: "Speaker Review")
        transcript.segments = [
            TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: "Speaker 1"),
                startTime: 0,
                endTime: 1,
                text: "First turn"
            ),
            TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: "Speaker 2"),
                startTime: 2,
                endTime: 3,
                text: "Second turn"
            ),
            TranscriptSegment(
                id: UUID(),
                speaker: .me,
                startTime: 4,
                endTime: 5,
                text: "Mic turn"
            )
        ]

        transcript.replaceSpeakerDisplayName("Speaker 1", with: "Alice Example")

        XCTAssertEqual(transcript.segments[0].speaker, .remote(name: "Alice Example"))
        XCTAssertEqual(transcript.segments[1].speaker, .remote(name: "Speaker 2"))
        XCTAssertEqual(transcript.segments[2].speaker, .me)
    }
}

@MainActor
final class CommandKSearchRankingTests: XCTestCase {
    func testTitleMatchesRankAboveWikiBodyMatches() {
        let root = URL(fileURLWithPath: "/tmp/CommandKSearchRankingTests")
        let directMatch = GeneratedWikiSidebarItem(
            title: "Diana Berlin",
            type: "person",
            fileURL: root.appendingPathComponent("diana.md")
        )
        let bodyOnlyMatch = GeneratedWikiSidebarItem(
            title: "Matt Hartman",
            type: "person",
            fileURL: root.appendingPathComponent("matt.md")
        )

        let results = CommandKResults.compute(
            haystack: [
                CommandKHaystackEntry(
                    title: bodyOnlyMatch.title,
                    titleLower: bodyOnlyMatch.title.lowercased(),
                    subtitle: "People",
                    contentLower: "worked with diana on matrix diligence.",
                    dateFolderLower: "",
                    id: "wiki-\(bodyOnlyMatch.fileURL.path)",
                    kind: .wiki(bodyOnlyMatch, folderTitle: "People")
                ),
                CommandKHaystackEntry(
                    title: directMatch.title,
                    titleLower: directMatch.title.lowercased(),
                    subtitle: "People",
                    contentLower: "",
                    dateFolderLower: "",
                    id: "wiki-\(directMatch.fileURL.path)",
                    kind: .wiki(directMatch, folderTitle: "People")
                )
            ],
            query: "diana"
        )

        XCTAssertEqual(results.wiki.map(\.title), ["Diana Berlin", "Matt Hartman"])
        XCTAssertEqual(results.wiki.last?.subtitle, "People • content match")
    }
}

@MainActor
final class MeetingMarkdownWriterParsingTests: XCTestCase {
    func testParsePreservesGranolaSpeakerLabelsAndContinuationLines() throws {
        let fileURL = try writeMarkdown(
            """
            # Imported Meeting

            ## Transcript

            **Alice Example:** We should preserve the speaker.
            This wrapped line is still Alice.

            **Bob Example:** Agreed on the next step.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.segments.count, 2)
        XCTAssertEqual(transcript.segments[0].speaker, .remote(name: "Alice Example"))
        XCTAssertEqual(
            transcript.segments[0].text,
            "We should preserve the speaker.\nThis wrapped line is still Alice."
        )
        XCTAssertEqual(transcript.segments[1].speaker, .remote(name: "Bob Example"))
        XCTAssertEqual(transcript.segments[1].text, "Agreed on the next step.")
    }

    func testParsePreservesPlainAndTimestampedSpeakerLabels() throws {
        let fileURL = try writeMarkdown(
            """
            # Timestamped Meeting

            ## Transcript

            [00:12] Me: I opened the discussion.
            [00:17] Alpha Person: Then Alpha replied.
            **[01:02] Others:** The room responded.
            Facilitator: Final plain speaker line.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.segments.count, 4)
        XCTAssertEqual(transcript.segments[0].speaker, .me)
        XCTAssertEqual(transcript.segments[0].startTime, 12)
        XCTAssertEqual(transcript.segments[1].speaker, .remote(name: "Alpha Person"))
        XCTAssertEqual(transcript.segments[1].startTime, 17)
        XCTAssertEqual(transcript.segments[2].speaker, .remote(name: nil))
        XCTAssertEqual(transcript.segments[2].startTime, 62)
        XCTAssertEqual(transcript.segments[3].speaker, .remote(name: "Facilitator"))
        XCTAssertEqual(transcript.segments[3].text, "Final plain speaker line.")
    }

    func testParseRestoresGranolaFrontmatterDateAndAttendees() throws {
        let fileURL = try writeMarkdown(
            """
            ---
            title: "Imported Meeting"
            date: "2026-07-16T14:30:00.000Z"
            attendees: ["Alice Example", "Bob, Jr.", "Casey \\\"CJ\\\" Stone"]
            imported_from: granola
            ---

            # Imported Meeting

            ## Transcript

            **Alice Example:** We should preserve metadata.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.importedFrom, "granola")
        XCTAssertEqual(
            transcript.attendees.map(\.name),
            ["Alice Example", "Bob, Jr.", "Casey \"CJ\" Stone"]
        )
        XCTAssertEqual(
            Int(transcript.startDate.timeIntervalSince1970),
            Int(ISO8601DateFormatter().date(from: "2026-07-16T14:30:00Z")!.timeIntervalSince1970)
        )
    }

    func testParseRestoresVisibleAttendeesLine() throws {
        let fileURL = try writeMarkdown(
            """
            # Imported Meeting

            **Attendees:** Alice Example, Bob Example

            ## Transcript

            **Alice Example:** We should preserve attendee names.
            """
        )

        let transcript = try MeetingMarkdownWriter.parse(from: fileURL)

        XCTAssertEqual(transcript.attendees.map(\.name), ["Alice Example", "Bob Example"])
    }

    private func writeMarkdown(_ markdown: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GhostPepperMeetingMarkdownWriterTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("meeting.md")
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}

final class GranolaImporterTranscriptExtractionTests: XCTestCase {
    func testExtractTranscriptPreservesTimestampsAndNestedSpeakers() {
        let transcriptData: [Any] = [
            [
                "start_time": 12.8,
                "speaker": ["name": "Alice Example"],
                "text": "First speaker turn."
            ],
            [
                "timestamp_ms": 62_000,
                "participant": ["displayName": "Bob Example"],
                "content": "Second speaker turn."
            ]
        ]

        let markdown = GranolaImporter.extractTranscript(from: transcriptData)

        XCTAssertEqual(
            markdown,
            """
            **[00:12] Alice Example:** First speaker turn.

            **[01:02] Bob Example:** Second speaker turn.
            """
        )
    }

    func testExtractTranscriptFallsBackToSpeakerIDsAndWordLists() {
        let transcriptData: [Any] = [
            [
                "speaker_id": "1",
                "start": "00:03",
                "words": [
                    ["word": "Hello"],
                    ["text": "there"]
                ]
            ]
        ]

        let markdown = GranolaImporter.extractTranscript(from: transcriptData)

        XCTAssertEqual(markdown, "**[00:03] Speaker 1:** Hello there")
    }
}

@MainActor
final class MeetingSessionSpeakerTaggingTests: XCTestCase {
    func testApplyingRemoteSpeakerTagsReplacesGenericRemoteSegmentsAndKeepsMicSegments() {
        let originalSegments = [
            TranscriptSegment(
                id: UUID(),
                speaker: .me,
                startTime: 0,
                endTime: 30,
                text: "Mic side"
            ),
            TranscriptSegment(
                id: UUID(),
                speaker: .remote(name: nil),
                startTime: 0,
                endTime: 30,
                text: "Generic remote side"
            )
        ]
        let taggedTranscript = SpeakerTaggedTranscript(
            segments: [
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 0",
                    startTime: 1,
                    endTime: 4,
                    text: "Remote speaker one"
                ),
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 1",
                    startTime: 5,
                    endTime: 8,
                    text: "Remote speaker two"
                )
            ]
        )

        let updated = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: taggedTranscript,
            to: originalSegments
        )

        XCTAssertEqual(updated.count, 3)
        XCTAssertEqual(updated[0].speaker, .me)
        XCTAssertEqual(updated[1].speaker, .remote(name: "Speaker 1"))
        XCTAssertEqual(updated[1].text, "Remote speaker one")
        XCTAssertEqual(updated[2].speaker, .remote(name: "Speaker 2"))
        XCTAssertEqual(updated[2].text, "Remote speaker two")
    }

    func testApplyingRemoteSpeakerTagsUsesSavedDisplayNameWhenPresent() {
        let taggedTranscript = SpeakerTaggedTranscript(
            segments: [
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 0",
                    startTime: 0,
                    endTime: 2,
                    text: "Known voice",
                    attribution: SpeakerTaggedTranscript.Attribution(
                        speakerID: "Speaker 0",
                        recognizedVoiceID: UUID(),
                        displayName: "Alice Example",
                        confidence: 0.9,
                        evidenceDuration: 2,
                        source: .diarization
                    )
                ),
                SpeakerTaggedTranscript.Segment(
                    speakerID: "Speaker 1",
                    startTime: 3,
                    endTime: 4,
                    text: "Unlabeled voice",
                    attribution: SpeakerTaggedTranscript.Attribution(
                        speakerID: "Speaker 1",
                        recognizedVoiceID: UUID(),
                        displayName: "Recognized Voice 4",
                        confidence: 0.9,
                        evidenceDuration: 1,
                        source: .diarization
                    )
                )
            ]
        )

        let updated = MeetingSession.transcriptSegments(
            byApplyingRemoteSpeakerTags: taggedTranscript,
            to: []
        )

        XCTAssertEqual(updated.map(\.speaker), [
            .remote(name: "Alice Example"),
            .remote(name: "Speaker 1")
        ])
    }
}
