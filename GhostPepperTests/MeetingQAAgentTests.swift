import XCTest
@testable import GhostPepper

/// Mock LLMProvider that yields a programmable script of ProviderEvents.
private final class MockProvider: LLMProvider {
    /// Each `[ProviderEvent]` is returned in sequence per iteration.
    var scripts: [[ProviderEvent]]
    private(set) var calls: [(messages: [LLMMessage], tools: [LLMTool])] = []

    init(scripts: [[ProviderEvent]]) {
        self.scripts = scripts
    }

    func complete(system: String, messages: [LLMMessage], tools: [LLMTool]) -> AsyncThrowingStream<ProviderEvent, Error> {
        let script = scripts.isEmpty ? [] : scripts.removeFirst()
        calls.append((messages, tools))
        return AsyncThrowingStream { continuation in
            for event in script {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

final class MeetingQAAgentTests: XCTestCase {
    private var rootDir: URL!

    override func setUpWithError() throws {
        rootDir = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingQAAgentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2025-01-29"), withIntermediateDirectories: true)
        try "Quinn Adler".write(to: rootDir.appendingPathComponent("2025-01-29/dana-matt.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2025-02-06"), withIntermediateDirectories: true)
        try """
        # Owen Blake Carter sync
        Owen Blake Carter said: We should ship this.
        We agreed to follow up next week.
        """.write(to: rootDir.appendingPathComponent("2025-02-06/owen.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("2024-03-20"), withIntermediateDirectories: true)
        try """
        # Mira planning
        Mira said: The second brain should stay local.
        """.write(to: rootDir.appendingPathComponent("2024-03-20/mira.md"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: rootDir)
    }

    func testEndsWhenProviderReturnsEndTurn() async throws {
        let provider = MockProvider(scripts: [
            [
                .textDelta("The answer is 42."),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 100, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ]
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .claude(.sonnet), archiveRoot: rootDir, maxIterations: 15)

        var collected = ""
        var sawUsage = false
        for try await event in agent.ask("What is the answer?") {
            switch event {
            case .text(let t): collected += t
            case .usage: sawUsage = true
            default: break
            }
        }
        XCTAssertEqual(collected, "The answer is 42.")
        XCTAssertTrue(sawUsage)
    }

    func testExecutesToolCallAndContinuesLoop() async throws {
        let provider = MockProvider(scripts: [
            [
                .toolUse(id: "tu_1", name: "qmd_search", input: ["query": "Quinn", "case_insensitive": true, "max_results": 50]),
                .stop(reason: .toolUse, usage: ProviderUsage(inputTokens: 50, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
            [
                .textDelta("Found in 2025-01-29/dana-matt.md."),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 80, outputTokens: 8, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .claude(.sonnet), archiveRoot: rootDir, maxIterations: 15)

        var sawToolCall = false
        var sawToolResult = false
        var text = ""
        for try await event in agent.ask("Where is Quinn?") {
            switch event {
            case .toolCall: sawToolCall = true
            case .toolResult: sawToolResult = true
            case .text(let t): text += t
            default: break
            }
        }
        XCTAssertTrue(sawToolCall)
        XCTAssertTrue(sawToolResult)
        XCTAssertEqual(text, "Found in 2025-01-29/dana-matt.md.")
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testHonorsIterationCap() async throws {
        let infiniteToolUse: [ProviderEvent] = [
            .toolUse(id: "tu_x", name: "qmd_search", input: ["query": "anything", "case_insensitive": true, "max_results": 10]),
            .stop(reason: .toolUse, usage: ProviderUsage(inputTokens: 10, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0)),
        ]
        let provider = MockProvider(scripts: Array(repeating: infiniteToolUse, count: 20))
        let agent = MeetingQAAgent(provider: provider, backend: .claude(.sonnet), archiveRoot: rootDir, maxIterations: 3)

        var statuses: [String] = []
        for try await event in agent.ask("Loop forever") {
            if case .status(let s) = event { statuses.append(s) }
        }
        XCTAssertTrue(statuses.contains(where: { $0.contains("iteration cap") }), "Expected iteration-cap status, got \(statuses)")
        XCTAssertEqual(provider.calls.count, 3)
    }

    func testLocalModelRetriesToollessArchivePlanWithoutStreamingIt() async throws {
        let provider = MockProvider(scripts: [
            [
                .textDelta("Therefore, perhaps the best approach is to use list_dir and compile dates."),
                .stop(reason: .endTurn, usage: .zero),
            ],
            [
                .textDelta("Timeline:\n- 2025-02-06: Owen said \"We should ship this.\" 2025-02-06/owen.md:2"),
                .stop(reason: .endTurn, usage: .zero),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.deepseek_r1_qwen_7b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var text = ""
        var statuses: [String] = []
        for try await event in agent.ask("summarize my meetings with Owen Blake Carter as a timeline") {
            switch event {
            case .text(let t): text += t
            case .status(let s): statuses.append(s)
            default: break
            }
        }

        XCTAssertFalse(text.contains("Therefore, perhaps"), "Toolless planning text should not be shown: \(text)")
        XCTAssertTrue(text.contains("Timeline:"), "Expected final answer text after retry: \(text)")
        XCTAssertTrue(statuses.contains { $0.contains("Searching archive before local answer") }, "Expected deterministic search status, got \(statuses)")
        XCTAssertEqual(provider.calls.count, 2)

        let secondCallText = provider.calls[1].messages.flatMap { $0.content }.compactMap { block -> String? in
            if case .text(let t) = block { return t } else { return nil }
        }.joined(separator: "\n")
        let secondCallToolResults = provider.calls[1].messages.flatMap { $0.content }.compactMap { block -> String? in
            if case .toolResult(_, let content, _) = block { return content } else { return nil }
        }.joined(separator: "\n")
        XCTAssertFalse(secondCallText.contains("You answered without searching the archive"), "Expected deterministic search instead of a text-only retry")
        XCTAssertTrue(secondCallToolResults.contains("2025-02-06/owen.md"), "Expected qmd evidence in second call")
    }

    func testLocalModelSuppressesFakeSearchAnswerAfterNoToolRetry() async throws {
        let fakeSearchAnswer = """
        Okay, I need to figure out how to answer the user's question about prior meetings with Mira Vale. \
        The user is asking for a timeline of their meetings, so I should start by searching using "Mira Vale" as the query.

        To provide an accurate timeline of prior meetings with Mira Vale, I conducted a search using qmd_search for "Mira Vale." Here are the results:

        1. Meeting on March 20, 2024
        2. Meeting on January 15, 2024
        3. Meeting on October 10, 2023
        """
        let provider = MockProvider(scripts: [
            [
                .textDelta("I should use qmd_search for Mira Vale before answering."),
                .stop(reason: .endTurn, usage: .zero),
            ],
            [
                .textDelta(fakeSearchAnswer),
                .stop(reason: .endTurn, usage: .zero),
            ],
            [
                .textDelta("Mira said \"The second brain should stay local.\" 2024-03-20/mira.md:2"),
                .stop(reason: .endTurn, usage: .zero),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.deepseek_r1_qwen_7b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var text = ""
        var statuses: [String] = []
        for try await event in agent.ask("can you tell me about prior meetings with Mira Vale?") {
            switch event {
            case .text(let t): text += t
            case .status(let s): statuses.append(s)
            default: break
            }
        }

        XCTAssertFalse(text.contains("Meeting on March 20, 2024"), "Fake qmd_search prose should not be shown: \(text)")
        XCTAssertTrue(text.contains("The second brain should stay local."), text)
        XCTAssertTrue(text.contains("2024-03-20/mira.md:2"), text)
        XCTAssertTrue(statuses.contains { $0.contains("Searching archive before local answer") }, "Expected deterministic search status, got \(statuses)")
        XCTAssertTrue(statuses.contains { $0.contains("Checking answer against source evidence") }, "Expected verification status, got \(statuses)")
        XCTAssertEqual(provider.calls.count, 3)
    }

    func testLocalArchiveSearchQueryExtractsPersonFromQuestion() {
        XCTAssertEqual(
            MeetingQAAgent.localArchiveSearchQuery(for: "can you tell me about prior meetings with Mira Vale?"),
            "Mira Vale"
        )
        XCTAssertEqual(
            MeetingQAAgent.localArchiveSearchQueries(for: "can you tell me about prior meetings with Mira Vale?"),
            ["Mira Vale", "Mira", "Vale"]
        )
        XCTAssertEqual(
            MeetingQAAgent.localArchiveSearchQuery(for: "summarize my meetings with Owen Blake Carter as a timeline"),
            "Owen Blake Carter"
        )
    }

    func testLocalModelAllowsCitedAnswerWithoutRetry() async throws {
        let provider = MockProvider(scripts: [
            [
                .textDelta("Owen appears in the archive at 2025-01-29/dana-matt.md:1."),
                .stop(reason: .endTurn, usage: .zero),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.qwen35_9b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var text = ""
        var statuses: [String] = []
        for try await event in agent.ask("What did I discuss with Owen?") {
            switch event {
            case .text(let t): text += t
            case .status(let s): statuses.append(s)
            default: break
            }
        }

        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(text, "Owen appears in the archive at 2025-01-29/dana-matt.md:1.")
        XCTAssertFalse(statuses.contains { $0.contains("Retrying with archive search") }, "Cited local answers should not be retried")
    }

    func testLocalSynthesisFallbackSuppressesToolsForFinalAnswer() async throws {
        let provider = MockProvider(scripts: [
            [
                .toolUse(id: "tu_1", name: "qmd_search", input: ["query": "Owen Blake Carter", "case_insensitive": true, "max_results": 50]),
                .stop(reason: .toolUse, usage: .zero),
            ],
            [
                .stop(reason: .endTurn, usage: .zero),
            ],
            [
                .textDelta("Owen Blake Carter appears in the archive at 2025-02-06/owen.md:2."),
                .stop(reason: .endTurn, usage: .zero),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.qwen35_9b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var text = ""
        var statuses: [String] = []
        for try await event in agent.ask("summarize my meetings with Owen Blake Carter as a timeline") {
            switch event {
            case .text(let t): text += t
            case .status(let s): statuses.append(s)
            default: break
            }
        }

        XCTAssertEqual(provider.calls.count, 3)
        XCTAssertTrue(statuses.contains { $0.contains("Synthesizing answer") }, "Expected synthesis fallback status, got \(statuses)")
        XCTAssertEqual(provider.calls[2].tools.count, 0, "Final synthesis turn should not expose tools to the local model")
        XCTAssertTrue(text.contains("Owen Blake Carter appears"), text)
    }

    func testLocalModelRewritesUncitedTimelineAgainstEvidenceBeforeStreaming() async throws {
        let provider = MockProvider(scripts: [
            [
                .toolUse(id: "tu_1", name: "qmd_search", input: ["query": "Owen Blake Carter", "case_insensitive": true, "max_results": 50]),
                .stop(reason: .toolUse, usage: .zero),
            ],
            [
                .textDelta("Timeline:\n- 2025-02-06: Owen discussed the project."),
                .stop(reason: .endTurn, usage: .zero),
            ],
            [
                .textDelta("Timeline:\n- 2025-02-06: Owen said \"We should ship this.\" 2025-02-06/owen.md:2"),
                .stop(reason: .endTurn, usage: .zero),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.qwen35_9b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var text = ""
        var statuses: [String] = []
        for try await event in agent.ask("summarize my meetings with Owen Blake Carter as a timeline") {
            switch event {
            case .text(let t): text += t
            case .status(let s): statuses.append(s)
            default: break
            }
        }

        XCTAssertFalse(text.contains("Owen discussed the project."), "Uncited draft should not be streamed: \(text)")
        XCTAssertTrue(text.contains("We should ship this."), text)
        XCTAssertTrue(text.contains("2025-02-06/owen.md:2"), text)
        XCTAssertTrue(statuses.contains { $0.contains("Checking answer against source evidence") }, "Expected verification status, got \(statuses)")
        XCTAssertEqual(provider.calls.count, 3)
        XCTAssertEqual(provider.calls[2].tools.count, 0, "Verification recovery should force a plain-text final answer")

        let recoveryPrompt = provider.calls[2].messages.flatMap { $0.content }.compactMap { block -> String? in
            if case .text(let t) = block { return t } else { return nil }
        }.joined(separator: "\n")
        XCTAssertTrue(recoveryPrompt.contains("Direct quotes must match the source text exactly"), recoveryPrompt)
        XCTAssertTrue(recoveryPrompt.contains("2025-02-06/owen.md:2"), recoveryPrompt)
    }

    func testLocalModelFallsBackToEvidenceWhenVerificationRecoveryStillFails() async throws {
        let badDraft = "Timeline:\n- 2025-02-06: Owen discussed the project."
        let provider = MockProvider(scripts: [
            [
                .toolUse(id: "tu_1", name: "qmd_search", input: ["query": "Owen Blake Carter", "case_insensitive": true, "max_results": 50]),
                .stop(reason: .toolUse, usage: .zero),
            ],
            [
                .textDelta(badDraft),
                .stop(reason: .endTurn, usage: .zero),
            ],
            [
                .textDelta(badDraft),
                .stop(reason: .endTurn, usage: .zero),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.qwen35_9b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var text = ""
        for try await event in agent.ask("summarize my meetings with Owen Blake Carter as a timeline") {
            if case .text(let t) = event { text += t }
        }

        XCTAssertTrue(text.contains("local model did not produce a fully verified answer"), text)
        XCTAssertTrue(text.contains("2025-02-06/owen.md:2"), text)
        XCTAssertTrue(text.contains("We should ship this."), text)
        XCTAssertEqual(provider.calls.count, 3)
    }

    func testEvidencePacketParsesQMDAndReadFileLines() {
        let packet = MeetingQAEvidencePacket(observations: [
            MeetingQAToolObservation(
                name: "qmd_search",
                input: ["query": "Owen Blake Carter"],
                output: """
                2025-02-06/owen.md-1-# Owen Blake Carter sync
                2025-02-06/owen.md:2:Owen Blake Carter said: We should ship this.
                --
                (Returned 1 of 1 qmd search results.)
                """,
                isError: false
            ),
            MeetingQAToolObservation(
                name: "read_file",
                input: ["path": "2025-02-06/owen.md"],
                output: """
                2\tOwen Blake Carter said: We should ship this.

                (End of file at line 3.)
                """,
                isError: false
            ),
        ])

        XCTAssertEqual(packet.snippets.count, 3)
        XCTAssertTrue(packet.observedPaths.contains("2025-02-06/owen.md"))
        XCTAssertTrue(packet.containsQuote("We should ship this."))
        XCTAssertTrue(packet.compactSummary().contains("2025-02-06/owen.md:2"))
    }

    func testAnswerVerifierRejectsMissingQuotesAndUncitedTimelineDates() {
        let packet = MeetingQAEvidencePacket(observations: [
            MeetingQAToolObservation(
                name: "qmd_search",
                input: ["query": "Owen Blake Carter"],
                output: "2025-02-06/owen.md:2:Owen Blake Carter said: We should ship this.\n",
                isError: false
            )
        ])

        let result = MeetingQAAnswerVerifier.validate(
            answer: "Timeline:\n- 2025-02-06: Owen said \"We should launch today.\"",
            question: "summarize my meetings with Owen Blake Carter as a timeline",
            evidence: packet
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.reasons.contains { $0.contains("direct quote") }, "\(result.reasons)")
        XCTAssertTrue(result.reasons.contains { $0.contains("Timeline date lines") }, "\(result.reasons)")
    }

    func testAnswerVerifierRejectsPlaceholderPathCitations() {
        let packet = MeetingQAEvidencePacket(observations: [
            MeetingQAToolObservation(
                name: "qmd_search",
                input: ["query": "Mira"],
                output: """
                2026-04-21/intro-call-matt-mira-northwind.md:9:Intro Call: Matt & Mira (Northwind)
                2026-04-21/intro-call-matt-mira-northwind.md:15:Mira founded Northwind.
                """,
                isError: false
            )
        ])

        let result = MeetingQAAnswerVerifier.validate(
            answer: "Mira founded Northwind [`path:15`]. 2026-04-21/intro-call-matt-mira-northwind.md:9",
            question: "can you tell me about prior meetings with Mira?",
            evidence: packet
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.reasons.contains { $0.contains("placeholder citations") }, "\(result.reasons)")
    }

    func testAnswerVerifierRejectsVisibleDeepSeekPlanningEvenWithCitations() {
        let packet = MeetingQAEvidencePacket(observations: [
            MeetingQAToolObservation(
                name: "qmd_search",
                input: ["query": "Mira"],
                output: """
                2026-04-21/intro-call-matt-mira-northwind.md-7-
                2026-04-21/intro-call-matt-mira-northwind.md-8-# Intro Call
                2026-04-21/intro-call-matt-mira-northwind.md:9:Intro Call: Matt & Mira (Northwind)
                """,
                isError: false
            )
        ])

        let result = MeetingQAAnswerVerifier.validate(
            answer: """
            Okay, so I need to figure out how to answer the user's question about prior meetings with Mira. \
            First, I'll start by using the qmd_search tool.

            Mira met Matt at an intro call on 2026-04-21 titled "Intro Call: Matt & Mira (Northwind)". \
            2026-04-21/intro-call-matt-mira-northwind.md:9
            """,
            question: "can you tell me about prior meetings with Mira?",
            evidence: packet
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.reasons.contains { $0.contains("tool planning") }, "\(result.reasons)")
    }

    func testAnswerVerifierRejectsNoEvidenceRecallHallucination() {
        let packet = MeetingQAEvidencePacket(observations: [
            MeetingQAToolObservation(
                name: "qmd_search",
                input: ["query": "Mira Vale"],
                output: "No matches found for query: Mira Vale",
                isError: false
            )
        ])

        let result = MeetingQAAnswerVerifier.validate(
            answer: """
            I couldn't find any direct matches for "Mira Vale" in the meeting archive. \
            However, I recall a meeting titled "AI in Healthcare" that might be related to her work.
            """,
            question: "can you tell me about prior meetings with Mira Vale?",
            evidence: packet
        )

        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.reasons.contains { $0.contains("no source evidence") }, "\(result.reasons)")
    }

    // MARK: - Malformed tool-call recovery (memory: qwen-toolcall-malformed)

    func testRecoversFromMalformedToolCallByReprompting() async throws {
        let provider = MockProvider(scripts: [
            [
                .malformedToolCall(raw: #"{"arguments":{"unknown_key":"x"}}"#),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 40, outputTokens: 4, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
            [
                .textDelta("Recovered answer."),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 50, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.qwen35_4b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var text = ""
        var statuses: [String] = []
        for try await event in agent.ask("anything") {
            switch event {
            case .text(let t): text += t
            case .status(let s): statuses.append(s)
            default: break
            }
        }
        // The malformed blob must NOT leak into the answer; the loop re-prompts
        // and surfaces only the recovered turn's text.
        XCTAssertEqual(text, "Recovered answer.")
        XCTAssertEqual(provider.calls.count, 2)
        XCTAssertTrue(statuses.contains { $0.contains("malformed") }, "Expected a recovery status, got \(statuses)")
        // The re-prompt must reach the model on the second call.
        let secondCallText = provider.calls[1].messages.flatMap { $0.content }.compactMap { block -> String? in
            if case .text(let t) = block { return t } else { return nil }
        }.joined(separator: "\n")
        XCTAssertTrue(secondCallText.contains("could not be parsed"), "Expected recovery prompt in second call")
    }

    func testGivesUpAfterRepeatedMalformedToolCalls() async throws {
        let malformedTurn: [ProviderEvent] = [
            .malformedToolCall(raw: #"{"arguments":{"unknown_key":"x"}}"#),
            .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 10, outputTokens: 1, cacheReadTokens: 0, cacheWriteTokens: 0)),
        ]
        let provider = MockProvider(scripts: [malformedTurn, malformedTurn, malformedTurn])
        let agent = MeetingQAAgent(provider: provider, backend: .local(.qwen35_4b_q4_k_m), archiveRoot: rootDir, maxIterations: 15)

        var sawError = false
        for try await event in agent.ask("anything") {
            if case .error = event { sawError = true }
        }
        XCTAssertTrue(sawError, "Expected an error after repeated malformed tool calls")
        // One retry only: initial + one re-prompt, then give up (no infinite loop).
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testToolErrorReportedToProviderAsIsError() async throws {
        let provider = MockProvider(scripts: [
            [
                .toolUse(id: "tu_bad", name: "read_file", input: ["path": "../escape.md", "offset": 1, "limit": 200]),
                .stop(reason: .toolUse, usage: ProviderUsage(inputTokens: 50, outputTokens: 5, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
            [
                .textDelta("Sorry, that path was rejected."),
                .stop(reason: .endTurn, usage: ProviderUsage(inputTokens: 60, outputTokens: 6, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
        ])
        let agent = MeetingQAAgent(provider: provider, backend: .claude(.sonnet), archiveRoot: rootDir, maxIterations: 15)

        var sawErrorResult = false
        for try await event in agent.ask("Read forbidden") {
            if case .toolResult(_, _, _, let isError) = event, isError {
                sawErrorResult = true
            }
        }
        XCTAssertTrue(sawErrorResult)
        XCTAssertEqual(provider.calls.count, 2)
        let secondCallMessages = provider.calls[1].messages
        let lastUserMsg = secondCallMessages.last { $0.role == .user }!
        let hasErrorBlock = lastUserMsg.content.contains { block in
            if case .toolResult(_, _, let isError) = block { return isError }
            return false
        }
        XCTAssertTrue(hasErrorBlock)
    }
}
