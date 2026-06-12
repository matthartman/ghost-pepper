import XCTest
@testable import GhostPepper

final class MeetingQASystemPromptTests: XCTestCase {
    func testPromptInterpolatesArchiveRoot() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Root: /tmp/Meetings"), prompt)
    }

    func testPromptDescribesGranolaFormat() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Granola-imported"), prompt)
        XCTAssertTrue(prompt.contains("YAML frontmatter"), prompt)
    }

    func testPromptDescribesNativeFormat() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Native Ghost Pepper"), prompt)
        XCTAssertTrue(prompt.contains("**Date:**"), prompt)
        XCTAssertTrue(prompt.contains("## Notes"), prompt)
    }

    func testPromptRequiresCitations() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("cite"), prompt)
        XCTAssertTrue(prompt.contains("path:line"), prompt)
    }

    func testPromptUsesQMDSearchAsPrimarySearchTool() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("qmd_search"), prompt)
        XCTAssertTrue(prompt.contains("Prefer qmd_search"), prompt)
        XCTAssertFalse(prompt.contains("Prefer grep"), prompt)
    }

    func testPromptGivesPersonTimelineRules() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Timeline questions"), prompt)
        XCTAssertTrue(prompt.contains("person's full name"), prompt)
        XCTAssertTrue(prompt.contains("Do not list every meeting date"), prompt)
        XCTAssertTrue(prompt.contains("Sort the final answer chronologically"), prompt)
    }

    func testPromptTellsModelNotToExposeToolPlans() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .local(.deepseek_r1_qwen_7b_q4_k_m), maxIterations: 15)
        XCTAssertTrue(prompt.contains("Never describe a tool-use plan"), prompt)
        XCTAssertTrue(prompt.contains("Do not write analysis"), prompt)
        XCTAssertTrue(prompt.contains("first visible"), prompt)
    }

    func testPromptHasVoiceToTextGuidance() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("voice-to-text") || prompt.contains("Voice-to-text"), prompt)
        XCTAssertTrue(prompt.contains("Quinn Adler"), "Should include the canonical artifact example")
    }

    func testPromptDescribesMultiHopGuidance() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("multi-hop") || prompt.contains("Multi-hop") || prompt.contains("know each other"), prompt)
    }

    func testPromptDescribesIterationBudget() {
        let prompt = MeetingQASystemPrompt.build(archiveRootPath: "/tmp/Meetings", backend: .claude(.sonnet), maxIterations: 15)
        XCTAssertTrue(prompt.contains("15"), "Iteration cap should be visible to the model")
    }

    func testLocalProviderPromptForcesArchiveToolCallFirst() {
        let tool = MeetingQAAgent.qaToolDefinitions().first { $0.name == "qmd_search" }!
        let prompt = LocalLLMProvider.buildPrompt(
            system: "System instructions",
            messages: [LLMMessage(role: .user, content: [.text("summarize my meetings with Owen Blake Carter as a timeline")])],
            tools: [tool]
        )
        XCTAssertTrue(prompt.contains("Emit a tool_call first"), prompt)
        XCTAssertTrue(prompt.contains(#""name":"qmd_search""#), prompt)
        XCTAssertTrue(prompt.contains("no hidden analysis"), prompt)
    }
}
