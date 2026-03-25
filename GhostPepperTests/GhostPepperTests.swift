import XCTest
import SwiftUI
@testable import GhostPepper

private final class FakeHotkeyMonitor: HotkeyMonitoring {
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkStop: (() -> Void)?
    var onToggleToTalkStart: (() -> Void)?
    var onToggleToTalkStop: (() -> Void)?

    var updatedBindings: [ChordAction: KeyChord] = [:]
    var startResult = true
    var startCallCount = 0
    var suspendedStates: [Bool] = []

    func start() -> Bool {
        startCallCount += 1
        return startResult
    }

    func stop() {}

    func updateBindings(_ bindings: [ChordAction: KeyChord]) {
        updatedBindings = bindings
    }

    func setSuspended(_ suspended: Bool) {
        suspendedStates.append(suspended)
    }
}

private final class FakeAppRelauncher: AppRelaunching {
    var relaunchCallCount = 0
    var error: Error?

    func relaunch() throws {
        relaunchCallCount += 1
        if let error {
            throw error
        }
    }
}

@MainActor
final class GhostPepperTests: XCTestCase {
    private func makeDebugLogStore() -> DebugLogStore {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("debug-log.json")
        return DebugLogStore(storageURL: fileURL)
    }

    override func tearDown() {
        PermissionChecker.current = PermissionChecker.defaultClient
        super.tearDown()
    }

    func testAppStateInitialStatus() {
        // AppState is @MainActor so we test basic enum
        XCTAssertEqual(AppStatus.ready.rawValue, "Ready")
        XCTAssertEqual(AppStatus.recording.rawValue, "Recording...")
        XCTAssertEqual(AppStatus.transcribing.rawValue, "Transcribing...")
        XCTAssertEqual(AppStatus.error.rawValue, "Error")
    }

