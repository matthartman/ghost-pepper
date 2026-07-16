import XCTest
@testable import GhostPepper

final class MeetingChunkerTests: XCTestCase {
    func testShortFileIsOneChunk() {
        let content = "# Title\n\nSome notes\nMore notes"
        let chunks = MeetingChunker.chunk(content, targetChars: 6000)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].startLine, 1)
        XCTAssertEqual(chunks[0].endLine, 4)
        XCTAssertEqual(chunks[0].text, content)
    }

    func testChunksCoverEveryLineExactlyOnce() {
        var lines: [String] = []
        for i in 1...400 {
            if i % 50 == 0 { lines.append("## Section \(i)") }
            lines.append("Line \(i): some transcript content that pads the length out a bit")
        }
        let content = lines.joined(separator: "\n")
        let chunks = MeetingChunker.chunk(content, targetChars: 3000)

        XCTAssertGreaterThan(chunks.count, 1)
        // Contiguous, no gaps, no overlap.
        XCTAssertEqual(chunks.first?.startLine, 1)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.endLine + 1, b.startLine)
        }
        // Reassembles to the original.
        XCTAssertEqual(chunks.map { $0.text }.joined(separator: "\n"), content)
    }

    func testPrefersHeadingBoundary() {
        var lines: [String] = []
        for i in 1...60 { lines.append("Filler line \(i) with enough text to accumulate characters steadily") }
        lines.append("## The Break")
        for i in 1...60 { lines.append("Tail line \(i) with enough text to accumulate characters steadily") }
        let content = lines.joined(separator: "\n")
        let chunks = MeetingChunker.chunk(content, targetChars: 5000)

        XCTAssertGreaterThan(chunks.count, 1)
        // Some chunk should start exactly at the heading.
        XCTAssertTrue(chunks.contains { $0.text.hasPrefix("## The Break") })
    }

    func testSpeakerLineIsBoundary() {
        XCTAssertTrue(MeetingChunker.isBoundary("**[14:30] Nick:** so about the fund"))
        XCTAssertTrue(MeetingChunker.isBoundary("## Summary"))
        XCTAssertFalse(MeetingChunker.isBoundary("regular text **[not a timestamp"))
        XCTAssertFalse(MeetingChunker.isBoundary("plain line"))
    }

    func testNumberedTextUsesGlobalLineNumbers() {
        let chunk = MeetingChunk(startLine: 41, endLine: 43, text: "alpha\nbeta\ngamma")
        let numbered = MeetingChunker.numberedText(for: chunk)
        XCTAssertEqual(numbered, "L41: alpha\nL42: beta\nL43: gamma")
    }
}
