import Foundation

/// Abstract LLM backend. One round trip per call. The agent does the looping.
protocol LLMProvider {
    func complete(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> AsyncThrowingStream<ProviderEvent, Error>
}

struct LLMMessage {
    enum Role {
        case user
        case assistant
    }
    let role: Role
    let content: [LLMContentBlock]
}

enum LLMContentBlock {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

struct LLMTool {
    let name: String
    let description: String
    let inputSchema: [String: Any]
}

enum ProviderEvent {
    case textDelta(String)
    case toolUse(id: String, name: String, input: [String: Any])
    /// A tool call the backend recognized as a tool-call attempt but could not
    /// turn into a usable `toolUse` (unparseable JSON, no inferable tool). The
    /// agent loop re-prompts the model instead of ending the turn. Only the
    /// local Qwen backend emits this; structured backends (Anthropic) do not.
    case malformedToolCall(raw: String)
    case stop(reason: StopReason, usage: ProviderUsage)
}

enum StopReason: Equatable {
    case endTurn
    case toolUse
    case maxTokens
    case other(String)
}

struct ProviderUsage: Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int

    static let zero = ProviderUsage(inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheWriteTokens: 0)
}

enum LLMProviderKind: String, CaseIterable, Identifiable {
    case anthropic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic (Claude)"
        }
    }
}
