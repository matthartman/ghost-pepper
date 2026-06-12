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
    private let answerVerificationEnabled: Bool

    /// Backward-compatible Q&A initializer. Wires up the standard
    /// MeetingQASystemPrompt and the read-only qmd_search / read_file / list_dir tools
    /// scoped to the meeting archive.
    convenience init(
        provider: LLMProvider,
        backend: AgentBackend,
        archiveRoot: URL,
        maxIterations: Int = 15
    ) {
        let tools = MeetingQATools(root: archiveRoot)
        let searchHandler: AgentToolHandler = { input in
            let query = (input["query"] as? String) ?? (input["pattern"] as? String) ?? ""
            let path = input["path"] as? String
            let caseInsensitive = (input["case_insensitive"] as? Bool) ?? true
            let maxResults = (input["max_results"] as? Int) ?? 50
            return try await tools.qmdSearch(query: query, path: path, caseInsensitive: caseInsensitive, maxResults: maxResults)
        }
        let handlers: [String: AgentToolHandler] = [
            "qmd_search": searchHandler,
            "grep": searchHandler,
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
        self.init(
            provider: provider,
            backend: backend,
            systemPrompt: MeetingQASystemPrompt.build(
                archiveRootPath: archiveRoot.path,
                backend: backend,
                maxIterations: maxIterations
            ),
            toolHandlers: handlers,
            toolDefinitions: Self.qaToolDefinitions(),
            summarizeInput: Self.summarizeQAInput,
            summarizeOutput: Self.summarizeQAOutput,
            maxIterations: maxIterations,
            answerVerificationEnabled: true
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
        maxIterations: Int = 15,
        answerVerificationEnabled: Bool = false
    ) {
        self.provider = provider
        self.backend = backend
        self.systemPrompt = systemPrompt
        self.toolHandlers = toolHandlers
        self.toolDefinitions = toolDefinitions
        self.summarizeInput = summarizeInput
        self.summarizeOutput = summarizeOutput
        self.maxIterations = maxIterations
        self.answerVerificationEnabled = answerVerificationEnabled
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
        var didMalformedRecovery = false
        var didNoToolRecovery = false
        var didVerificationRecovery = false
        var toolObservations: [MeetingQAToolObservation] = []
        // After the synthesis fallback fires, the next round trip must produce
        // plain text — a stubborn local model otherwise just emits more tool
        // calls and we never recover. Suppress tools for that single turn so
        // the model literally can't call them (both the per-call tools param
        // and the LocalLLMProvider's `<tools>` system block are gated on this).
        var suppressToolsNextTurn = false

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
            var malformedRaw: String? = nil

            let iterationTools = suppressToolsNextTurn ? [] : toolDefinitions
            suppressToolsNextTurn = false
            do {
                for try await event in provider.complete(system: systemPrompt, messages: messages, tools: iterationTools) {
                    if Task.isCancelled {
                        continuation.yield(.status("Stopped"))
                        continuation.finish()
                        return
                    }
                    switch event {
                    case .textDelta(let delta):
                        assistantTextBuffer += delta
                        if !backend.isLocal {
                            continuation.yield(.text(delta))
                        }
                    case .toolUse(let id, let name, let input):
                        pendingToolCalls.append((id, name, input))
                        assistantBlocks.append(.toolUse(id: id, name: name, input: input))
                    case .malformedToolCall(let raw):
                        // Captured, not streamed to the user — handled after the
                        // turn so we can re-prompt instead of ending on a blob.
                        malformedRaw = raw
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
                    toolObservations.append(MeetingQAToolObservation(name: call.name, input: call.input, output: output, isError: isError))
                    continuation.yield(.toolResult(id: call.id, summary: summarizeOutput(call.name, output, isError), fullOutput: output, isError: isError))
                    toolResultBlocks.append(.toolResult(toolUseId: call.id, content: output, isError: isError))
                }
                messages.append(LLMMessage(role: .user, content: toolResultBlocks))
                continue
            }

            // Malformed tool call the backend couldn't parse or infer a tool
            // from. Push back once with the correct format before giving up,
            // rather than ending the turn on an unparseable blob. (Only the
            // local Qwen backend emits this; structured backends never do.)
            if let raw = malformedRaw {
                if !didMalformedRecovery {
                    didMalformedRecovery = true
                    var blocks = assistantBlocks
                    blocks.append(.text("<tool_call>\n\(raw)\n</tool_call>"))
                    messages.append(LLMMessage(role: .assistant, content: blocks))
                    messages.append(LLMMessage(role: .user, content: [.text(Self.malformedToolCallRecoveryPrompt)]))
                    continuation.yield(.status("Recovering from a malformed tool call…"))
                    continue
                }
                continuation.yield(.error("The model produced malformed tool calls repeatedly and could not recover."))
                continuation.finish()
                return
            }

            switch stopReason {
            case .endTurn:
                if backend.isLocal,
                   !hasUsedTools,
                   shouldRetryLocalAnswerWithoutTools(userMessages: initialMessages, assistantText: assistantTextBuffer) {
                    if !didNoToolRecovery {
                        didNoToolRecovery = true
                        let question = Self.latestUserQuestion(in: initialMessages) ?? ""
                        let inputs = Self.localArchiveSearchInputs(for: question)
                        continuation.yield(.status("Searching archive before local answer…"))
                        var assistantToolBlocks: [LLMContentBlock] = []
                        var userToolResultBlocks: [LLMContentBlock] = []
                        for (index, input) in inputs.enumerated() {
                            let toolUseId = "local_qmd_search_\(index)_\(Int(Date().timeIntervalSince1970 * 1000))"
                            continuation.yield(.toolCall(
                                id: toolUseId,
                                name: "qmd_search",
                                inputSummary: summarizeInput("qmd_search", input),
                                fullInput: input
                            ))
                            let (output, isError) = await runTool(name: "qmd_search", input: input)
                            toolObservations.append(MeetingQAToolObservation(name: "qmd_search", input: input, output: output, isError: isError))
                            continuation.yield(.toolResult(
                                id: toolUseId,
                                summary: summarizeOutput("qmd_search", output, isError),
                                fullOutput: output,
                                isError: isError
                            ))
                            assistantToolBlocks.append(.toolUse(id: toolUseId, name: "qmd_search", input: input))
                            userToolResultBlocks.append(.toolResult(toolUseId: toolUseId, content: output, isError: isError))
                            if !isError && !MeetingQATools.isNoMatchesOutput(output) {
                                break
                            }
                        }
                        hasUsedTools = true
                        messages.append(LLMMessage(role: .assistant, content: assistantToolBlocks))
                        messages.append(LLMMessage(role: .user, content: userToolResultBlocks))
                        continue
                    }

                    continuation.yield(.error(Self.localNoToolFailureMessage))
                    continuation.finish()
                    return
                }

                // Synthesis fallback: weak local models sometimes do tool calls
                // and then stop without writing an answer. Push them once with
                // an explicit "now answer" message before giving up. Skipped if
                // no tools were used (the model genuinely had nothing to find)
                // or if we already tried synthesis once.
                if assistantTextBuffer.isEmpty && hasUsedTools && !didSynthesisFallback {
                    didSynthesisFallback = true
                    suppressToolsNextTurn = true
                    if !assistantBlocks.isEmpty {
                        messages.append(LLMMessage(role: .assistant, content: assistantBlocks))
                    }
                    let evidence = MeetingQAEvidencePacket(observations: toolObservations)
                    let synthesisPrompt = Self.synthesisPrompt(evidence: evidence)
                    messages.append(LLMMessage(role: .user, content: [.text(synthesisPrompt)]))
                    continuation.yield(.status("Synthesizing answer from tool results…"))
                    continue
                }
                if answerVerificationEnabled,
                   backend.isLocal,
                   hasUsedTools,
                   !assistantTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let evidence = MeetingQAEvidencePacket(observations: toolObservations)
                    let question = Self.latestUserQuestion(in: initialMessages) ?? Self.latestUserQuestion(in: messages) ?? ""
                    let verification = MeetingQAAnswerVerifier.validate(
                        answer: assistantTextBuffer,
                        question: question,
                        evidence: evidence,
                        archiveRoot: nil
                    )
                    if !verification.isValid {
                        if !didVerificationRecovery {
                            didVerificationRecovery = true
                            suppressToolsNextTurn = true
                            messages.append(LLMMessage(
                                role: .user,
                                content: [.text(Self.verificationRecoveryPrompt(reasons: verification.reasons, evidence: evidence))]
                            ))
                            continuation.yield(.status("Checking answer against source evidence…"))
                            continue
                        }

                        continuation.yield(.text(Self.fallbackAnswer(question: question, evidence: evidence)))
                        continuation.finish()
                        return
                    }
                }
                if backend.isLocal && !assistantTextBuffer.isEmpty {
                    continuation.yield(.text(assistantTextBuffer))
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

    private func shouldRetryLocalAnswerWithoutTools(userMessages: [LLMMessage], assistantText: String) -> Bool {
        guard !assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let latestQuestion = Self.latestUserQuestion(in: userMessages)?.lowercased() else { return false }

        let asksAboutArchive = [
            "meeting", "meetings", "transcript", "timeline", "summarize", "summary",
            "who", "when", "where", "what did", "with ", "about "
        ].contains { latestQuestion.contains($0) }
        guard asksAboutArchive else { return false }

        let text = assistantText.lowercased()
        if text.contains("qmd_search") || text.contains("list_dir") || text.contains("read_file") || text.contains("tool") {
            return true
        }
        if text.contains("without knowing") || text.contains("can't extract") || text.contains("impossible") || text.contains("perhaps") {
            return true
        }
        // A local archive answer with no citations is usually a hallucination
        // or a plan. Force one tool attempt before showing it.
        return Self.extractCitationLikePaths(from: assistantText).isEmpty
    }

    private static func latestUserQuestion(in messages: [LLMMessage]) -> String? {
        for message in messages.reversed() where message.role == .user {
            let text = message.content.compactMap { block -> String? in
                if case .text(let t) = block { return t }
                return nil
            }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    static func localArchiveSearchInput(for question: String) -> [String: Any] {
        localArchiveSearchInput(query: localArchiveSearchQuery(for: question))
    }

    static func localArchiveSearchInputs(for question: String) -> [[String: Any]] {
        localArchiveSearchQueries(for: question).map(localArchiveSearchInput(query:))
    }

    private static func localArchiveSearchInput(query: String) -> [String: Any] {
        [
            "query": query,
            "case_insensitive": true,
            "max_results": 50,
        ]
    }

    static func localArchiveSearchQueries(for question: String) -> [String] {
        let primary = localArchiveSearchQuery(for: question)
        let parts = primary
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { $0.count >= 3 }

        var queries: [String] = [primary]
        if parts.count > 1 {
            queries.append(contentsOf: parts)
        }
        var seen: Set<String> = []
        return queries.filter { query in
            let normalized = query.lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
            seen.insert(normalized)
            return true
        }
    }

    static func localArchiveSearchQuery(for question: String) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        if let quoted = firstRegexCapture(in: trimmed, pattern: #""([^"]{2,})""#) {
            return quoted
        }

        for marker in ["with", "about", "regarding"] {
            if let phrase = phraseAfter(marker: marker, in: trimmed), !phrase.isEmpty {
                return phrase
            }
        }

        let capitalizedPattern = #"\b[A-Z][A-Za-z'\-]+(?:\s+[A-Z][A-Za-z'\-]+){0,3}\b"#
        let capitalized = regexCaptures(in: trimmed, pattern: capitalizedPattern)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !["Can", "What", "Who", "When", "Where", "Tell"].contains($0) }
            .sorted { lhs, rhs in
                if lhs.split(separator: " ").count != rhs.split(separator: " ").count {
                    return lhs.split(separator: " ").count > rhs.split(separator: " ").count
                }
                return lhs.count > rhs.count
            }
        if let best = capitalized.first {
            return best
        }

        return trimmed
    }

    private static func phraseAfter(marker: String, in question: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: marker)
        guard let raw = firstRegexCapture(
            in: question,
            pattern: #"(?i)\b"# + escaped + #"\s+([A-Za-z0-9][A-Za-z0-9'\-]*(?:\s+[A-Za-z0-9][A-Za-z0-9'\-]*){0,5})"#
        ) else {
            return nil
        }

        let stopWords: Set<String> = [
            "a", "an", "and", "as", "at", "before", "for", "from", "in", "into",
            "meeting", "meetings", "of", "on", "or", "prior", "previous", "that",
            "the", "timeline", "to", "where", "who", "with",
        ]
        let kept = raw
            .split(separator: " ")
            .prefix { token in
                let normalized = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
                return !stopWords.contains(normalized)
            }
            .map(String.init)
        let phrase = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return phrase.isEmpty ? nil : phrase
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        regexCaptures(in: text, pattern: pattern).first
    }

    private static func regexCaptures(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { match in
            let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
            guard captureRange.location != NSNotFound else { return nil }
            return ns.substring(with: captureRange)
        }
    }

    private static func extractCitationLikePaths(from text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}/[A-Za-z0-9_\-\.]+\.md(?::\d+)?"#) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Sent back to the model after it emits a tool call we can't parse or map
    /// to a tool, nudging it to either retry in the exact wire format or answer
    /// in plain text.
    static let malformedToolCallRecoveryPrompt = """
    Your previous tool call could not be parsed — it was missing a valid "name" or had malformed JSON. \
    To call a tool, emit it in exactly this format:
    <tool_call>
    {"name": "<tool name>", "arguments": { ... }}
    </tool_call>
    where "name" is one of the available tools. Either retry the tool call in that exact format, or, if you \
    already have enough information, write your final answer in plain text with no tags.
    """

    /// Sent to local models that respond to an archive question with prose
    /// instead of using tools. Kept short and concrete because small models
    /// obey direct corrections better than long policy blocks.
    static let localNoToolRecoveryPrompt = """
    You answered without searching the archive. Do not explain your plan and do not say what you would do.

    Call a tool now. Start with qmd_search using the most distinctive exact name or phrase from the user's question. \
    For a timeline about a person, search that person's full name first; if no results come back, search name variants. \
    After tool results arrive, answer chronologically with citations as path:line.
    """

    static let localNoToolFailureMessage = """
    The local model answered without searching the meeting archive, even after Ghost Pepper asked it to use qmd_search. \
    I suppressed that answer because it would not be source-backed. Try a stronger local Q&A model, or switch this question to Claude.
    """

    static func synthesisPrompt(evidence: MeetingQAEvidencePacket) -> String {
        """
        Now write your final answer to the user's original question, citing source files as path:line. \
        Tools are unavailable for this reply.

        Use only the source evidence below. Every factual claim needs a citation. \
        Direct quotes must match the source text exactly.

        \(evidence.compactSummary(maxSnippets: 60))
        """
    }

    static func verificationRecoveryPrompt(reasons: [String], evidence: MeetingQAEvidencePacket) -> String {
        let reasonText = reasons.isEmpty ? "The draft was not grounded enough." : reasons.map { "- \($0)" }.joined(separator: "\n")
        return """
        Your draft was not grounded well enough, so it was not shown to the user.

        Fix these issues:
        \(reasonText)

        Write the final answer now. Use only the source evidence below. Cite every factual claim as path:line. \
        Direct quotes must match the source text exactly. Do not call tools. Do not explain your plan.

        \(evidence.compactSummary(maxSnippets: 80))
        """
    }

    static func fallbackAnswer(question: String, evidence: MeetingQAEvidencePacket) -> String {
        if evidence.isEmpty {
            return """
            I couldn't find source evidence strong enough to answer that reliably.
            """
        }
        return """
        I found source evidence, but the local model did not produce a fully verified answer. Here are the strongest source lines I found:

        \(evidence.compactSummary(maxSnippets: 24))
        """
    }

    // MARK: - Q&A defaults

    static func summarizeQAInput(name: String, input: [String: Any]) -> String {
        switch name {
        case "qmd_search", "grep":
            let pattern = (input["query"] as? String) ?? (input["pattern"] as? String) ?? ""
            let path = (input["path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return path.map { "query=\"\(pattern)\", path=\"\($0)\"" } ?? "query=\"\(pattern)\""
        case "read_file":
            let path = (input["path"] as? String) ?? "?"
            let offset = (input["offset"] as? Int) ?? 1
            let limit = (input["limit"] as? Int) ?? 200
            return "\(path) offset=\(offset) limit=\(limit)"
        case "list_dir":
            let path = (input["path"] as? String) ?? ""
            return path.isEmpty ? "(root)" : path
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

    static func qaToolDefinitions() -> [LLMTool] {
        let qmdSearch = LLMTool(
            name: "qmd_search",
            description: "Search the meeting archive with qmd BM25 keyword search. Returns each result with nearby line-numbered context, so you usually have enough to answer without a follow-up read_file. Result groups are separated by `--`. Lines marked with `:` are matches; lines marked with `-` are surrounding context. Prefer this over read_file when looking for names, dates, companies, or specific phrases.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Keywords or a short quoted phrase to search for. Use plain names, company names, dates, and distinctive terms."],
                    "path": ["type": "string", "description": "Optional subdirectory or file relative to the archive root."],
                    "case_insensitive": ["type": "boolean", "default": true],
                    "max_results": ["type": "integer", "default": 50, "maximum": 200],
                ] as [String: Any],
                "required": ["query"],
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
        return [qmdSearch, readFile, listDir]
    }
}

struct MeetingQAToolObservation {
    let name: String
    let input: [String: Any]
    let output: String
    let isError: Bool
}

struct MeetingQAEvidenceSnippet: Equatable {
    let path: String
    let line: Int
    let text: String
    let isMatch: Bool
}

struct MeetingQAEvidencePacket {
    let snippets: [MeetingQAEvidenceSnippet]
    let rawText: String

    init(observations: [MeetingQAToolObservation]) {
        let usable = observations.filter { !$0.isError }
        self.rawText = usable.map(\.output).joined(separator: "\n")
        self.snippets = usable.flatMap(Self.parseObservation)
    }

    var isEmpty: Bool { snippets.isEmpty }

    var observedPaths: Set<String> {
        Set(snippets.map(\.path))
    }

    func compactSummary(maxSnippets: Int = 60, maxLineLength: Int = 260) -> String {
        guard !snippets.isEmpty else {
            return "Source evidence: no matching source lines were returned by the tools."
        }

        let sorted = snippets.sorted {
            if $0.path != $1.path { return $0.path < $1.path }
            return $0.line < $1.line
        }
        let lines = sorted.prefix(max(1, maxSnippets)).map { snippet in
            let text = Self.truncate(snippet.text.isEmpty ? "(blank line)" : snippet.text, maxLength: maxLineLength)
            return "- \(snippet.path):\(snippet.line) \(text)"
        }
        var summary = "Source evidence:\n" + lines.joined(separator: "\n")
        if sorted.count > maxSnippets {
            summary += "\n- ... \(sorted.count - maxSnippets) more source lines omitted"
        }
        return summary
    }

    func containsQuote(_ quote: String) -> Bool {
        let normalizedQuote = Self.normalizeForQuoteCheck(quote)
        guard normalizedQuote.count >= 8 else { return true }
        let normalizedRaw = Self.normalizeForQuoteCheck(rawText)
        if normalizedRaw.contains(normalizedQuote) { return true }

        let normalizedSnippetText = Self.normalizeForQuoteCheck(snippets.map(\.text).joined(separator: "\n"))
        return normalizedSnippetText.contains(normalizedQuote)
    }

    private static func parseObservation(_ observation: MeetingQAToolObservation) -> [MeetingQAEvidenceSnippet] {
        switch observation.name {
        case "read_file":
            let path = (observation.input["path"] as? String) ?? ""
            return parseReadFileOutput(path: path, output: observation.output)
        default:
            return parsePathLineOutput(observation.output)
        }
    }

    private static func parsePathLineOutput(_ output: String) -> [MeetingQAEvidenceSnippet] {
        let pattern = #"^(.+?\.md)([:\-])(\d+)(?:[:\-])(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 5,
                  let pathRange = Range(match.range(at: 1), in: line),
                  let separatorRange = Range(match.range(at: 2), in: line),
                  let lineRange = Range(match.range(at: 3), in: line),
                  let textRange = Range(match.range(at: 4), in: line),
                  let lineNumber = Int(line[lineRange])
            else { return nil }

            return MeetingQAEvidenceSnippet(
                path: String(line[pathRange]),
                line: lineNumber,
                text: String(line[textRange]).trimmingCharacters(in: .whitespaces),
                isMatch: String(line[separatorRange]) == ":"
            )
        }
    }

    private static func parseReadFileOutput(path: String, output: String) -> [MeetingQAEvidenceSnippet] {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let pattern = #"^(\d+)\t(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine)
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 3,
                  let lineRange = Range(match.range(at: 1), in: line),
                  let textRange = Range(match.range(at: 2), in: line),
                  let lineNumber = Int(line[lineRange])
            else { return nil }

            return MeetingQAEvidenceSnippet(
                path: path,
                line: lineNumber,
                text: String(line[textRange]).trimmingCharacters(in: .whitespaces),
                isMatch: true
            )
        }
    }

    private static func truncate(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength - 1)) + "…"
    }

    private static func normalizeForQuoteCheck(_ value: String) -> String {
        value
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct MeetingQAAnswerVerification {
    let isValid: Bool
    let reasons: [String]
}

enum MeetingQAAnswerVerifier {
    static func validate(
        answer: String,
        question: String,
        evidence: MeetingQAEvidencePacket,
        archiveRoot: URL? = nil
    ) -> MeetingQAAnswerVerification {
        var reasons: [String] = []
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MeetingQAAnswerVerification(isValid: false, reasons: ["The answer was empty."])
        }

        let lower = trimmed.lowercased()
        let planningMarkers = [
            "okay, so i need",
            "okay, i need",
            "i need to figure out",
            "first, i'll",
            "i'll start",
            "i'll run",
            "let me check",
            "looking at the source evidence",
            "source evidence given by the user",
            "step-by-step explanation",
            "initial search",
            "relaxation strategy",
            "the assistant tried",
            "i conducted a search",
            "qmd_search",
            "perhaps the user wants",
            "therefore, perhaps",
            "the best approach is",
            "use list_dir",
            "without knowing how",
            "i can't extract",
            "i would need to",
            "i remember",
            "i recall",
        ]
        if let marker = planningMarkers.first(where: { lower.contains($0) }) {
            reasons.append("The answer exposed tool planning or uncertainty (`\(marker)`).")
        }

        let citations = extractCitations(from: trimmed)
        let archiveQuestion = asksArchiveQuestion(question)
        if archiveQuestion {
            if containsPlaceholderCitation(trimmed) {
                reasons.append("The answer used placeholder citations like `path:15` instead of real source paths.")
            }
            if !evidence.isEmpty, citations.isEmpty {
                reasons.append("The answer used archive evidence but did not cite any source file lines.")
            } else if evidence.isEmpty, makesUnsupportedNoEvidenceClaim(trimmed) {
                reasons.append("The answer made archive claims even though the tools returned no source evidence.")
            }
        }

        let observedPaths = evidence.observedPaths
        for citation in citations {
            let citationPath = citation.path
            let existsOnDisk = archiveRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(citationPath).path) } ?? false
            if !observedPaths.contains(citationPath) && !existsOnDisk {
                reasons.append("The citation \(citation.raw) was not present in the retrieved evidence.")
            }
        }

        if !evidence.isEmpty {
            let missingQuotes = extractDirectQuotes(from: trimmed).filter { !evidence.containsQuote($0) }
            if let firstMissingQuote = missingQuotes.first {
                reasons.append("The direct quote \"\(String(firstMissingQuote.prefix(80)))\" was not found in the retrieved evidence.")
            }
        }

        if question.lowercased().contains("timeline") {
            let datedLinesWithoutCitations = trimmed
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .filter { containsISODate($0) && extractCitations(from: $0).isEmpty }
            if !datedLinesWithoutCitations.isEmpty {
                reasons.append("Timeline date lines need source citations.")
            }
        }

        return MeetingQAAnswerVerification(isValid: reasons.isEmpty, reasons: reasons)
    }

    private static func asksArchiveQuestion(_ question: String) -> Bool {
        let lower = question.lowercased()
        return [
            "meeting", "meetings", "transcript", "timeline", "summarize",
            "summary", "who", "when", "where", "what did", "with ", "about "
        ].contains { lower.contains($0) }
    }

    private static func makesUnsupportedNoEvidenceClaim(_ answer: String) -> Bool {
        let lower = answer.lowercased()
        let unsupportedMarkers = [
            "however",
            "but wait",
            "i recall",
            "i remember",
            "might be related",
            "could be related",
            "maybe",
            "likely",
            "around mid",
            "took place",
            "participated",
            "attended",
            "met ",
        ]
        if unsupportedMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        if containsISODate(answer) {
            return true
        }

        let noEvidenceMarkers = [
            "couldn't find",
            "could not find",
            "no source evidence",
            "no matches",
            "didn't find",
            "did not find",
        ]
        return !noEvidenceMarkers.contains(where: { lower.contains($0) })
    }

    private static func containsPlaceholderCitation(_ answer: String) -> Bool {
        let patterns = [
            #"(?i)\bpath:\d+(?:-\d+)?\b"#,
            #"(?i)\[`path:\d+(?:-\d+)?`\]"#,
            #"(?i)\bsource:\s*path:\d+(?:-\d+)?\b"#,
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(answer.startIndex..<answer.endIndex, in: answer)
            return regex.firstMatch(in: answer, range: range) != nil
        }
    }

    private static func extractDirectQuotes(from text: String) -> [String] {
        let patterns = [
            #""([^"\n]{12,})""#,
            #"“([^”\n]{12,})”"#,
        ]
        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            return regex.matches(in: text, range: range).compactMap { match in
                guard match.numberOfRanges > 1 else { return nil }
                let value = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.rangeOfCharacter(from: .letters) == nil ? nil : value
            }
        }
    }

    private struct Citation {
        let raw: String
        let path: String
    }

    private static func extractCitations(from text: String) -> [Citation] {
        let pattern = #"\b((?:\d{4}-\d{2}-\d{2}|\.indexes|Reads)/[^\s,()\[\]`]+\.md)(?::\d+(?:-\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return Citation(
                raw: ns.substring(with: match.range(at: 0)),
                path: ns.substring(with: match.range(at: 1))
            )
        }
    }

    private static func containsISODate(_ text: String) -> Bool {
        let pattern = #"\b20\d{2}-\d{2}-\d{2}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
