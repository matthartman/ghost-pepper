import XCTest
@testable import GhostPepper

final class QwenToolCallParserTests: XCTestCase {
    /// Drives a full tool_call through the parser (open tag + JSON + close tag)
    /// and returns the single resolved output.
    private func parseSingle(_ payload: String) -> QwenToolCallParser.Output? {
        let parser = QwenToolCallParser()
        var outputs = parser.consume("<tool_call>\(payload)</tool_call>")
        outputs += parser.finish()
        return outputs.first(where: {
            if case .toolCall = $0 { return true }
            if case .text = $0 { return true }
            return false
        })
    }

    private func toolCall(_ output: QwenToolCallParser.Output?) -> (name: String, input: [String: Any])? {
        guard case .toolCall(let name, let input)? = output else { return nil }
        return (name, input)
    }

    func testWellFormedToolCallParses() {
        let out = parseSingle(#"{"name": "qmd_search", "arguments": {"query": "Essex"}}"#)
        let call = toolCall(out)
        XCTAssertEqual(call?.name, "qmd_search")
        XCTAssertEqual(call?.input["query"] as? String, "Essex")
    }

    // MARK: - Recovery: local Qwen drops "name" (memory: qwen-toolcall-malformed)

    func testMissingNameInfersQMDSearchFromPattern() {
        let out = parseSingle(#"{"arguments": {"pattern": "Essex Labs", "max_results": 50}}"#)
        let call = toolCall(out)
        XCTAssertEqual(call?.name, "qmd_search")
        XCTAssertEqual(call?.input["pattern"] as? String, "Essex Labs")
    }

    func testMissingNameInfersQMDSearchFromQuery() {
        let out = parseSingle(#"{"arguments": {"query": "Essex Labs", "max_results": 50}}"#)
        let call = toolCall(out)
        XCTAssertEqual(call?.name, "qmd_search")
        XCTAssertEqual(call?.input["query"] as? String, "Essex Labs")
    }

    func testMissingNameInfersWriteFileFromContent() {
        let out = parseSingle(#"{"arguments": {"path": "jane-doe.md", "content": "Jane Doe"}}"#)
        XCTAssertEqual(toolCall(out)?.name, "write_file")
    }

    func testMissingNameInfersReadFileFromOffset() {
        let out = parseSingle(#"{"arguments": {"path": "2026-01-07/standup.md", "offset": 10}}"#)
        XCTAssertEqual(toolCall(out)?.name, "read_file")
    }

    func testMissingNameInfersReadFileFromMdPath() {
        let out = parseSingle(#"{"arguments": {"path": "2026-01-07/standup.md"}}"#)
        XCTAssertEqual(toolCall(out)?.name, "read_file")
    }

    func testMissingNameInfersListDirFromBarePath() {
        let out = parseSingle(#"{"arguments": {"path": "2026-01-07"}}"#)
        XCTAssertEqual(toolCall(out)?.name, "list_dir")
    }

    func testBareTopLevelArgumentsWithoutWrapper() {
        // Some emissions drop both "name" and the "arguments" wrapper.
        let out = parseSingle(#"{"pattern": "Quinn"}"#)
        let call = toolCall(out)
        XCTAssertEqual(call?.name, "qmd_search")
        XCTAssertEqual(call?.input["pattern"] as? String, "Quinn")
    }

    func testUninferableMalformedEmitsMalformedSignal() {
        // No recognizable argument keys → can't infer. Don't fabricate a tool;
        // emit a distinct malformed signal so the agent loop can re-prompt
        // (rather than treating the blob as a final answer).
        let parser = QwenToolCallParser()
        var outputs = parser.consume(#"<tool_call>{"foo": "bar"}</tool_call>"#)
        outputs += parser.finish()
        XCTAssertFalse(outputs.contains { if case .toolCall = $0 { return true } else { return false } },
                       "should not infer a tool from unknown keys")
        XCTAssertTrue(outputs.contains { if case .malformedToolCall = $0 { return true } else { return false } },
                      "expected a malformed-tool-call signal")
    }
}
