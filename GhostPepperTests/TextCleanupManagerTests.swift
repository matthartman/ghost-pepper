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

    func testDeleteCachedModelNotifiesObserversForInventoryRefresh() {
        let manager = TextCleanupManager()
        let expectation = expectation(description: "cleanup manager publishes cache deletion")
        var cancellable: AnyCancellable? = manager.objectWillChange.sink {
            expectation.fulfill()
        }

        manager.deleteCachedModel(kind: .qwen35_0_8b_q4_k_m)

        wait(for: [expectation], timeout: 1.0)
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
