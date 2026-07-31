import XCTest
import Combine
@testable import GhostPepper

@MainActor
final class TextCleanupManagerTests: XCTestCase {
    actor ProbeConcurrencyHarness {
        private var isRunning = false

        func run(text: String) async -> CleanupModelProbeRawResult {
            if isRunning {
                return CleanupModelProbeRawResult(
                    modelKind: .qwen35_2b_q4_k_m,
                    modelDisplayName: TextCleanupManager.recommendedFastModel.displayName,
                    rawOutput: "",
                    elapsed: 0
                )
            }

            isRunning = true
            try? await Task.sleep(nanoseconds: 50_000_000)
            isRunning = false

            return CleanupModelProbeRawResult(
                modelKind: .qwen35_2b_q4_k_m,
                modelDisplayName: TextCleanupManager.recommendedFastModel.displayName,
                rawOutput: text,
                elapsed: 0.05
            )
        }
    }

    func testCleanupModelCatalogIncludesVeryFastFastAndFullQwenModels() {
        let modelsByKind = Dictionary(
            uniqueKeysWithValues: TextCleanupManager.cleanupModels.map { ($0.kind, $0) }
        )
        XCTAssertEqual(
            modelsByKind[.qwen35_0_8b_q4_k_m]?.displayName,
            "Qwen 3.5 0.8B Q4_K_M (Very fast)"
        )
        XCTAssertEqual(
            modelsByKind[.qwen35_2b_q4_k_m]?.displayName,
            "Qwen 3.5 2B Q4_K_M (Fast)"
        )
        XCTAssertEqual(
            modelsByKind[.qwen35_4b_q4_k_m]?.displayName,
            "Qwen 3.5 4B Q4_K_M (Full)"
        )
        XCTAssertEqual(
            TextCleanupManager.recommendedFullModel.fileName,
            "Qwen3.5-4B-Q4_K_M.gguf"
        )
    }

    func testDefaultSelectionUsesVeryFastModel() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let manager = TextCleanupManager(
            defaults: defaults,
            cleanupModelAvailabilityOverrides: [
                .qwen35_0_8b_q4_k_m: true
            ]
        )

