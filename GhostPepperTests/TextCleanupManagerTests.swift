import XCTest
@testable import GhostPepper

@MainActor
final class TextCleanupManagerTests: XCTestCase {
    func testAutomaticPolicyPrefersFastForShortInput() {
        let manager = TextCleanupManager(
            localModelPolicy: .automatic,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 4, isQuestion: false),
            .fast
        )
    }

    func testFastOnlyPolicyAlwaysReturnsFastWhenReady() {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 40, isQuestion: true),
            .fast
        )
    }

    func testFullOnlyPolicyAlwaysReturnsFullWhenReady() {
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 4, isQuestion: false),
            .full
        )
    }

    func testQuestionSelectionStillFlowsThroughManagerPolicy() {
        let manager = TextCleanupManager(
            localModelPolicy: .fastOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: true
        )

        XCTAssertEqual(
            manager.selectedModelKind(wordCount: 3, isQuestion: true),
            .fast
        )
    }

    func testAutomaticPolicyTreatsFastModelAsUsableWhenFullModelIsUnavailable() {
        let manager = TextCleanupManager(
            localModelPolicy: .automatic,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: false
        )

        XCTAssertTrue(manager.hasUsableModelForCurrentPolicy)
    }

    func testFullOnlyPolicyRequiresFullModelToBeUsable() {
        let manager = TextCleanupManager(
            localModelPolicy: .fullOnly,
            fastModelAvailabilityOverride: true,
            fullModelAvailabilityOverride: false
        )

        XCTAssertFalse(manager.hasUsableModelForCurrentPolicy)
    }
}
