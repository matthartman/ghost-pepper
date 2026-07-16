import Foundation

typealias AgentToolHandler = ([String: Any]) async throws -> String

final class MeetingQAAgent {
    private let provider: LLMProvider
    private let backend: AgentBackend
    private let systemPrompt: String
    private let toolHandlers: [String: AgentToolHandler]
    private let toolDefinitions: [LLMTool]
    private let summarizeInput: (String, [String: Any]) -> String
    private let summarizeOutput: (String, String, Bool) -> String
    private let maxIterations: Int

    /// Backward-compatible Q&A initializer. Wires up the standard
    /// MeetingQASystemPrompt and the read-only grep / read_file / list_dir tools
    /// scoped to the meeting archive.
    convenience init(
        provider: LLMProvider,
        backend: AgentBackend,
        archiveRoot: URL,
        maxIterations: Int = 15,
        searchService: QMDService? = nil
    ) {
        let tools = MeetingQATools(root: archiveRoot)
        // The hybrid search tool appears only when qmd is installed; the
        // agent falls back to pure grep otherwise.
        let search: QMDService? = (searchService?.isAvailable == true) ? searchService : nil
        var handlers: [String: AgentToolHandler] = [
            "grep": { input in
                let pattern = (input["pattern"] as? String) ?? ""
                let path = input["path"] as? String
                let caseInsensitive = (input["case_insensitive"] as? Bool) ?? true
                let maxResults = (input["max_results"] as? Int) ?? 50
                return try await tools.grep(pattern: pattern, path: path, caseInsensitive: caseInsensitive, maxResults: maxResults)
            },
            "read_file": { input in
                let path = (input["path"] as? String) ?? ""
                let offset = (input["offset"] as? Int) ?? 1
                let limit = (input["limit"] as? Int) ?? 200
                return try await tools.readFile(path: path, offset: offset, limit: limit)
            },
            "list_dir": { input in
                let path = (input["path"] as? String) ?? ""
                return try await tools.listDir(path: path)
            },
        ]
        if let search {
            handlers["search"] = { input in
                let query = (input["query"] as? String) ?? ""
                let limit = (input["k"] as? Int) ?? 8
                return try await search.search(query: query, limit: limit)
            }
        }
        self.init(
            provider: provider,
            backend: backend,
            systemPrompt: MeetingQASystemPrompt.build(
                archiveRootPath: archiveRoot.path,
                backend: backend,
                maxIterations: maxIterations,
                hasSemanticSearch: search != nil
            ),
            toolHandlers: handlers,
            toolDefinitions: Self.qaToolDefinitions(includeSearch: search != nil),
            summarizeInput: Self.summarizeQAInput,
            summarizeOutput: Self.summarizeQAOutput,
            maxIterations: maxIterations
        )
    }

    /// Generic initializer. Used for Q&A (via the convenience init above) and
    /// for the indexing flow, which passes its own prompt + tools (incl.
    /// write_file) so the same loop drives a different task.
    init(
        provider: LLMProvider,
        backend: AgentBackend,
        systemPrompt: String,
        toolHandlers: [String: AgentToolHandler],
        toolDefinitions: [LLMTool],
        summarizeInput: @escaping (String, [String: Any]) -> String,
        summarizeOutput: @escaping (String, String, Bool) -> String,
        maxIterations: Int = 15
    ) {
        self.provider = provider
        self.backend = backend
        self.systemPrompt = systemPrompt
        self.toolHandlers = toolHandlers
        self.toolDefinitions = toolDefinitions
        self.summarizeInput = summarizeInput
        self.summarizeOutput = summarizeOutput
        self.maxIterations = maxIterations
    }

    func ask(_ question: String) -> AsyncThrowingStream<QAEvent, Error> {
        ask(messages: [LLMMessage(role: .user, content: [.text(question)])])
    }

