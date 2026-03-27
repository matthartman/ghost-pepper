import XCTest
@testable import GhostPepper

@MainActor
final class CorrectionStoreTests: XCTestCase {
    func testPreferredTranscriptionsRoundTripThroughStorePersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let store = CorrectionStore(defaults: defaults)
        store.preferredTranscriptionsText = "Ghost Pepper\nOpenAI"

        let reloadedStore = CorrectionStore(defaults: defaults)

        XCTAssertEqual(reloadedStore.preferredTranscriptions, ["Ghost Pepper", "OpenAI"])
    }

    func testCommonlyMisheardRoundTripThroughStorePersistence() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let store = CorrectionStore(defaults: defaults)
        store.commonlyMisheardText = "chat gbt -> ChatGPT\njust see -> Jesse"

        let reloadedStore = CorrectionStore(defaults: defaults)

        XCTAssertEqual(
            reloadedStore.commonlyMisheard,
            [
                MisheardReplacement(wrong: "chat gbt", right: "ChatGPT"),
                MisheardReplacement(wrong: "just see", right: "Jesse")
            ]
        )
    }

    func testPreferredTranscriptionsWinOverBroadReplacement() {
        let engine = DeterministicCorrectionEngine(
            preferredTranscriptions: ["Ghost Pepper"],
            commonlyMisheard: [MisheardReplacement(wrong: "ghost", right: "goes")]
        )

        let corrected = engine.applyPreCleanupCorrections(to: "ghost pepper is ready")

        XCTAssertEqual(corrected, "Ghost Pepper is ready")
    }

    func testCommonlyMisheardReplacementAppliesDeterministically() {
        let engine = DeterministicCorrectionEngine(
            preferredTranscriptions: [],
            commonlyMisheard: [MisheardReplacement(wrong: "chat gbt", right: "ChatGPT")]
        )

        let corrected = engine.applyPreCleanupCorrections(to: "open chat gbt and summarize this")

        XCTAssertEqual(corrected, "open ChatGPT and summarize this")
    }

    func testPreferredTranscriptionsDoNotRewritePostCleanupOutput() {
        let engine = DeterministicCorrectionEngine(
            preferredTranscriptions: ["Ghost Pepper"],
            commonlyMisheard: []
        )

        let corrected = engine.applyPostCleanupCorrections(to: "ghost pepper is ready")

        XCTAssertEqual(corrected, "ghost pepper is ready")
    }

    func testPreferredOCRCustomWordsMatchPreferredTranscriptions() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let store = CorrectionStore(defaults: defaults)
        store.preferredTranscriptionsText = "Ghost Pepper\nJesse"

        XCTAssertEqual(store.preferredOCRCustomWords, ["Ghost Pepper", "Jesse"])
    }

    func testCommonlyMisheardDraftPreservesIncompleteLine() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let store = CorrectionStore(defaults: defaults)
        store.commonlyMisheardText = "chat gbt -> ChatGPT\nstill typing"

        XCTAssertEqual(store.commonlyMisheardText, "chat gbt -> ChatGPT\nstill typing")
        XCTAssertEqual(store.commonlyMisheard, [MisheardReplacement(wrong: "chat gbt", right: "ChatGPT")])

        let reloadedStore = CorrectionStore(defaults: defaults)
        XCTAssertEqual(reloadedStore.commonlyMisheardText, "chat gbt -> ChatGPT\nstill typing")
        XCTAssertEqual(reloadedStore.commonlyMisheard, [MisheardReplacement(wrong: "chat gbt", right: "ChatGPT")])
    }

    func testAppendCommonlyMisheardPreservesDraftAndDeduplicates() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let store = CorrectionStore(defaults: defaults)
        store.commonlyMisheardText = "chat gbt -> ChatGPT\nstill typing"

        store.appendCommonlyMisheard(MisheardReplacement(wrong: "just see", right: "Jesse"))
        store.appendCommonlyMisheard(MisheardReplacement(wrong: "just see", right: "Jesse"))

        XCTAssertEqual(
            store.commonlyMisheardText,
            "chat gbt -> ChatGPT\nstill typing\njust see -> Jesse"
        )
        XCTAssertEqual(
            store.commonlyMisheard,
            [
                MisheardReplacement(wrong: "chat gbt", right: "ChatGPT"),
                MisheardReplacement(wrong: "just see", right: "Jesse")
            ]
        )
    }
}
