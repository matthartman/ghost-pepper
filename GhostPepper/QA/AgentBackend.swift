import Foundation

/// What model is driving the agent loop. Persisted as a tagged string in
/// `@AppStorage("agentBackend")` so we can pivot between cloud and local
/// without forking storage keys per backend kind.
///
/// Encoded form: `"claude:<ClaudeAPIModel.rawValue>"` or
/// `"local:<LocalCleanupModelKind.rawValue>"`.
enum AgentBackend: Equatable {
    case claude(ClaudeAPIModel)
    case local(LocalCleanupModelKind)

    var isLocal: Bool {
        switch self {
        case .claude: return false
        case .local: return true
        }
    }

    /// Compact label used in pickers and the running-cost footer.
    var shortDisplayName: String {
        switch self {
        case .claude(let model):
            return model.shortDisplayName
        case .local(let kind):
            return Self.localDisplayName(for: kind)
        }
    }

    /// Looks up the display name for a local model kind from the cleanup
    /// catalog. nonisolated so MeetingQAAgent's runLoop (which runs on a
    /// non-MainActor Task) can call it when emitting usage events.
    private static func localDisplayName(for kind: LocalCleanupModelKind) -> String {
        switch kind {
        case .qwen35_0_8b_q4_k_m: return "Qwen 3.5 0.8B"
        case .qwen35_2b_q4_k_m: return "Qwen 3.5 2B"
        case .qwen35_4b_q4_k_m: return "Qwen 3.5 4B"
        case .deepseek_r1_qwen_7b_q4_k_m: return "DeepSeek R1 7B"
        case .gemma4_12b_it_optiq_4bit_mlx: return "Gemma 4 12B MLX"
        }
    }

    /// Cost in USD for one round-trip's worth of usage. Local is always free.
    func estimatedCostUSD(usage: ProviderUsage) -> Double {
        switch self {
        case .claude(let model):
            return ClaudePricing.estimateCostUSD(
                model: model,
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheReadTokens,
                cacheWriteTokens: usage.cacheWriteTokens
            )
        case .local:
            return 0
        }
    }

    // MARK: - Persistence

    var encoded: String {
        switch self {
        case .claude(let model): return "claude:\(model.rawValue)"
        case .local(let kind): return "local:\(kind.rawValue)"
        }
    }

    /// Decodes a persisted string. Returns nil if the form is unrecognized;
    /// callers should fall back to a sensible default (typically Claude
    /// Sonnet) and overwrite the storage on next read.
    static func decode(_ raw: String) -> AgentBackend? {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let kind = String(parts[0])
        let value = String(parts[1])
        switch kind {
        case "claude":
            if let model = ClaudeAPIModel(rawValue: value) { return .claude(model) }
            return nil
        case "local":
            if let modelKind = LocalCleanupModelKind(rawValue: value) { return .local(modelKind) }
            return nil
        default:
            return nil
        }
    }

    /// Migration entry point. Reads the new `agentBackend` setting if set;
    /// otherwise initializes from the legacy `claudeAPIModel` setting and
    /// persists the result so future reads hit the new key.
    static func resolveFromDefaults(_ defaults: UserDefaults = .standard) -> AgentBackend {
        if let stored = defaults.string(forKey: "agentBackend"),
           let decoded = decode(stored) {
            return decoded
        }
        let legacy = defaults.string(forKey: "claudeAPIModel") ?? ClaudeAPIModel.sonnet.rawValue
        let model = ClaudeAPIModel(rawValue: legacy) ?? .sonnet
        let resolved: AgentBackend = .claude(model)
        defaults.set(resolved.encoded, forKey: "agentBackend")
        return resolved
    }
}