    /// Multi-turn entry point. Pass an alternating user/assistant message
    /// list ending with the new user question; the agent runs its tool-use
    /// loop on top of that history.
    func ask(messages initialMessages: [LLMMessage]) -> AsyncThrowingStream<QAEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                await self.runLoop(initialMessages: initialMessages, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runLoop(initialMessages: [LLMMessage], continuation: AsyncThrowingStream<QAEvent, Error>.Continuation) async {
        var messages: [LLMMessage] = initialMessages
        var cumulativeUsage = ProviderUsage.zero
        var hasUsedTools = false
        var didSynthesisFallback = false

        for _ in 0..<maxIterations {
            if Task.isCancelled {
                continuation.yield(.status("Stopped"))
                continuation.finish()
                return
            }

            var assistantBlocks: [LLMContentBlock] = []
            var pendingToolCalls: [(id: String, name: String, input: [String: Any])] = []
            var stopReason: StopReason = .other("missing")
            var iterationUsage: ProviderUsage = .zero
            var assistantTextBuffer = ""

            do {
                for try await event in provider.complete(system: systemPrompt, messages: messages, tools: toolDefinitions) {
                    if Task.isCancelled {
                        continuation.yield(.status("Stopped"))
                        continuation.finish()
                        return
                    }
                    switch event {
                    case .textDelta(let delta):
                        assistantTextBuffer += delta
                        continuation.yield(.text(delta))
                    case .toolUse(let id, let name, let input):
                        pendingToolCalls.append((id, name, input))
                        assistantBlocks.append(.toolUse(id: id, name: name, input: input))
                    case .stop(let reason, let usage):
                        stopReason = reason
                        iterationUsage = usage
                    }
                }
            } catch {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
                return
            }

            if !assistantTextBuffer.isEmpty {
                assistantBlocks.insert(.text(assistantTextBuffer), at: 0)
            }
            cumulativeUsage = ProviderUsage(
                inputTokens: cumulativeUsage.inputTokens + iterationUsage.inputTokens,
                outputTokens: cumulativeUsage.outputTokens + iterationUsage.outputTokens,
                cacheReadTokens: cumulativeUsage.cacheReadTokens + iterationUsage.cacheReadTokens,
                cacheWriteTokens: cumulativeUsage.cacheWriteTokens + iterationUsage.cacheWriteTokens
            )
            emitUsage(cumulativeUsage, continuation: continuation)

            if !pendingToolCalls.isEmpty {
                hasUsedTools = true
                messages.append(LLMMessage(role: .assistant, content: assistantBlocks))

                var toolResultBlocks: [LLMContentBlock] = []
                for call in pendingToolCalls {
                    continuation.yield(.toolCall(id: call.id, name: call.name, inputSummary: summarizeInput(call.name, call.input), fullInput: call.input))
                    let (output, isError) = await runTool(name: call.name, input: call.input)
                    continuation.yield(.toolResult(id: call.id, summary: summarizeOutput(call.name, output, isError), fullOutput: output, isError: isError))
                    toolResultBlocks.append(.toolResult(toolUseId: call.id, content: output, isError: isError))
                }
                messages.append(LLMMessage(role: .user, content: toolResultBlocks))
                continue
            }

            switch stopReason {
            case .endTurn:
                // Synthesis fallback: weak local models sometimes do tool calls
                // and then stop without writing an answer. Push them once with
                // an explicit "now answer" message before giving up. Skipped if
                // no tools were used (the model genuinely had nothing to find)
                // or if we already tried synthesis once.
                if assistantTextBuffer.isEmpty && hasUsedTools && !didSynthesisFallback {
                    didSynthesisFallback = true
                    if !assistantBlocks.isEmpty {
                        messages.append(LLMMessage(role: .assistant, content: assistantBlocks))
                    }
                    let synthesisPrompt = """
                    Now write your final answer to the user's original question, citing source files as path:line. \
                    If your searches did not find enough to answer fully, summarize what you searched, what you found, \
                    and what the closest match was. Do not call any more tools — just write the answer.
                    """
                    messages.append(LLMMessage(role: .user, content: [.text(synthesisPrompt)]))
                    continuation.yield(.status("Synthesizing answer from tool results…"))
                    continue
                }
                continuation.finish()
                return
            case .maxTokens:
                continuation.yield(.error("Model hit max_tokens before finishing."))
                continuation.finish()
                return
            case .toolUse:
                continuation.finish()
                return
            case .other(let raw):
                continuation.yield(.error("Unexpected stop reason: \(raw)"))
                continuation.finish()
                return
            }
        }

        continuation.yield(.status("Hit iteration cap of \(maxIterations)"))
        continuation.finish()
    }

    private func runTool(name: String, input: [String: Any]) async -> (output: String, isError: Bool) {
        guard let handler = toolHandlers[name] else {
            return ("Unknown tool: \(name)", true)
        }
        do {
            let out = try await handler(input)
            return (out, false)
        } catch {
            return (error.localizedDescription, true)
        }
    }

    private func emitUsage(_ usage: ProviderUsage, continuation: AsyncThrowingStream<QAEvent, Error>.Continuation) {
        continuation.yield(.usage(QAUsage(
            modelDisplayName: backend.shortDisplayName,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            estimatedCostUSD: backend.estimatedCostUSD(usage: usage),
            isLocal: backend.isLocal
        )))
    }

    // MARK: - Q&A defaults

    static func summarizeQAInput(name: String, input: [String: Any]) -> String {
        switch name {
        case "grep":
            let pattern = (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return path.map { "pattern=\"\(pattern)\", path=\"\($0)\"" } ?? "pattern=\"\(pattern)\""
        case "read_file":
            let path = (input["path"] as? String) ?? "?"
            let offset = (input["offset"] as? Int) ?? 1
            let limit = (input["limit"] as? Int) ?? 200
            return "\(path) offset=\(offset) limit=\(limit)"
        case "list_dir":
            let path = (input["path"] as? String) ?? ""
            return path.isEmpty ? "(root)" : path
        case "search":
            let query = (input["query"] as? String) ?? ""
            return "query=\"\(query)\""
        default:
            return ""
        }
    }

    static func summarizeQAOutput(name: String, output: String, isError: Bool) -> String {
        if isError {
            return "ERROR: \(output.prefix(120))"
        }
        let lineCount = output.split(separator: "\n").count
        return "\(lineCount) lines"
    }

    static func qaToolDefinitions(includeSearch: Bool = false) -> [LLMTool] {
        let grep = LLMTool(
            name: "grep",
            description: "Search the meeting archive for a regex pattern. Returns each match with 2 lines of context before and after, so you usually have enough to answer without a follow-up read_file. Match groups are separated by `--`. Lines marked with `:` are matches; lines marked with `-` are surrounding context. Prefer this over read_file when looking for names, dates, or specific phrases — it's much cheaper than reading whole files.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "pattern": ["type": "string", "description": "Regex pattern. Use plain strings for names. Use \\b for word boundaries."],
                    "path": ["type": "string", "description": "Optional subdirectory or file relative to the archive root."],
                    "case_insensitive": ["type": "boolean", "default": true],
                    "max_results": ["type": "integer", "default": 50, "maximum": 200],
                ] as [String: Any],
                "required": ["pattern"],
            ]
        )
        let readFile = LLMTool(
            name: "read_file",
            description: "Read a slice of a meeting transcript file. Returns the content with line numbers prepended for easy citation.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path relative to archive root."],
                    "offset": ["type": "integer", "default": 1, "description": "1-indexed starting line."],
                    "limit": ["type": "integer", "default": 200, "maximum": 1000],
                ] as [String: Any],
                "required": ["path"],
            ]
        )
        let listDir = LLMTool(
            name: "list_dir",
            description: "List entries in a directory inside the meeting archive. Use to discover meetings by date — directories are named YYYY-MM-DD.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Path relative to archive root. Use '.' or empty string for the root."],
                ] as [String: Any],
                "required": ["path"],
            ]
        )
        var tools = [grep, readFile, listDir]
        if includeSearch {
            tools.insert(LLMTool(
                name: "search",
                description: "Hybrid semantic + keyword search over the meeting archive (local, via qmd). Use this FIRST for conceptual or discovery questions where the transcript may not contain the question's exact words (e.g. 'companies building environment capture for robotics training'). Returns ranked excerpts with path:line citations, formatted like grep output. Prefer grep only for exact names, dates, or quoted strings.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Natural-language description of what you're looking for. Full phrases work better than keywords."],
                        "k": ["type": "integer", "default": 8, "maximum": 20, "description": "How many results to return."],
                    ] as [String: Any],
                    "required": ["query"],
                ]
            ), at: 0)
        }
        return tools
    }
}