    func testEmptyTranscriptionDispositionCancelsShortRecordings() {
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 79_999),
            .cancel
        )
    }

    func testEmptyTranscriptionDispositionShowsNoSoundForFiveSecondsOrLonger() {
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 80_000),
            .showNoSoundDetected
        )
        XCTAssertEqual(
            AppState.emptyTranscriptionDisposition(forAudioSampleCount: 96_000),
            .showNoSoundDetected
        )
    }

    func testNoSoundDetectedOverlayMessageUsesExpectedCopy() {
        XCTAssertEqual(OverlayMessage.noSoundDetected.primaryText, "No sound detected")
        XCTAssertNil(OverlayMessage.noSoundDetected.secondaryText)
    }

    func testOverlayHostingViewDoesNotManageWindowSizingConstraints() {
        let overlay = RecordingOverlayController()
        overlay.show(message: .recording)
        defer { overlay.dismiss() }

        let panel: NSPanel? = unwrapPrivateOptional(named: "panel", from: overlay)
        let hostingView: NSHostingView<OverlayPillView>? = unwrapPrivateOptional(
            named: "hostingView",
            from: overlay
        )

        XCTAssertNotNil(panel)
        XCTAssertNotNil(hostingView)
        XCTAssertEqual(hostingView?.sizingOptions, [])
        XCTAssertFalse(panel?.contentView is NSHostingView<OverlayPillView>)
    }

    private func unwrapPrivateOptional<T>(named name: String, from object: Any) -> T? {
        let mirror = Mirror(reflecting: object)
        guard let child = mirror.children.first(where: { $0.label == name }) else {
            return nil
        }

        let optionalMirror = Mirror(reflecting: child.value)
        guard optionalMirror.displayStyle == .optional else {
            return child.value as? T
        }

        return optionalMirror.children.first?.value as? T
    }

    func testAppStateLoadsDefaultShortcutBindingsIntoHotkeyMonitor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))

        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.updatedBindings[.pushToTalk], AppState.defaultPushToTalkChord)
        XCTAssertEqual(monitor.updatedBindings[.toggleToTalk], AppState.defaultToggleToTalkChord)
    }

    func testAppStateWiresPushAndToggleCallbacksIntoHotkeyMonitor() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))

        await appState.startHotkeyMonitor()

        XCTAssertNotNil(monitor.onPushToTalkStart)
        XCTAssertNotNil(monitor.onPushToTalkStop)
        XCTAssertNotNil(monitor.onToggleToTalkStart)
        XCTAssertNotNil(monitor.onToggleToTalkStop)
    }

    func testAppStateStartHotkeyMonitorSkipsRepeatedStartAfterSuccess() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            inputMonitoringChecker: { true }
        )

        await appState.startHotkeyMonitor()
        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.startCallCount, 1)
    }

    func testAppStateStartHotkeyMonitorPromptsForInputMonitoringButStillStartsWhenMonitorCanRun() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        var requestCount = 0
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            inputMonitoringChecker: { false },
            inputMonitoringPrompter: { requestCount += 1 }
        )

        await appState.startHotkeyMonitor()

        XCTAssertEqual(monitor.startCallCount, 1)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(appState.status, .ready)
        XCTAssertNil(appState.errorMessage)
    }

    func testAppStateUpdateShortcutRefreshesHotkeyMonitorBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))
        let newChord = try XCTUnwrap(KeyChord(keys: Set([
            PhysicalKey(keyCode: 54),
            PhysicalKey(keyCode: 61),
            PhysicalKey(keyCode: 53)
        ])))

        appState.updateShortcut(newChord, for: .pushToTalk)

        XCTAssertEqual(appState.pushToTalkChord, newChord)
        XCTAssertEqual(monitor.updatedBindings[.pushToTalk], newChord)
    }

    func testAppStateUpdateShortcutRejectsDuplicateBindings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(hotkeyMonitor: monitor, chordBindingStore: ChordBindingStore(defaults: defaults))
        let originalToggleChord = appState.toggleToTalkChord

        appState.updateShortcut(AppState.defaultPushToTalkChord, for: .toggleToTalk)

        XCTAssertEqual(appState.toggleToTalkChord, originalToggleChord)
        XCTAssertEqual(monitor.updatedBindings[.toggleToTalk], originalToggleChord)
        XCTAssertEqual(appState.shortcutErrorMessage, "That shortcut is already in use.")
    }

    func testAppStateLoadsPersistedCleanupBackendSelection() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        defaults.set("foundationModels", forKey: "cleanupBackend")

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertEqual(appState.cleanupBackend, .localModels)
    }

    func testAppStateUpdateCleanupBackendPersistsAndUpdatesTextCleaner() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.updateCleanupBackend(.localModels)

        XCTAssertEqual(appState.cleanupBackend, .localModels)
        XCTAssertEqual(
            defaults.string(forKey: "cleanupBackend"),
            CleanupBackendOption.localModels.rawValue
        )
    }

    func testAppStateDefaultsPostPasteLearningToEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertTrue(appState.postPasteLearningEnabled)
        XCTAssertTrue(appState.postPasteLearningCoordinator.learningEnabled)
    }

    func testAppStateUpdatePostPasteLearningPersistsAndUpdatesCoordinator() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.postPasteLearningEnabled = false

        XCTAssertFalse(appState.postPasteLearningEnabled)
        XCTAssertFalse(appState.postPasteLearningCoordinator.learningEnabled)
        XCTAssertEqual(defaults.object(forKey: "postPasteLearningEnabled") as? Bool, false)
    }

    func testAppStateRelaunchAppUsesConfiguredRelauncher() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let relauncher = FakeAppRelauncher()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            appRelauncher: relauncher
        )

        appState.relaunchApp()

        XCTAssertEqual(relauncher.relaunchCallCount, 1)
        XCTAssertNil(appState.errorMessage)
    }

    func testAppStateRelaunchAppSurfacesRelaunchFailures() throws {
        struct RelaunchError: LocalizedError {
            var errorDescription: String? { "open failed" }
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let relauncher = FakeAppRelauncher()
        relauncher.error = RelaunchError()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            appRelauncher: relauncher
        )

        appState.relaunchApp()

        XCTAssertEqual(relauncher.relaunchCallCount, 1)
        XCTAssertEqual(appState.errorMessage, "Failed to relaunch Ghost Pepper: open failed")
    }

    func testSettingsWindowHostsSwiftUIViaContentViewController() throws {
        closeWindows(titled: "Ghost Pepper Settings")
        defer { closeWindows(titled: "Ghost Pepper Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = SettingsWindowController()

        controller.show(appState: appState)

        let window = try XCTUnwrap(NSApp.windows.first(where: { $0.title == "Ghost Pepper Settings" }))
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController)
    }

    func testSettingsWindowControllerCloseButtonOrdersWindowOutWithoutClosing() throws {
        closeWindows(titled: "Ghost Pepper Settings")
        defer { closeWindows(titled: "Ghost Pepper Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = SettingsWindowController()

        controller.show(appState: appState)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Ghost Pepper Settings" && $0.isVisible })
        )

        let shouldClose = window.delegate?.windowShouldClose?(window)

        XCTAssertEqual(shouldClose, false)
        XCTAssertFalse(window.isVisible)

        controller.show(appState: appState)
        let reopenedWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Ghost Pepper Settings" && $0.isVisible })
        )

        XCTAssertTrue(window === reopenedWindow)
    }

    func testPromptEditorHostsSwiftUIViaContentViewController() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)

        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController)
    }

    func testPromptEditorControllerReusesExistingWindow() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let firstWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )

        controller.show(appState: appState)
        let secondWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        defer { secondWindow.close() }

        XCTAssertTrue(firstWindow === secondWindow)
    }

    func testPromptEditorControllerDismissKeepsWindowReusable() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let firstWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )

        controller.dismiss()
        XCTAssertFalse(firstWindow.isVisible)

        controller.show(appState: appState)
        let secondWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        defer { secondWindow.close() }

        XCTAssertTrue(firstWindow === secondWindow)
    }

    func testPromptEditorControllerCloseButtonOrdersWindowOutWithoutClosing() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )

        let shouldClose = controller.windowShouldClose(window)

        XCTAssertFalse(shouldClose)
        XCTAssertFalse(window.isVisible)
    }

    func testPromptEditorControllerDismissResignsFirstResponder() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        let controller = PromptEditorController()

        controller.show(appState: appState)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Edit Cleanup Prompt" && $0.isVisible })
        )
        let textView = NSTextView(frame: .zero)
        window.contentView?.addSubview(textView)
        XCTAssertTrue(window.makeFirstResponder(textView))

        controller.dismiss()

        XCTAssertFalse(window.firstResponder === textView)
    }

    func testAppStateShowPromptEditorReusesSingleWindow() throws {
        closeWindows(titled: "Edit Cleanup Prompt")
        defer { closeWindows(titled: "Edit Cleanup Prompt") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showPromptEditor()
        appState.showPromptEditor()

        let windows = NSApp.windows.filter { $0.title == "Edit Cleanup Prompt" && $0.isVisible }
        defer { windows.forEach { $0.close() } }

        XCTAssertEqual(windows.count, 1)
    }

    func testAppStateShowSettingsReusesSingleWindow() throws {
        closeWindows(titled: "Ghost Pepper Settings")
        defer { closeWindows(titled: "Ghost Pepper Settings") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showSettings()
        appState.showSettings()

        let windows = NSApp.windows.filter { $0.title == "Ghost Pepper Settings" }
        defer { windows.forEach { $0.close() } }

        XCTAssertEqual(windows.count, 1)
    }

    func testAppStateShowDebugLogHostsSwiftUIViaContentViewController() throws {
        closeWindows(titled: "Ghost Pepper Debug Log")
        defer { closeWindows(titled: "Ghost Pepper Debug Log") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showDebugLog()

        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Ghost Pepper Debug Log" && $0.isVisible })
        )
        defer { window.close() }

        XCTAssertNotNil(window.contentViewController)
    }

    func testDebugLogWindowControllerCloseButtonOrdersWindowOutWithoutClosing() throws {
        closeWindows(titled: "Ghost Pepper Debug Log")
        defer { closeWindows(titled: "Ghost Pepper Debug Log") }
        let controller = DebugLogWindowController()
        let debugLogStore = makeDebugLogStore()

        controller.show(debugLogStore: debugLogStore)
        let window = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Ghost Pepper Debug Log" && $0.isVisible })
        )

        let shouldClose = window.delegate?.windowShouldClose?(window)

        XCTAssertEqual(shouldClose, false)
        XCTAssertFalse(window.isVisible)

        controller.show(debugLogStore: debugLogStore)
        let reopenedWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Ghost Pepper Debug Log" && $0.isVisible })
        )

        XCTAssertTrue(window === reopenedWindow)
    }

    func testAppStateShowDebugLogReusesSingleWindow() throws {
        closeWindows(titled: "Ghost Pepper Debug Log")
        defer { closeWindows(titled: "Ghost Pepper Debug Log") }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.showDebugLog()
        let firstWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Ghost Pepper Debug Log" && $0.isVisible })
        )
        appState.showDebugLog()

        let secondWindow = try XCTUnwrap(
            NSApp.windows.first(where: { $0.title == "Ghost Pepper Debug Log" && $0.isVisible })
        )
        defer { secondWindow.close() }

        XCTAssertTrue(firstWindow === secondWindow)
    }

    func testAppStateShortcutCaptureSuspendsHotkeyMonitor() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let monitor = FakeHotkeyMonitor()
        let appState = AppState(
            hotkeyMonitor: monitor,
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        appState.setShortcutCaptureActive(true)
        appState.setShortcutCaptureActive(false)

        XCTAssertEqual(monitor.suspendedStates, [true, false])
    }

    func testRecordingOverlayHostsSwiftUIViaContentViewController() throws {
        let overlay = RecordingOverlayController()
        let existingWindowNumbers = Set(NSApp.windows.map(\.windowNumber))

        overlay.show()

        let panel = try XCTUnwrap(
            NSApp.windows
                .filter { !existingWindowNumbers.contains($0.windowNumber) }
                .compactMap { $0 as? NSPanel }
                .first
        )
        defer {
            overlay.dismiss()
            panel.close()
        }

        XCTAssertNotNil(panel.contentViewController)
    }

    func testAppStateLoadsPersistedCorrectionSettingsIntoStore() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let seededStore = CorrectionStore(defaults: defaults)
        seededStore.preferredTranscriptionsText = "Ghost Pepper\nJesse"
        seededStore.commonlyMisheardText = "just see -> Jesse"

        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )

        XCTAssertEqual(appState.correctionStore.preferredTranscriptions, ["Ghost Pepper", "Jesse"])
        XCTAssertEqual(
            appState.correctionStore.commonlyMisheard,
            [MisheardReplacement(wrong: "just see", right: "Jesse")]
        )
    }

    func testAppStateUsesPreferredTranscriptionsAsOCRCustomWords() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.correctionStore.preferredTranscriptionsText = "Ghost Pepper\nJesse"

        XCTAssertEqual(appState.ocrCustomWords, ["Ghost Pepper", "Jesse"])
    }

    func testAppStateLoadsLocalCleanupModelsWhenCleanupIsEnabled() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults
        )
        appState.cleanupEnabled = true

        XCTAssertTrue(appState.shouldLoadLocalCleanupModels)
    }

    func testAppStateRecordsCleanupDebugSnapshotOnlyWhileDebugViewerIsOpen() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let debugLogStore = makeDebugLogStore()
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            debugLogStore: debugLogStore
        )

        appState.recordCleanupDebugSnapshot(
            rawTranscription: "raw text",
            windowContext: OCRContext(windowContents: "window text"),
            cleanedOutput: "cleaned text",
            attemptedCleanup: true
        )
        XCTAssertTrue(debugLogStore.formattedText.isEmpty)

        debugLogStore.beginLiveViewing()
        appState.recordCleanupDebugSnapshot(
            rawTranscription: "raw text",
            windowContext: OCRContext(windowContents: "window text"),
            cleanedOutput: "cleaned text",
            attemptedCleanup: true
        )
        debugLogStore.endLiveViewing()

        let formattedText = debugLogStore.formattedText
        XCTAssertTrue(formattedText.contains("raw text"))
        XCTAssertTrue(formattedText.contains("windowContext=captured"))
        XCTAssertTrue(formattedText.contains("cleaned text"))
    }

    func testAppStateAppliesDeterministicCorrectionsWhenCleanupModelIsUnavailable() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        let correctionStore = CorrectionStore(defaults: defaults)
        correctionStore.commonlyMisheardText = "just see -> Jesse"
        let cleanupManager = TextCleanupManager(
            defaults: defaults,
            fastModelAvailabilityOverride: false,
            fullModelAvailabilityOverride: false
        )
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            textCleanupManager: cleanupManager,
            correctionStore: correctionStore
        )
        appState.cleanupEnabled = true

        let result = await appState.cleanedTranscription("just see approved it")

        XCTAssertEqual(result, "Jesse approved it")
    }

    func testAppStatePrepareForTerminationShutsDownCleanupBackend() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        var shutdownCount = 0
        let cleanupManager = TextCleanupManager(
            defaults: defaults,
            backendShutdownOverride: {
                shutdownCount += 1
            }
        )
        let appState = AppState(
            hotkeyMonitor: FakeHotkeyMonitor(),
            chordBindingStore: ChordBindingStore(defaults: defaults),
            cleanupSettingsDefaults: defaults,
            textCleanupManager: cleanupManager
        )

        appState.prepareForTermination()

        XCTAssertEqual(shutdownCount, 1)
    }

    private func closeWindows(titled title: String) {
        NSApp.windows
            .filter { $0.title == title }
            .forEach { window in
                window.delegate = nil
                window.orderOut(nil)
                window.close()
            }
    }

    func testCheckMicrophoneUsesInjectedClientWithoutSystemPrompt() async {
        var requestCount = 0
        PermissionChecker.current = PermissionChecker.Client(
            checkAccessibility: { false },
            promptAccessibility: {},
            microphoneStatus: { .notDetermined },
            requestMicrophoneAccess: {
                requestCount += 1
                return true
            },
            openAccessibilitySettings: {},
            openMicrophoneSettings: {}
        )

        let granted = await PermissionChecker.checkMicrophone()

        XCTAssertTrue(granted)
        XCTAssertEqual(requestCount, 1)
    }

    func testDefaultClientIsNonInteractiveDuringTests() async {
        PermissionChecker.current = PermissionChecker.defaultClient

        let granted = await PermissionChecker.checkMicrophone()

        XCTAssertFalse(granted)
        XCTAssertEqual(PermissionChecker.microphoneStatus(), .denied)
    }
}
