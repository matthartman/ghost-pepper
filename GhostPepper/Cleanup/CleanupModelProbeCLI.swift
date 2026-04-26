import Foundation

struct CleanupModelProbeCommand: Equatable {
    let modelKind: LocalCleanupModelKind
    let input: String?
    let prompt: String?
    let windowContext: String?
    let thinkingMode: CleanupModelProbeThinkingMode

    var isInteractive: Bool {
        input == nil
    }
}

enum CleanupModelProbeCLIError: Error, LocalizedError, Equatable {
    case missingValue(flag: String)
    case unknownFlag(String)
    case invalidModel(String)
    case invalidThinkingMode(String)
    case duplicateWindowContextSource
    case emptyInput
    case invalidInputCombination(String)
    case failedToReadFile(String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let flag):
            return "Missing value for \(flag)."
        case .unknownFlag(let flag):
            return "Unknown flag \(flag)."
        case .invalidModel(let value):
            return "Unsupported model '\(value)'."
        case .invalidThinkingMode(let value):
            return "Unsupported thinking mode '\(value)'. Use 'none', 'suppressed', or 'enabled'."
        case .duplicateWindowContextSource:
            return "Use either --window-context or --window-context-file, not both."
        case .emptyInput:
            return "Input must not be empty."
        case .invalidInputCombination(let message):
            return message
        case .failedToReadFile(let path):
            return "Failed to read file at \(path)."
        }
    }
}

enum CleanupModelProbeCLI {
    static func parse(
        arguments: [String],
        readFile: (String) throws -> String = { path in
            try String(contentsOfFile: path, encoding: .utf8)
        }
    ) throws -> CleanupModelProbeCommand {
        var iterator = arguments.makeIterator()
        var modelKind: LocalCleanupModelKind?
        var input: String?
        var prompt: String?
        var windowContext: String?
        var windowContextFile: String?
        var thinkingMode: CleanupModelProbeThinkingMode = .none
        var interactiveRequested = false

        while let argument = iterator.next() {
            switch argument {
            case "--model":
                guard let value = iterator.next() else {
                    throw CleanupModelProbeCLIError.missingValue(flag: "--model")
                }
                guard let parsedModel = parseModelKind(value) else {
                    throw CleanupModelProbeCLIError.invalidModel(value)
                }
                modelKind = parsedModel
            case "--input":
                guard let value = iterator.next() else {
                    throw CleanupModelProbeCLIError.missingValue(flag: "--input")
                }
                if interactiveRequested {
                    throw CleanupModelProbeCLIError.invalidInputCombination(
                        "Use either --input for one-shot mode or --interactive, not both."
                    )
                }
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CleanupModelProbeCLIError.emptyInput
                }
                input = value
            case "--prompt":
                guard let value = iterator.next() else {
                    throw CleanupModelProbeCLIError.missingValue(flag: "--prompt")
                }
                prompt = value
            case "--window-context":
                guard let value = iterator.next() else {
                    throw CleanupModelProbeCLIError.missingValue(flag: "--window-context")
                }
                windowContext = value
            case "--window-context-file":
                guard let value = iterator.next() else {
                    throw CleanupModelProbeCLIError.missingValue(flag: "--window-context-file")
                }
                windowContextFile = value
            case "--thinking":
                guard let value = iterator.next() else {
                    throw CleanupModelProbeCLIError.missingValue(flag: "--thinking")
                }
                guard let parsedThinkingMode = CleanupModelProbeThinkingMode(rawValue: value) else {
                    throw CleanupModelProbeCLIError.invalidThinkingMode(value)
                }
                thinkingMode = parsedThinkingMode
            case "--interactive":
                interactiveRequested = true
                if input != nil {
                    throw CleanupModelProbeCLIError.invalidInputCombination(
                        "Use either --input for one-shot mode or --interactive, not both."
                    )
                }
            default:
                throw CleanupModelProbeCLIError.unknownFlag(argument)
            }
        }

        guard let resolvedModelKind = modelKind else {
            throw CleanupModelProbeCLIError.missingValue(flag: "--model")
        }

        if windowContext != nil && windowContextFile != nil {
            throw CleanupModelProbeCLIError.duplicateWindowContextSource
        }

        let resolvedWindowContext: String?
        if let windowContext {
            resolvedWindowContext = windowContext
        } else if let windowContextFile {
            do {
                resolvedWindowContext = try readFile(windowContextFile)
            } catch {
                throw CleanupModelProbeCLIError.failedToReadFile(windowContextFile)
            }
        } else {
            resolvedWindowContext = nil
        }

        return CleanupModelProbeCommand(
            modelKind: resolvedModelKind,
            input: input,
            prompt: prompt,
            windowContext: resolvedWindowContext,
            thinkingMode: thinkingMode
        )
    }

    static func shouldExitInteractive(input: String?) -> Bool {
        guard let input else {
            return true
        }

        return input.trimmingCharacters(in: .whitespacesAndNewlines) == ":quit"
    }

    static func format(_ transcript: CleanupModelProbeTranscript) -> String {
        [
            "Model: \(transcript.modelDisplayName) [\(displayName(for: transcript.modelKind))]",
            "Thinking mode: \(transcript.thinkingMode.rawValue)",
            String(format: "Elapsed: %.2fs", transcript.elapsed),
            "",
            "Prompt:",
            transcript.finalPrompt,
            "",
            "User input:",
            transcript.input,
            "",
            "Cleanup input:",
            transcript.modelInputText,
            "",
            "Model input:",
            transcript.modelInput,
            "",
            "Raw model output:",
            transcript.rawModelOutput,
            "",
            "Sanitized model output:",
            transcript.sanitizedOutput,
            "",
            "Final cleaned output:",
            transcript.finalOutput
        ].joined(separator: "\n")
    }

    static var usage: String {
        """
        Usage:
          CleanupModelProbe --model fast|full|qwen35_0_8b_q4_k_m|qwen35_2b_q4_k_m|qwen35_4b_q4_k_m [--input <text>] [--prompt <text>] [--window-context <text> | --window-context-file <path>] [--thinking none|suppressed|enabled]

        Notes:
          - Omit --input to enter interactive mode.
          - Type :quit or send EOF to exit interactive mode.
        """
    }

    private static func parseModelKind(_ value: String) -> LocalCleanupModelKind? {
        switch value {
        case "fast":
            return .fast
        case "full":
            return .full
        default:
            return LocalCleanupModelKind(rawValue: value)
        }
    }

    private static func displayName(for modelKind: LocalCleanupModelKind) -> String {
        if modelKind == .fast {
            return "fast"
        }

        if modelKind == .full {
            return "full"
        }

        return modelKind.rawValue
    }
}