        XCTAssertEqual(manager.selectedCleanupModelKind, .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 4, isQuestion: false),
            .qwen35_0_8b_q4_k_m
        )
    }

    func testSelectedCleanupModelPersistsConcreteModelChoice() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let manager = TextCleanupManager(
            defaults: defaults,
            cleanupModelAvailabilityOverrides: [
                .qwen35_0_8b_q4_k_m: true
            ]
        )
        manager.selectedCleanupModelKind = .qwen35_0_8b_q4_k_m

        let restored = TextCleanupManager(
            defaults: defaults,
            cleanupModelAvailabilityOverrides: [
                .qwen35_0_8b_q4_k_m: true
            ]
        )

        XCTAssertEqual(restored.selectedCleanupModelKind, .qwen35_0_8b_q4_k_m)
    }

    func testSelectedCleanupModelReturnsChosenModelWhenReady() {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_0_8b_q4_k_m: true
            ]
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 40, isQuestion: true),
            .qwen35_0_8b_q4_k_m
        )
    }

    func testSelectedCleanupModelTreatsChosenModelAsUsableWhenAvailable() {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_0_8b_q4_k_m: true
            ]
        )

        XCTAssertTrue(manager.hasUsableModelForCurrentPolicy)
    }

    func testSelectedCleanupModelRequiresChosenModelToBeUsable() {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_2b_q4_k_m: true
            ]
        )

        XCTAssertFalse(manager.hasUsableModelForCurrentPolicy)
    }

    func testCleanupSuppressesThinkingForProductionCleanupCalls() async throws {
        var capturedThinkingMode: CleanupModelProbeThinkingMode?
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_4b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_4b_q4_k_m: true
            ],
            probeExecutionOverride: { _, _, _, thinkingMode in
                capturedThinkingMode = thinkingMode
                return CleanupModelProbeRawResult(
                    modelKind: .qwen35_4b_q4_k_m,
                    modelDisplayName: TextCleanupManager.recommendedFullModel.displayName,
                    rawOutput: "That worked really well.",
                    elapsed: 0.01
                )
            }
        )

        let result = try await manager.clean(text: "That worked really well.", prompt: "unused prompt")

        XCTAssertEqual(result, "That worked really well.")
        XCTAssertEqual(capturedThinkingMode, .suppressed)
    }

    func testShutdownBackendCallsOverride() {
        var shutdownCount = 0
        let manager = TextCleanupManager(
            backendShutdownOverride: {
                shutdownCount += 1
            }
        )

        manager.shutdownBackend()
        manager.shutdownBackend()

        XCTAssertEqual(shutdownCount, 2)
    }

    func testCleanupSerializesOverlappingRequests() async throws {
        let harness = ProbeConcurrencyHarness()
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_4b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_4b_q4_k_m: true
            ],
            probeExecutionOverride: { text, _, _, _ in
                await harness.run(text: text)
            }
        )

        async let first = manager.clean(text: "first", prompt: "unused")
        async let second = manager.clean(text: "second", prompt: "unused")

        let results = try await [first, second]

        XCTAssertEqual(results, ["first", "second"])
    }

    func testCleanupThrowsUnavailableWhenSelectedModelIsMissing() async {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_4b_q4_k_m: true
            ]
        )

        await XCTAssertThrowsErrorAsync(try await manager.clean(text: "hello", prompt: "unused")) { error in
            XCTAssertEqual(error as? CleanupBackendError, .unavailable)
        }
    }

    func testCleanupThrowsUnusableOutputWhenModelReturnsPlaceholder() async {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_2b_q4_k_m: true
            ],
            probeExecutionOverride: { _, _, _, _ in
                CleanupModelProbeRawResult(
                    modelKind: .qwen35_2b_q4_k_m,
                    modelDisplayName: TextCleanupManager.recommendedFastModel.displayName,
                    rawOutput: "...",
                    elapsed: 0.01
                )
            }
        )

        await XCTAssertThrowsErrorAsync(try await manager.clean(text: "hello", prompt: "unused")) { error in
            XCTAssertEqual(
                error as? CleanupBackendError,
                .unusableOutput(rawOutput: "...")
            )
        }
    }

    func testCleanupThrowsTimedOutWhenProbeIsCancelled() async {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_2b_q4_k_m: true
            ],
            probeExecutionOverride: { _, _, _, _ in
                throw CancellationError()
            }
        )

        await XCTAssertThrowsErrorAsync(try await manager.clean(text: "hello", prompt: "unused")) { error in
            XCTAssertEqual(
                error as? CleanupBackendError,
                .timedOut(seconds: 15.0)
            )
        }
    }

    func testCleanupPurposeConfigProvidesDistinctContextAndTimeoutPerPurpose() {
        let realtime = TextCleanupManager.config(for: .realtime)
        let summarization = TextCleanupManager.config(for: .summarization)

        XCTAssertEqual(realtime.maxTokenCount, 4096)
        XCTAssertEqual(realtime.timeoutSeconds, 15.0)
        XCTAssertEqual(summarization.maxTokenCount, 16384)
        XCTAssertEqual(summarization.timeoutSeconds, 90.0)
    }

    func testGGUFCleanupModelsUseSixteenKContextWindow() {
        XCTAssertEqual(TextCleanupManager.compactModel.maxTokenCount, 16384)
        XCTAssertEqual(TextCleanupManager.recommendedFastModel.maxTokenCount, 16384)
        XCTAssertEqual(TextCleanupManager.recommendedFullModel.maxTokenCount, 16384)
    }

    func testCleanupLogsEstimatedTokenBudgetForPromptAndOutput() async throws {
        var loggedMessages: [String] = []
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_2b_q4_k_m: true
            ],
            probeExecutionOverride: { _, _, _, _ in
                CleanupModelProbeRawResult(
                    modelKind: .qwen35_2b_q4_k_m,
                    modelDisplayName: TextCleanupManager.recommendedFastModel.displayName,
                    rawOutput: "short output",
                    elapsed: 1.23
                )
            }
        )
        manager.debugLogger = { _, message in loggedMessages.append(message) }

        _ = try await manager.clean(text: "some transcript text", prompt: "summarize this")

        XCTAssertTrue(
            loggedMessages.contains {
                $0.contains("prompt") && $0.contains("output") && $0.contains("of 4096 max tokens (realtime)")
            },
            "Expected a debug log entry reporting the estimated token budget, got: \(loggedMessages)"
        )
    }

    func testDefaultMeetingSummaryModelSelectionUsesFullModel() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let manager = TextCleanupManager(defaults: defaults)

        XCTAssertEqual(manager.selectedMeetingSummaryModelKind, .qwen35_4b_q4_k_m)
    }

    func testMeetingSummaryModelSelectionPersistsIndependentlyOfRealtimeModel() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let manager = TextCleanupManager(
            defaults: defaults,
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            selectedMeetingSummaryModelKind: .qwen35_2b_q4_k_m
        )

        XCTAssertEqual(manager.selectedCleanupModelKind, .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(manager.selectedMeetingSummaryModelKind, .qwen35_2b_q4_k_m)

        let restored = TextCleanupManager(defaults: defaults)
        XCTAssertEqual(restored.selectedCleanupModelKind, .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(restored.selectedMeetingSummaryModelKind, .qwen35_2b_q4_k_m)
    }

    func testLoadModelReloadsWhenContextTokenCountChangesForSameKind() async {
        let manager = TextCleanupManager(
            cleanupModelAvailabilityOverrides: [.qwen35_0_8b_q4_k_m: true]
        )

        await manager.loadModel(kind: .qwen35_0_8b_q4_k_m, contextTokenCount: 4096)
        XCTAssertEqual(manager.activeLoadedModelKind, .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(manager.activeLoadedContextTokenCount, 4096)

        await manager.loadModel(kind: .qwen35_0_8b_q4_k_m, contextTokenCount: 16384)
        XCTAssertEqual(manager.activeLoadedModelKind, .qwen35_0_8b_q4_k_m)
        XCTAssertEqual(manager.activeLoadedContextTokenCount, 16384)
    }

    func testCleanUsesDistinctContextPerPurposeForSameModelKind() async throws {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_0_8b_q4_k_m,
            cleanupModelAvailabilityOverrides: [.qwen35_0_8b_q4_k_m: true],
            probeExecutionOverride: { _, _, modelKind, _ in
                CleanupModelProbeRawResult(
                    modelKind: modelKind,
                    modelDisplayName: TextCleanupManager.compactModel.displayName,
                    rawOutput: "cleaned",
                    elapsed: 0.01
                )
            }
        )

        _ = try await manager.clean(text: "hi", prompt: "unused", modelKind: .qwen35_0_8b_q4_k_m, purpose: .realtime)
        XCTAssertEqual(manager.activeLoadedContextTokenCount, 4096)

        _ = try await manager.clean(text: "hi", prompt: "unused", modelKind: .qwen35_0_8b_q4_k_m, purpose: .summarization)
        XCTAssertEqual(manager.activeLoadedContextTokenCount, 16384)
    }

    func testCleanupUsesSummarizationTimeoutWhenPurposeIsSummarization() async {
        let manager = TextCleanupManager(
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cleanupModelAvailabilityOverrides: [
                .qwen35_2b_q4_k_m: true
            ],
            probeExecutionOverride: { _, _, _, _ in
                throw CancellationError()
            }
        )

        await XCTAssertThrowsErrorAsync(
            try await manager.clean(text: "hello", prompt: "unused", purpose: .summarization)
        ) { error in
            XCTAssertEqual(
                error as? CleanupBackendError,
                .timedOut(seconds: 90.0)
            )
        }
    }

    func testDeleteCachedModelRemovesOnlyTheConfiguredCacheFileAndNotifiesObservers() throws {
        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: modelsDirectory) }

        let modelFile = modelsDirectory.appendingPathComponent(TextCleanupManager.compactModel.fileName)
        try Data("cached model".utf8).write(to: modelFile)

        let manager = TextCleanupManager(modelsDirectory: modelsDirectory)
        let expectation = expectation(description: "cleanup manager publishes cache deletion")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        manager.deleteCachedModel(kind: .qwen35_0_8b_q4_k_m)

        wait(for: [expectation], timeout: 1.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelFile.path))
        withExtendedLifetime(cancellable) {}
        cancellable = nil
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message().isEmpty ? "Expected error to be thrown." : message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
