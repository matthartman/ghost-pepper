import XCTest
@testable import GhostPepper

final class AnthropicProviderSSETests: XCTestCase {
    func testTextDeltaEmitsImmediately() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })

        try acc.handle(eventJSON: """
        {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}
        """)

        XCTAssertEqual(emitted.count, 1)
        if case .textDelta(let s) = emitted[0] {
            XCTAssertEqual(s, "Hello")
        } else {
            XCTFail("Expected .textDelta, got \(emitted[0])")
        }
    }

    func testToolUseAccumulatesAcrossDeltasAndEmitsOnBlockStop() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })

        try acc.handle(eventJSON: """
        {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_abc","name":"grep","input":{}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"pattern\\":\\"Nev"}}
        """)
        try acc.handle(eventJSON: """
        {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"ille\\"}"}}
        """)
        XCTAssertTrue(emitted.isEmpty, "Should not emit until block_stop, got \(emitted)")

        try acc.handle(eventJSON: """
        {"type":"content_block_stop","index":1}
        """)

        XCTAssertEqual(emitted.count, 1)
        if case .toolUse(let id, let name, let input) = emitted[0] {
            XCTAssertEqual(id, "toolu_abc")
            XCTAssertEqual(name, "grep")
            XCTAssertEqual(input["pattern"] as? String, "Neville")
        } else {
            XCTFail("Expected .toolUse, got \(emitted[0])")
        }
    }

    func testStopEventCarriesStopReasonAndUsage() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })

        try acc.handle(eventJSON: """
        {"type":"message_start","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"output_tokens":0}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_stop"}
        """)

        XCTAssertEqual(emitted.count, 1)
        if case .stop(let reason, let usage) = emitted[0] {
            XCTAssertEqual(reason, .endTurn)
            XCTAssertEqual(usage.inputTokens, 5)
            XCTAssertEqual(usage.outputTokens, 7)
            XCTAssertEqual(usage.cacheReadTokens, 2)
            XCTAssertEqual(usage.cacheWriteTokens, 3)
        } else {
            XCTFail("Expected .stop, got \(emitted[0])")
        }
    }

    func testStopReasonToolUseRecognized() throws {
        var emitted: [ProviderEvent] = []
        var acc = AnthropicSSEAccumulator(onEvent: { emitted.append($0) })
        try acc.handle(eventJSON: """
        {"type":"message_start","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":3}}
        """)
        try acc.handle(eventJSON: """
        {"type":"message_stop"}
        """)
        XCTAssertEqual(emitted.count, 1)
        if case .stop(let reason, _) = emitted[0] {
            XCTAssertEqual(reason, .toolUse)
        } else {
            XCTFail("Expected .stop with .toolUse")
        }
    }
}
