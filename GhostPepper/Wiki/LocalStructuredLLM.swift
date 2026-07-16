import Foundation

/// Single-purpose completions against the local model, with JSON coercion
/// and one retry. This is the only way the wiki pipeline talks to the model:
/// no tools, no agent loop — one bounded prompt in, one parsed object out.
@MainActor
final class LocalStructuredLLM {
    enum LLMError: LocalizedError {
        case notJSON(String)

        var errorDescription: String? {
            switch self {
            case .notJSON(let preview):
                return "Local model did not return valid JSON. Output began: \(preview.prefix(160))"
            }
        }
    }

    let cleanupManager: TextCleanupManager
    let modelKind: LocalCleanupModelKind

    struct CompletionTrace {
        var text: String
        var estimatedInputTokens: Int
        var estimatedOutputTokens: Int
    }

    init(cleanupManager: TextCleanupManager, modelKind: LocalCleanupModelKind) {
        self.cleanupManager = cleanupManager
        self.modelKind = modelKind
    }

    /// Plain-text completion (used for narrative sections and merges).
    func complete(system: String, user: String) async throws -> String {
        try await completeWithTrace(system: system, user: user).text
    }

    /// Plain-text completion with token estimates and streaming callback.
    func completeWithTrace(
        system: String,
        user: String,
        onToken: ((String) -> Void)? = nil
    ) async throws -> CompletionTrace {
        let prompt = Self.buildPrompt(system: system, user: user)
        let stream = try await cleanupManager.streamCompletion(prompt: prompt, modelKind: modelKind)
        var out = ""
        for await token in stream {
            if Task.isCancelled { break }
            out += token
            onToken?(token)
        }
        let stripped = Self.stripThinking(out).trimmingCharacters(in: .whitespacesAndNewlines)
        return CompletionTrace(
            text: stripped,
            estimatedInputTokens: Self.estimatedTokenCount(prompt),
            estimatedOutputTokens: Self.estimatedTokenCount(stripped)
        )
    }

    /// JSON-object completion. Extracts the first balanced `{…}` from the
    /// model's output (ignoring `<think>` blocks and chatter); retries once
    /// with explicit feedback if parsing fails.
    func completeJSONObject(system: String, user: String) async throws -> [String: Any] {
        let first = try await complete(system: system, user: user)
        if let object = Self.extractJSONObject(from: first) {
            return object
        }
        let retryUser = user + """


        IMPORTANT: your previous reply was not valid JSON. Reply again with \
        ONLY a single JSON object — no prose, no markdown fences, no \
        explanation before or after it.
        """
        let second = try await complete(system: system, user: retryUser)
        if let object = Self.extractJSONObject(from: second) {
            return object
        }
        throw LLMError.notJSON(second.isEmpty ? first : second)
    }

    /// JSON-array completion. Used by the generated wiki pipeline for simple
    /// function-style extractors where the natural output is a list.
    func completeJSONArray(system: String, user: String) async throws -> [[String: Any]] {
        let first = try await complete(system: system, user: user)
        if let array = Self.extractJSONArray(from: first) {
            return array
        }
        let retryUser = user + """


        IMPORTANT: your previous reply was not valid JSON. Reply again with \
        ONLY a single JSON array — no prose, no markdown fences, no \
        explanation before or after it.
        """
        let second = try await complete(system: system, user: retryUser)
        if let array = Self.extractJSONArray(from: second) {
            return array
        }
        throw LLMError.notJSON(second.isEmpty ? first : second)
    }

