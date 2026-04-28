import XCTest
@testable import GhostPepper

@MainActor
final class PostPasteLearningCoordinatorTests: XCTestCase {
    func testCoordinatorStartsPollingImmediatelyAfterPaste() async throws {
        XCTAssertEqual(PostPasteLearningCoordinator.observationWindow, 15)
        XCTAssertEqual(PostPasteLearningCoordinator.pollInterval, 1)
        XCTAssertEqual(PostPasteLearningCoordinator.quiescencePeriod, 2)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var revisitCallCount = 0
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in
                scheduledCalls.append((delay, work))
            },
            revisit: { _ in
                revisitCallCount += 1
                return nil
            }
        )

        coordinator.handlePaste(samplePasteSession())

        XCTAssertEqual(scheduledCalls.count, 1)
        XCTAssertEqual(scheduledCalls.first?.0, 0)
        XCTAssertEqual(revisitCallCount, 0)

        await runNextScheduledCall(&scheduledCalls)
        await waitUntil { revisitCallCount == 1 }

        XCTAssertEqual(revisitCallCount, 1)
    }

    func testCoordinatorRejectsLargeRewriteDiffs() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledWork: (() -> Void)?
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { _, work in scheduledWork = work },
            revisit: { _ in
                PostPasteLearningObservation(
                    text: "This sentence was rewritten into something unrelated"
                )
            }
        )

        coordinator.handlePaste(samplePasteSession())
        scheduledWork?()
        await Task.yield()

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorStoresHighConfidenceNarrowReplacement() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var observations = [
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it"
        ]
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                guard !observations.isEmpty else {
                    return nil
                }

                let text = observations.removeFirst()
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(&scheduledCalls, count: 3)
        await waitUntil {
            correctionStore.commonlyMisheard == [MisheardReplacement(wrong: "just see", right: "Jesse")]
        }

        XCTAssertEqual(
            correctionStore.commonlyMisheard,
            [MisheardReplacement(wrong: "just see", right: "Jesse")]
        )
    }

    func testCoordinatorUsesInjectedSchedulerInsteadOfRealSleep() {
        let correctionStore = CorrectionStore(defaults: UserDefaults(suiteName: #function)!)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in
                scheduledCalls.append((delay, work))
            },
            revisit: { _ in
                XCTFail("Revisit should not run until the test triggers the scheduled work")
                return nil
            }
        )

        coordinator.handlePaste(samplePasteSession())

        XCTAssertEqual(scheduledCalls.map(\.0), [0])
    }

    func testCoordinatorDoesNotScheduleWhenLearningIsDisabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledWork: (() -> Void)?
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            learningEnabled: false,
            scheduler: { _, work in
                scheduledWork = work
            },
            revisit: { _ in
                XCTFail("Disabled learning should not trigger text-field revisit")
                return nil
            }
        )

        coordinator.handlePaste(samplePasteSession())

        XCTAssertNil(scheduledWork)
        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorRejectsChangesOutsideThePastedWords() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var observations = [
            "tomorrow maybe later",
            "tomorrow maybe later",
            "tomorrow maybe later",
            "tomorrow maybe later",
            "tomorrow maybe later"
        ]
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                let text = observations.removeFirst()
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(&scheduledCalls, count: 3)
        await Task.yield()

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorRejectsThreeWordReplacement() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var observations = [
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow",
            "please email Jesse Vincent tomorrow"
        ]
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                let text = observations.removeFirst()
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )

        coordinator.handlePaste(samplePasteSession(
            pastedText: "please email just see vincent tomorrow",
            focusedElementText: "please email just see vincent tomorrow"
        ))
        await runScheduledCalls(&scheduledCalls, count: 3)
        await Task.yield()

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testCoordinatorIgnoresPunctuationOnlyEdits() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var observations = [
            "like approved it",
            "like approved it",
            "like approved it",
            "like approved it",
            "like approved it"
        ]
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                let text = observations.removeFirst()
                return PostPasteLearningObservation(text: text)
            }
        )

        coordinator.handlePaste(samplePasteSession(
            pastedText: "like? approved it",
            focusedElementText: "like? approved it"
        ))
        await runScheduledCalls(&scheduledCalls, count: 3)
        await waitUntil(timeout: 0.2) {
            !correctionStore.commonlyMisheard.isEmpty
        }

        XCTAssertTrue(correctionStore.commonlyMisheard.isEmpty)
    }

    func testInferredReplacementIgnoresPunctuationOnlyChanges() {
        let replacement = PostPasteLearningCoordinator.inferredReplacement(
            from: "like? approved it",
            to: "like approved it",
            constrainedTo: "like? approved it"
        )

        XCTAssertNil(replacement)
    }

    func testInferredReplacementKeepsCaseChangesInsideCandidateReplacement() {
        let replacement = PostPasteLearningCoordinator.inferredReplacement(
            from: "please email just see vincent tomorrow",
            to: "please email Jesse Vincent tomorrow",
            constrainedTo: "please email just see vincent tomorrow"
        )

        XCTAssertNil(replacement)
    }

    func testCoordinatorLogsScheduledAndLearnedCorrection() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var observations = [
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it"
        ]
        var debugMessages: [String] = []
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                let text = observations.removeFirst()
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )
        coordinator.debugLogger = { _, message in
            debugMessages.append(message)
        }

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(&scheduledCalls, count: 3)
        await waitUntil {
            correctionStore.commonlyMisheard == [MisheardReplacement(wrong: "just see", right: "Jesse")]
        }

        XCTAssertTrue(debugMessages.contains(where: { $0.contains("Scheduled post-paste learning polling session") }))
        XCTAssertTrue(debugMessages.contains(where: { $0.contains("Post-paste learning learned replacement: just see -> Jesse") }))
    }

    func testCoordinatorLogsWhyLearningSkippedWhenPollingWindowExpires() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var debugMessages: [String] = []
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                nil
            }
        )
        coordinator.debugLogger = { _, message in
            debugMessages.append(message)
        }

        coordinator.handlePaste(samplePasteSession())
        while !scheduledCalls.isEmpty {
            await runNextScheduledCall(&scheduledCalls)
        }
        await waitUntil {
            debugMessages.contains(where: { $0.contains("Post-paste learning skipped because the polling window expired without a stable correction") })
        }

        XCTAssertTrue(debugMessages.contains(where: { $0.contains("Post-paste learning skipped because the polling window expired without a stable correction") }))
    }

    func testCoordinatorNotifiesWhenItLearnsCorrection() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var observations = [
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it",
            "Jesse approved it"
        ]
        var learnedReplacement: MisheardReplacement?
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                let text = observations.removeFirst()
                return PostPasteLearningObservation(
                    text: text
                )
            }
        )
        coordinator.onLearnedCorrection = { replacement in
            learnedReplacement = replacement
        }

        coordinator.handlePaste(samplePasteSession())
        await runScheduledCalls(&scheduledCalls, count: 3)
        await waitUntil { learnedReplacement == MisheardReplacement(wrong: "just see", right: "Jesse") }

        XCTAssertEqual(learnedReplacement, MisheardReplacement(wrong: "just see", right: "Jesse"))
    }

    func testCoordinatorCanLearnAfterLateInitialSnapshotCapture() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        var scheduledCalls: [(TimeInterval, () -> Void)] = []
        var observations: [PostPasteLearningObservation?] = [
            nil,
            PostPasteLearningObservation(text: "just see approved it"),
            PostPasteLearningObservation(text: "Jesse approved it"),
            PostPasteLearningObservation(text: "Jesse approved it"),
            PostPasteLearningObservation(text: "Jesse approved it")
        ]
        let coordinator = PostPasteLearningCoordinator(
            correctionStore: correctionStore,
            scheduler: { delay, work in scheduledCalls.append((delay, work)) },
            revisit: { _ in
                guard !observations.isEmpty else {
                    return nil
                }

                return observations.removeFirst()
            }
        )

        coordinator.handlePaste(samplePasteSession(focusedElementText: nil))

        await runScheduledCalls(&scheduledCalls, count: 5)
        await waitUntil {
            correctionStore.commonlyMisheard == [MisheardReplacement(wrong: "just see", right: "Jesse")]
        }

        XCTAssertEqual(
            correctionStore.commonlyMisheard,
            [MisheardReplacement(wrong: "just see", right: "Jesse")]
        )
    }

    private func samplePasteSession(
        pastedText: String = "just see approved it",
        focusedElementText: String? = "just see approved it"
    ) -> PasteSession {
        PasteSession(
            pastedText: pastedText,
            pastedAt: Date(timeIntervalSince1970: 1_742_751_200),
            frontmostAppBundleIdentifier: "com.example.app",
            frontmostWindowID: 42,
            frontmostWindowFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            focusedElementFrame: CGRect(x: 20, y: 40, width: 300, height: 120),
            focusedElementText: focusedElementText
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 0.5,
        condition: @escaping @Sendable () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func runScheduledCalls(
        _ scheduledCalls: inout [(TimeInterval, () -> Void)],
        count: Int
    ) async {
        for _ in 0..<count {
            await runNextScheduledCall(&scheduledCalls)
        }
    }

    private func runNextScheduledCall(
        _ scheduledCalls: inout [(TimeInterval, () -> Void)]
    ) async {
        let deadline = Date().addingTimeInterval(0.5)
        while scheduledCalls.isEmpty, Date() < deadline {
            await Task.yield()
        }

        XCTAssertFalse(scheduledCalls.isEmpty)
        scheduledCalls.removeFirst().1()
        await Task.yield()
    }
}
