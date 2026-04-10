import XCTest
@testable import GhostPepper

@MainActor
final class RuntimeModelInventoryTests: XCTestCase {
    func testRuntimeModelRowsIncludeAllSpeechAndCleanupModels() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-small.en",
            speechModelState: .loading,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: ["openai_whisper-tiny.en"],
            cleanupState: .downloading(kind: .qwen35_4b_q4_k_m, progress: 0.4),
            selectedCleanupModelKind: .qwen35_4b_q4_k_m,
            cachedCleanupKinds: [.qwen35_0_8b_q4_k_m, .qwen35_2b_q4_k_m]
        )

        XCTAssertTrue(rows.map(\.name).contains("Whisper tiny.en (speed)"))
        XCTAssertTrue(rows.map(\.name).contains("Whisper small.en (accuracy)"))
        XCTAssertTrue(rows.map(\.name).contains("Whisper small (multilingual)"))
        XCTAssertTrue(rows.map(\.name).contains("Whisper multilingual (large v3 turbo)"))
        XCTAssertTrue(rows.map(\.name).contains("whisper.cpp Large v3 Turbo (q5_0 quantized)"))
        XCTAssertTrue(rows.map(\.name).contains("whisper.cpp Large v3 Turbo (f16 full precision)"))
        XCTAssertTrue(rows.map(\.name).contains("Parakeet v3 (25 languages)"))
        XCTAssertTrue(rows.map(\.name).contains("Qwen 3.5 0.8B Q4_K_M (Very fast)"))
        XCTAssertTrue(rows.map(\.name).contains("Qwen 3.5 2B Q4_K_M (Fast)"))
        XCTAssertTrue(rows.map(\.name).contains("Qwen 3.5 4B Q4_K_M (Full)"))

        XCTAssertEqual(row(named: "Whisper tiny.en (speed)", in: rows)?.status, .loaded)
        XCTAssertEqual(row(named: "Whisper tiny.en (speed)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Whisper small.en (accuracy)", in: rows)?.status, .downloading(progress: nil))
        XCTAssertEqual(row(named: "Whisper small.en (accuracy)", in: rows)?.isSelected, true)

        XCTAssertEqual(row(named: "Whisper small (multilingual)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "Whisper small (multilingual)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Whisper multilingual (large v3 turbo)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "Whisper multilingual (large v3 turbo)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "whisper.cpp Large v3 Turbo (q5_0 quantized)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "whisper.cpp Large v3 Turbo (q5_0 quantized)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "whisper.cpp Large v3 Turbo (f16 full precision)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "whisper.cpp Large v3 Turbo (f16 full precision)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Parakeet v3 (25 languages)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "Parakeet v3 (25 languages)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.status, .loaded)
        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.status, .loaded)
        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.isSelected, false)

        XCTAssertEqual(row(named: "Qwen 3.5 4B Q4_K_M (Full)", in: rows)?.status, .downloading(progress: 0.4))
        XCTAssertEqual(row(named: "Qwen 3.5 4B Q4_K_M (Full)", in: rows)?.isSelected, true)
    }

    func testRuntimeModelRowsSeparateSelectedSpeechModelFromActiveDownload() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-tiny.en",
            speechModelState: .loading,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: [],
            cleanupState: .idle,
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: []
        )

        XCTAssertEqual(rows[0].status, .downloading(progress: nil))
        XCTAssertFalse(rows[0].isSelected)

        XCTAssertEqual(rows[1].status, .notLoaded)
        XCTAssertTrue(rows[1].isSelected)
    }

    func testRuntimeModelRowsShowCachedSpeechModelAsLoadingInsteadOfDownloading() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-small.en",
            speechModelState: .loading,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: ["openai_whisper-small.en"],
            cleanupState: .idle,
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: []
        )

        XCTAssertEqual(rows[1].status, .loading)
        XCTAssertNil(RuntimeModelInventory.activeDownloadText(rows: rows))
    }

    func testRuntimeModelRowsShowActiveCleanupLoadForNonSelectedCleanupModel() {
        let rows = RuntimeModelInventory.rows(
            selectedSpeechModelName: "openai_whisper-small.en",
            activeSpeechModelName: "openai_whisper-small.en",
            speechModelState: .ready,
            speechDownloadProgress: nil,
            cachedSpeechModelNames: ["openai_whisper-small.en"],
            cleanupState: .loadingModel(kind: .qwen35_0_8b_q4_k_m),
            selectedCleanupModelKind: .qwen35_2b_q4_k_m,
            cachedCleanupKinds: [.qwen35_0_8b_q4_k_m]
        )

        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.status, .loading)
        XCTAssertEqual(row(named: "Qwen 3.5 0.8B Q4_K_M (Very fast)", in: rows)?.isSelected, false)
        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.status, .notLoaded)
        XCTAssertEqual(row(named: "Qwen 3.5 2B Q4_K_M (Fast)", in: rows)?.isSelected, true)
    }

    private func row(named name: String, in rows: [RuntimeModelRow]) -> RuntimeModelRow? {
        rows.first(where: { $0.name == name })
    }
}