    func completeJSONArrayWithTrace(
        system: String,
        user: String,
        onToken: ((String) -> Void)? = nil
    ) async throws -> (array: [[String: Any]], trace: CompletionTrace) {
        let first = try await completeWithTrace(system: system, user: user, onToken: onToken)
        if let array = Self.extractJSONArray(from: first.text) {
            return (array, first)
        }
        if let repaired = try? await repairJSONArray(raw: first.text, shapeHint: user, onToken: onToken) {
            return (repaired.array, CompletionTrace(
                text: repaired.trace.text,
                estimatedInputTokens: first.estimatedInputTokens + repaired.trace.estimatedInputTokens,
                estimatedOutputTokens: first.estimatedOutputTokens + repaired.trace.estimatedOutputTokens
            ))
        }
        let retryUser = user + """


        IMPORTANT: your previous reply was not valid JSON. Reply again with \
        ONLY a single JSON array — no prose, no markdown fences, no \
        explanation before or after it.
        """
        let second = try await completeWithTrace(system: system, user: retryUser, onToken: onToken)
        if let array = Self.extractJSONArray(from: second.text) {
            return (array, CompletionTrace(
                text: second.text,
                estimatedInputTokens: first.estimatedInputTokens + second.estimatedInputTokens,
                estimatedOutputTokens: first.estimatedOutputTokens + second.estimatedOutputTokens
            ))
        }
        if let repaired = try? await repairJSONArray(raw: second.text.isEmpty ? first.text : second.text, shapeHint: user, onToken: onToken) {
            return (repaired.array, CompletionTrace(
                text: repaired.trace.text,
                estimatedInputTokens: first.estimatedInputTokens + second.estimatedInputTokens + repaired.trace.estimatedInputTokens,
                estimatedOutputTokens: first.estimatedOutputTokens + second.estimatedOutputTokens + repaired.trace.estimatedOutputTokens
            ))
        }
        throw LLMError.notJSON(second.text.isEmpty ? first.text : second.text)
    }

    private func repairJSONArray(
        raw: String,
        shapeHint: String,
        onToken: ((String) -> Void)?
    ) async throws -> (array: [[String: Any]], trace: CompletionTrace) {
        let system = """
        /no_think
        You repair malformed model output into valid JSON. Output ONLY one JSON array.
        Do not add facts. Do not explain. Do not use markdown fences.
        """
        let user = """
        Convert the malformed output below into the JSON array requested by the original task.
        If an item is incomplete, keep supported fields and use empty strings or empty arrays for missing values.
        Output ONLY valid JSON.

        Original task and shape:
        \(shapeHint.prefix(4000))

        Malformed output:
        \(raw)
        """
        let trace = try await completeWithTrace(system: system, user: user, onToken: onToken)
        if let array = Self.extractJSONArray(from: trace.text) {
            return (array, trace)
        }
        throw LLMError.notJSON(trace.text)
    }

    // MARK: - Prompt assembly (Qwen3 chat template, same as LocalLLMProvider)

    static func buildPrompt(system: String, user: String) -> String {
        var prompt = ""
        prompt += "<|im_start|>system\n\(system)\n<|im_end|>\n"
        prompt += "<|im_start|>user\n\(user)\n<|im_end|>\n"
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    static func estimatedTokenCount(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.count) / 4.0)))
    }

    // MARK: - Output cleanup

    /// Removes `<think>…</think>` reasoning blocks (DeepSeek R1 and Qwen
    /// thinking mode) so JSON extraction sees only the real answer.
    static func stripThinking(_ s: String) -> String {
        var out = s
        while let open = out.range(of: "<think>") {
            if let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                // Unclosed think block: drop everything from <think> on.
                out.removeSubrange(open.lowerBound..<out.endIndex)
            }
        }
        return out
    }

    /// Finds the first balanced top-level JSON object in `raw` and parses it.
    /// Tolerates markdown fences, leading prose, and trailing chatter.
    static func extractJSONObject(from raw: String) -> [String: Any]? {
        let cleaned = stripThinking(raw)
        let chars = Array(cleaned)
        guard let start = chars.firstIndex(of: "{") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                if c == "\"" {
                    inString = true
                } else if c == "{" {
                    depth += 1
                } else if c == "}" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(chars[start...i])
                        if let data = candidate.data(using: .utf8),
                           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                            return object
                        }
                        return nil
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// Finds the first balanced top-level JSON array in `raw` and parses it.
    static func extractJSONArray(from raw: String) -> [[String: Any]]? {
        let cleaned = stripThinking(raw)
        let chars = Array(cleaned)
        guard let start = chars.firstIndex(of: "[") else { return nil }

        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
            } else {
                if c == "\"" {
                    inString = true
                } else if c == "[" {
                    depth += 1
                } else if c == "]" {
                    depth -= 1
                    if depth == 0 {
                        let candidate = String(chars[start...i])
                        if let array = parseJSONArrayCandidate(candidate) { return array }
                        return nil
                    }
                }
            }
            i += 1
        }
        return nil
    }

    private static func parseJSONArrayCandidate(_ candidate: String) -> [[String: Any]]? {
        for text in [candidate, relaxedJSON(candidate)] {
            if let data = text.data(using: .utf8),
               let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                return array
            }
        }
        return nil
    }

    private static func relaxedJSON(_ text: String) -> String {
        text
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #",\s*([\]}])"#, with: "$1", options: .regularExpression)
    }
}
