import Foundation

/// Drives the same `MeetingQAAgent` loop as `AnthropicProvider`, but against a
/// locally loaded Qwen 3.5 model. Rather than fork the loop, we translate the
/// provider-neutral message log into Qwen3's chat-template format, stream
/// tokens through `QwenToolCallParser`, and re-emit them as `ProviderEvent`s.
///
/// Tool definitions are surfaced in the system block as a `<tools>` JSON list;
/// tool calls come back as `<tool_call>{...}</tool_call>`; tool results are
/// fed back as `<tool_response name="...">...</tool_response>`. This is the
/// Hermes-2-Pro / Qwen3 convention.
///
/// Stop reason is inferred: a turn that emitted at least one `<tool_call>` ends
/// with `.toolUse`; an otherwise plain-text turn ends with `.endTurn`.
/// Token usage is reported as zero — we don't meter local runs.
struct LocalLLMProvider: LLMProvider {
    let cleanupManager: TextCleanupManager
    let modelKind: LocalCleanupModelKind

    func complete(
        system: String,
        messages: [LLMMessage],
        tools: [LLMTool]
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let prompt = Self.buildPrompt(system: system, messages: messages, tools: tools)
                let parser = QwenToolCallParser()
                var emittedToolCall = false
                var idCounter = 0

                func emit(_ outputs: [QwenToolCallParser.Output]) {
                    for output in outputs {
                        switch output {
                        case .text(let t):
                            guard !t.isEmpty else { continue }
                            continuation.yield(.textDelta(t))
                        case .toolCall(let name, let input):
                            idCounter += 1
                            let id = "qtu_\(idCounter)_\(Int(Date().timeIntervalSince1970 * 1000))"
                            emittedToolCall = true
                            continuation.yield(.toolUse(id: id, name: name, input: input))
                        case .malformedToolCall(let raw):
                            // Don't surface to the user as text; let the agent
                            // loop decide to re-prompt.
                            continuation.yield(.malformedToolCall(raw: raw))
                        }
                    }
                }

                do {
                    let stream = try await cleanupManager.streamCompletion(
                        prompt: prompt,
                        modelKind: modelKind
                    )
                    for await token in stream {
                        if Task.isCancelled { break }
                        emit(parser.consume(token))
                    }
                    emit(parser.finish())

                    let stopReason: StopReason = emittedToolCall ? .toolUse : .endTurn
                    continuation.yield(.stop(reason: stopReason, usage: .zero))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Prompt assembly

    static func buildPrompt(system: String, messages: [LLMMessage], tools: [LLMTool]) -> String {
        var prompt = ""
        prompt += "<|im_start|>system\n"
        prompt += buildSystemBody(system: system, tools: tools)
        prompt += "<|im_end|>\n"

        // As we walk messages we track tool_use_id -> tool name from each
        // assistant turn so the next user turn's tool_result blocks can be
        // rendered with their matching name.
        var idToToolName: [String: String] = [:]

        for message in messages {
            switch message.role {
            case .user:
                prompt += "<|im_start|>user\n"
                prompt += encodeUserContent(blocks: message.content, idToToolName: idToToolName)
                prompt += "<|im_end|>\n"
            case .assistant:
                prompt += "<|im_start|>assistant\n"
                prompt += encodeAssistantContent(blocks: message.content)
                prompt += "<|im_end|>\n"
                for block in message.content {
                    if case .toolUse(let id, let name, _) = block {
                        idToToolName[id] = name
                    }
                }
            }
        }

        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    private static func buildSystemBody(system: String, tools: [LLMTool]) -> String {
        var body = system
        if !tools.isEmpty {
            body += "\n\nYou have access to tools that search the meeting archive. Call them when the user's question needs information from past meetings.\n\n"
            body += "<tools>\n"
            for tool in tools {
                let toolJSON: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.inputSchema,
                ]
                if let data = try? JSONSerialization.data(withJSONObject: toolJSON, options: []),
                   let str = String(data: data, encoding: .utf8) {
                    body += str + "\n"
                }
            }
            body += "</tools>\n\n"
            body += """
            To call a tool, emit a tool_call block exactly like this — JSON inside XML tags:
            <tool_call>
            {"name": "<tool name>", "arguments": {<json arguments>}}
            </tool_call>

            When the user asks about meetings, transcripts, people in the archive, dates, or timelines, do not answer from memory and do not describe a plan. Emit a tool_call first.
            Good first call for person timelines:
            <tool_call>
            {"name":"qmd_search","arguments":{"query":"Person Full Name","case_insensitive":true,"max_results":50}}
            </tool_call>

            You may emit multiple tool_call blocks in a single turn. After each round of tools, the user message will contain <tool_response> blocks with the results — read them and either continue answering or call more tools. When you've gathered enough information, write your final answer in plain text with no tool_call tags and no hidden analysis.
            """
        }
        body += "\n"
        return body
    }

    private static func encodeAssistantContent(blocks: [LLMContentBlock]) -> String {
        var s = ""
        for block in blocks {
            switch block {
            case .text(let t):
                s += t
            case .toolUse(_, let name, let input):
                let payload: [String: Any] = ["name": name, "arguments": input]
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                   let json = String(data: data, encoding: .utf8) {
                    s += "\n<tool_call>\n\(json)\n</tool_call>\n"
                }
            case .toolResult:
                break
            }
        }
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    private static func encodeUserContent(blocks: [LLMContentBlock], idToToolName: [String: String]) -> String {
        var s = ""
        for block in blocks {
            switch block {
            case .text(let t):
                s += t
                if !s.hasSuffix("\n") { s += "\n" }
            case .toolResult(let toolUseId, let content, let isError):
                let name = idToToolName[toolUseId] ?? "tool"
                let truncated = Self.truncatedToolResult(content)
                let prefix = isError ? "ERROR: " : ""
                s += "<tool_response name=\"\(name)\">\n\(prefix)\(truncated)\n</tool_response>\n"
            case .toolUse:
                break
            }
        }
        if !s.hasSuffix("\n") { s += "\n" }
        return s
    }

    /// Local Qwen models have a 32K context window; we trim long tool results
    /// more aggressively than cloud to leave room for further iterations.
    private static let toolResultCharLimit = 4000

    private static func truncatedToolResult(_ content: String) -> String {
        guard content.count > toolResultCharLimit else { return content }
        let head = content.prefix(toolResultCharLimit)
        let dropped = content.count - toolResultCharLimit
        return "\(head)\n…[truncated \(dropped) characters]"
    }
}
