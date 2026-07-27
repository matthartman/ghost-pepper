import XCTest
@testable import GhostPepper

@MainActor
final class MeetingCardTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - JSON extraction (small-model output)

    func testExtractJSONFromCleanOutput() {
        let object = LocalStructuredLLM.extractJSONObject(from: "{\"summary\": \"hi\"}")
        XCTAssertEqual(object?["summary"] as? String, "hi")
    }

    func testExtractJSONIgnoresThinkBlocksAndProse() {
        let raw = """
        <think>Let me consider the participants carefully...
        {"decoy": true}</think>
        Sure! Here is the JSON you asked for:
        ```json
        {"summary": "Q2 planning sync", "topics": ["budget", "hiring"]}
        ```
        Hope that helps!
        """
        let object = LocalStructuredLLM.extractJSONObject(from: raw)
        XCTAssertEqual(object?["summary"] as? String, "Q2 planning sync")
        XCTAssertEqual((object?["topics"] as? [String])?.count, 2)
    }

    func testExtractJSONHandlesBracesInsideStrings() {
        let raw = "{\"summary\": \"they said {sic} and } moved on\", \"topics\": []}"
        let object = LocalStructuredLLM.extractJSONObject(from: raw)
        XCTAssertEqual(object?["summary"] as? String, "they said {sic} and } moved on")
    }

    func testExtractJSONUnclosedThinkBlockReturnsNil() {
        let raw = "<think>still thinking {\"summary\": \"x\"}"
        XCTAssertNil(LocalStructuredLLM.extractJSONObject(from: raw))
    }

    // MARK: - Field coercion

    func testStringListCoercesMixedTypes() {
        let list = MeetingCardJSON.stringList(["alpha", 42, ["name": "beta"], "", ["junk": 1]] as [Any])
        XCTAssertEqual(list, ["alpha", "42", "beta"])
    }

    func testParticipantsCoercePlainStringsAndObjects() {
        let raw: [Any] = [
            "Alpha Person",
            ["name": "Beta", "role": "CEO", "affiliation": "Acme"],
            ["role": "no name, dropped"],
        ]
        let participants = MeetingCardJSON.participants(raw)
        XCTAssertEqual(participants.count, 2)
        XCTAssertEqual(participants[0], MeetingCard.Participant(name: "Alpha Person", role: "", affiliation: ""))
        XCTAssertEqual(participants[1].affiliation, "Acme")
    }

    func testQuoteValidationDropsOutOfRangeAndMismatched() {
        let fileLines = [
            "# Meeting",
            "",
            "**[10:00] Alpha:** the fund closed at forty million dollars",
            "**[10:01] Speaker Two:** congrats",
        ]
        let quotes = [
            MeetingCard.Quote(text: "the fund closed at forty million", line: 3),   // valid
            MeetingCard.Quote(text: "completely invented content here", line: 3),   // text mismatch
            MeetingCard.Quote(text: "congrats", line: 99),                          // out of range
        ]
        let valid = MeetingCardJSON.validatedQuotes(quotes, fileLines: fileLines)
        XCTAssertEqual(valid.count, 1)
        XCTAssertEqual(valid[0].line, 3)
    }

    // MARK: - Store

    private func sampleCard() -> MeetingCard {
        MeetingCard(
            version: MeetingCard.currentVersion,
            meetingPath: "2026-04-28/standup.md",
            title: "Standup",
            date: "2026-04-28",
            summary: "Quick sync about the deploy pipeline.",
            participants: [.init(name: "Alpha Person", role: "GP", affiliation: "Example Ventures")],
            mentionedPeople: [.init(name: "Beta", context: "intro requested", possibleRole: "founder", confidence: "medium")],
            mentions: [.init(kind: "companies", name: "Example Ventures", context: "Alpha's fund")],
            topics: ["deploys"],
            decisions: ["Ship Friday"],
            openThreads: ["Intro to Parker"],
            quotes: [.init(text: "ship it", line: 12)],
            scannedKinds: ["people", "companies"],
            sourceModifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generatedByModel: "qwen35_4b_q4_k_m",
            promptHash: "abcdef123456",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    func testCardRoundtripsThroughStore() throws {
        let card = sampleCard()
        try MeetingCardStore.write(card, in: tempDir)
        let read = MeetingCardStore.read(in: tempDir, meetingPath: card.meetingPath)
        XCTAssertEqual(read, card)
    }

    func testCardURLFlattensPath() {
        let url = MeetingCardStore.cardURL(in: tempDir, meetingPath: "2026-04-28/standup.md")
        XCTAssertEqual(url.lastPathComponent, "2026-04-28__standup.md.json")
        XCTAssertTrue(url.path.contains("/.indexes/_cards/"))
    }

    func testEntityNamesPerKind() {
        let card = sampleCard()
        XCTAssertEqual(card.entityNames(forKind: "people"), ["Alpha Person", "Beta"])
        XCTAssertEqual(card.entityNames(forKind: "companies"), ["Example Ventures"])
        XCTAssertEqual(card.entityNames(forKind: "projects"), [])
    }

    func testMentionedPeopleCoercePlainStringsAndObjects() {
        let raw: [Any] = [
            "Gamma Person",
            ["name": "Beta", "context": "intro requested", "possible_role": "founder", "confidence": "medium"],
            ["context": "no name, dropped"],
        ]
        let people = MeetingCardJSON.mentionedPeople(raw)
        XCTAssertEqual(people.count, 2)
        XCTAssertEqual(people[0], MeetingCard.MentionedPerson(name: "Gamma Person", context: "", possibleRole: "", confidence: ""))
        XCTAssertEqual(people[1].possibleRole, "founder")
    }

    func testIsCurrentDetectsSourceChange() throws {
        let sourceURL = tempDir.appendingPathComponent("meeting.md")
        try "hello".write(to: sourceURL, atomically: true, encoding: .utf8)
        let mtime = (try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate]) as! Date

        var card = sampleCard()
        card.sourceModifiedAt = mtime
        XCTAssertTrue(MeetingCardStore.isCurrent(card, sourceURL: sourceURL))

        card.sourceModifiedAt = mtime.addingTimeInterval(-3600)
        XCTAssertFalse(MeetingCardStore.isCurrent(card, sourceURL: sourceURL))

        card.sourceModifiedAt = mtime
        card.version = MeetingCard.currentVersion - 1
        XCTAssertFalse(MeetingCardStore.isCurrent(card, sourceURL: sourceURL))
    }

    func testCardsDigestTrimsFromTheFront() {
        var cards: [MeetingCard] = []
        for i in 0..<50 {
            var card = sampleCard()
            card.meetingPath = String(format: "2026-01-%02d/m.md", (i % 28) + 1)
            card.title = "Meeting \(i)"
            card.summary = String(repeating: "word ", count: 80)
            cards.append(card)
        }
        let digest = LocalWikiEngine.cardsDigest(cards, maxChars: 4000)
        XCTAssertLessThanOrEqual(digest.count, 4200)
        XCTAssertTrue(digest.hasPrefix("(earlier meetings omitted)"))
        XCTAssertTrue(digest.contains("Meeting 49"), "most recent meeting must survive trimming")
    }

    func testCardsDigestCanFocusMentionedPersonContext() {
        var card = sampleCard()
        card.mentionedPeople = [
            .init(name: "Beta", context: "intro requested", possibleRole: "founder", confidence: "medium"),
            .init(name: "Gamma Person", context: "unrelated update", possibleRole: "investor", confidence: "low"),
        ]
        let digest = LocalWikiEngine.cardsDigest([card], subjectName: "Beta", maxChars: 4000)
        XCTAssertTrue(digest.contains("Beta"))
        XCTAssertTrue(digest.contains("intro requested"))
        XCTAssertFalse(digest.contains("Gamma Person"))
    }
}
