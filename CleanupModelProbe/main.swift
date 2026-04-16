import Foundation
import RunAnywhere
import LlamaCPPRuntime

enum CleanupModelProbeMain {
    private static let ghostPepperDefaultsDomain = "com.github.matthartman.ghostpepper"

    @MainActor
    static func run() async -> Int32 {
        do {
            try RunAnywhere.initialize(environment: .development)
        } catch {
            fputs("RunAnywhere initialization failed: \(error.localizedDescription)\n", stderr)
            return EXIT_FAILURE
        }
        LlamaCPP.register()

        do {
            let command = try CleanupModelProbeCLI.parse(arguments: Array(CommandLine.arguments.dropFirst()))
            let manager = TextCleanupManager(selectedCleanupModelKind: command.modelKind)
            await manager.loadModel(kind: command.modelKind)
            let defaults = UserDefaults(suiteName: ghostPepperDefaultsDomain) ?? .standard

            let runner = CleanupModelProbeRunner(
                correctionStore: CorrectionStore(defaults: defaults)
            ) { input, prompt, modelKind, thinkingMode in
                try await manager.probe(
                    text: input,
                    prompt: prompt,
                    modelKind: modelKind,
                    thinkingMode: thinkingMode
                )
            }
            let activePrompt = command.prompt ?? defaults.string(forKey: "cleanupPrompt")

            if let input = command.input {
                try await runOneShot(command: command, runner: runner, input: input, prompt: activePrompt)
            } else {
                try await runInteractive(command: command, runner: runner, prompt: activePrompt)
            }

            return EXIT_SUCCESS
        } catch let error as CleanupModelProbeCLIError {
            fputs("\(error.localizedDescription)\n\n\(CleanupModelProbeCLI.usage)\n", stderr)
            return EXIT_FAILURE
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            return EXIT_FAILURE
        }
    }

    @MainActor
    private static func runOneShot(
        command: CleanupModelProbeCommand,
        runner: CleanupModelProbeRunner,
        input: String,
        prompt: String?
    ) async throws {
        let transcript = try await runProbe(command: command, runner: runner, input: input, prompt: prompt)
        print(CleanupModelProbeCLI.format(transcript))
    }

    @MainActor
    private static func runInteractive(
        command: CleanupModelProbeCommand,
        runner: CleanupModelProbeRunner,
        prompt: String?
    ) async throws {
        print("Loaded \(label(for: command.modelKind)). Enter text to probe, or :quit to exit.")

        while true {
            print("cleanup-probe> ", terminator: "")
            fflush(stdout)

            let nextInput = readLine()
            if CleanupModelProbeCLI.shouldExitInteractive(input: nextInput) {
                return
            }

            guard let nextInput else {
                return
            }

            if nextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            let transcript = try await runProbe(command: command, runner: runner, input: nextInput, prompt: prompt)
            print(CleanupModelProbeCLI.format(transcript))
            print("")
        }
    }

    @MainActor
    private static func runProbe(
        command: CleanupModelProbeCommand,
        runner: CleanupModelProbeRunner,
        input: String,
        prompt: String?
    ) async throws -> CleanupModelProbeTranscript {
        try await runner.run(
            input: input,
            modelKind: command.modelKind,
            thinkingMode: command.thinkingMode,
            prompt: prompt,
            windowContext: command.windowContext.map { OCRContext(windowContents: $0) }
        )
    }

    @MainActor
    private static func label(for modelKind: LocalCleanupModelKind) -> String {
        TextCleanupManager.cleanupModels.first(where: { $0.kind == modelKind })?.displayName ?? modelKind.rawValue
    }
}

Task {
    let exitCode = await CleanupModelProbeMain.run()
    exit(exitCode)
}

RunLoop.main.run()
