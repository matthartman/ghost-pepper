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
        try "Quinn Adler".write(to: rootDir.appendingPathComponent("2025-01-29/speaker-one-speaker-two.md"), atomically: true, encoding: .utf8)
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
                .toolUse(id: "tu_1", name: "grep", input: ["pattern": "Quinn", "case_insensitive": true, "max_results": 50]),
                .stop(reason: .toolUse, usage: ProviderUsage(inputTokens: 50, outputTokens: 10, cacheReadTokens: 0, cacheWriteTokens: 0)),
            ],
            [
                .textDelta("Found in 2025-01-29/speaker-one-speaker-two.md."),
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
        XCTAssertEqual(text, "Found in 2025-01-29/speaker-one-speaker-two.md.")
        XCTAssertEqual(provider.calls.count, 2)
    }

    func testHonorsIterationCap() async throws {
        let infiniteToolUse: [ProviderEvent] = [
            .toolUse(id: "tu_x", name: "grep", input: ["pattern": "anything", "case_insensitive": true, "max_results": 10]),
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
