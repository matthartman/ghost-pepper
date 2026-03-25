import SwiftUI
import Combine
import ServiceManagement

enum AppStatus: String {
    case ready = "Ready"
    case loading = "Loading model..."
    case recording = "Recording..."
    case transcribing = "Transcribing..."
    case cleaningUp = "Cleaning up..."
    case error = "Error"
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .loading
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?
    @Published var shortcutErrorMessage: String?
    @Published var cleanupBackend: CleanupBackendOption {
        didSet {
            cleanupSettingsDefaults.set(cleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        }
    }
    @Published var frontmostWindowContextEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                frontmostWindowContextEnabled,
                forKey: Self.frontmostWindowContextEnabledDefaultsKey
            )
        }
    }
    @AppStorage("cleanupEnabled") var cleanupEnabled: Bool = true
    @AppStorage("cleanupPrompt") var cleanupPrompt: String = TextCleaner.defaultPrompt
    @Published private(set) var pushToTalkChord: KeyChord
    @Published private(set) var toggleToTalkChord: KeyChord
    @Published var postPasteLearningEnabled: Bool {
        didSet {
            cleanupSettingsDefaults.set(
                postPasteLearningEnabled,
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
            postPasteLearningCoordinator.learningEnabled = postPasteLearningEnabled
        }
    }

    let modelManager = ModelManager()
    let audioRecorder = AudioRecorder()
    let transcriber: WhisperTranscriber
    let textPaster: TextPaster
    let soundEffects = SoundEffects()
    let hotkeyMonitor: HotkeyMonitoring
    let overlay = RecordingOverlayController()
    let textCleanupManager: TextCleanupManager
    let frontmostWindowOCRService: FrontmostWindowOCRService
    let cleanupPromptBuilder: CleanupPromptBuilder
    let correctionStore: CorrectionStore
    let textCleaner: TextCleaner
    let chordBindingStore: ChordBindingStore
    let postPasteLearningCoordinator: PostPasteLearningCoordinator
    let debugLogStore: DebugLogStore
    let appRelauncher: AppRelaunching

    var isReady: Bool {
        status == .ready
    }

    private var cleanupStateObserver: Any? = nil
    private let cleanupSettingsDefaults: UserDefaults
    private let inputMonitoringChecker: () -> Bool
    private let inputMonitoringPrompter: () -> Void
    private var hotkeyMonitorStarted = false

    private static let cleanupBackendDefaultsKey = "cleanupBackend"
    private static let frontmostWindowContextEnabledDefaultsKey = "frontmostWindowContextEnabled"
    private static let postPasteLearningEnabledDefaultsKey = "postPasteLearningEnabled"

    nonisolated static let defaultPushToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),
        PhysicalKey(keyCode: 61)
    ]))!

    nonisolated static let defaultToggleToTalkChord = KeyChord(keys: Set([
        PhysicalKey(keyCode: 54),
        PhysicalKey(keyCode: 61),
        PhysicalKey(keyCode: 49)
    ]))!

    nonisolated static let defaultShortcutBindings: [ChordAction: KeyChord] = [
        .pushToTalk: defaultPushToTalkChord,
        .toggleToTalk: defaultToggleToTalkChord
    ]

    init(
        hotkeyMonitor: HotkeyMonitoring = HotkeyMonitor(bindings: AppState.defaultShortcutBindings),
        chordBindingStore: ChordBindingStore = ChordBindingStore(),
        cleanupSettingsDefaults: UserDefaults = .standard,
        textCleanupManager: TextCleanupManager? = nil,
        frontmostWindowOCRService: FrontmostWindowOCRService = FrontmostWindowOCRService(),
        cleanupPromptBuilder: CleanupPromptBuilder = CleanupPromptBuilder(),
        correctionStore: CorrectionStore? = nil,
        textPaster: TextPaster = TextPaster(),
        debugLogStore: DebugLogStore = DebugLogStore(),
        appRelauncher: AppRelaunching? = nil,
        inputMonitoringChecker: @escaping () -> Bool = PermissionChecker.checkInputMonitoring,
        inputMonitoringPrompter: @escaping () -> Void = PermissionChecker.promptInputMonitoring
    ) {
        self.hotkeyMonitor = hotkeyMonitor
        self.chordBindingStore = chordBindingStore
        self.cleanupSettingsDefaults = cleanupSettingsDefaults
        self.textPaster = textPaster
        self.debugLogStore = debugLogStore
        self.appRelauncher = appRelauncher ?? AppRelauncher()
        self.inputMonitoringChecker = inputMonitoringChecker
        self.inputMonitoringPrompter = inputMonitoringPrompter
        self.pushToTalkChord = chordBindingStore.binding(for: .pushToTalk) ?? AppState.defaultPushToTalkChord
        self.toggleToTalkChord = chordBindingStore.binding(for: .toggleToTalk) ?? AppState.defaultToggleToTalkChord
        self.textCleanupManager = textCleanupManager ?? TextCleanupManager(defaults: cleanupSettingsDefaults)
        self.frontmostWindowOCRService = frontmostWindowOCRService
        self.cleanupPromptBuilder = cleanupPromptBuilder
        self.correctionStore = correctionStore ?? CorrectionStore(defaults: cleanupSettingsDefaults)
        let storedCleanupBackend = CleanupBackendOption(
            rawValue: cleanupSettingsDefaults.string(forKey: Self.cleanupBackendDefaultsKey) ?? ""
        ) ?? .localModels
        let storedFrontmostWindowContextEnabled = cleanupSettingsDefaults.bool(
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        let storedPostPasteLearningEnabled: Bool
        if cleanupSettingsDefaults.object(forKey: Self.postPasteLearningEnabledDefaultsKey) == nil {
            storedPostPasteLearningEnabled = true
        } else {
            storedPostPasteLearningEnabled = cleanupSettingsDefaults.bool(
                forKey: Self.postPasteLearningEnabledDefaultsKey
            )
        }
        self.cleanupBackend = storedCleanupBackend
        self.frontmostWindowContextEnabled = storedFrontmostWindowContextEnabled
        self.postPasteLearningEnabled = storedPostPasteLearningEnabled
        self.transcriber = WhisperTranscriber(modelManager: modelManager)
        self.textCleaner = TextCleaner(
            cleanupManager: self.textCleanupManager,
            correctionStore: self.correctionStore
        )
        self.postPasteLearningCoordinator = PostPasteLearningCoordinator(
            correctionStore: self.correctionStore,
            learningEnabled: storedPostPasteLearningEnabled,
            revisit: { session in
                await PostPasteLearningObservationProvider.captureObservation(
                    for: session
                )
            }
        )

        // Forward cleanup manager state changes to trigger menu bar icon refresh
        cleanupStateObserver = self.textCleanupManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }

        cleanupSettingsDefaults.set(storedCleanupBackend.rawValue, forKey: Self.cleanupBackendDefaultsKey)
        cleanupSettingsDefaults.set(
            storedFrontmostWindowContextEnabled,
            forKey: Self.frontmostWindowContextEnabledDefaultsKey
        )
        cleanupSettingsDefaults.set(
            storedPostPasteLearningEnabled,
            forKey: Self.postPasteLearningEnabledDefaultsKey
        )
        persistShortcutBindingsIfNeeded()
        hotkeyMonitor.updateBindings(shortcutBindings)
        self.textPaster.onPaste = { [postPasteLearningCoordinator = self.postPasteLearningCoordinator] session in
            postPasteLearningCoordinator.handlePaste(session)
        }
        self.postPasteLearningCoordinator.onLearnedCorrection = { [weak overlay] replacement in
            Task { @MainActor in
                overlay?.show(message: .learnedCorrection(replacement))
            }
        }
        let componentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.record(category: category, message: message)
            }
        }
        let sensitiveComponentDebugLogger: (DebugLogCategory, String) -> Void = { [weak debugLogStore] category, message in
            Task { @MainActor in
                debugLogStore?.recordSensitive(category: category, message: message)
            }
        }
        if let hotkeyMonitor = hotkeyMonitor as? HotkeyMonitor {
            hotkeyMonitor.debugLogger = componentDebugLogger
        }
        self.textCleanupManager.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.debugLogger = componentDebugLogger
        self.frontmostWindowOCRService.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.textCleaner.debugLogger = componentDebugLogger
        self.textCleaner.sensitiveDebugLogger = sensitiveComponentDebugLogger
        self.postPasteLearningCoordinator.debugLogger = componentDebugLogger
        self.modelManager.debugLogger = componentDebugLogger
    }

    func initialize(skipPermissionPrompts: Bool = false) async {
        // Enable launch at login by default on first run
        if !UserDefaults.standard.bool(forKey: "hasSetLaunchAtLogin") {
            UserDefaults.standard.set(true, forKey: "hasSetLaunchAtLogin")
            try? SMAppService.mainApp.register()
        }

        if !skipPermissionPrompts {
            let hasMic = await PermissionChecker.checkMicrophone()
            if !hasMic {
                errorMessage = "Microphone access required"
                status = .error
                return
            }
        }

        // Pre-warm audio engine so first recording starts faster
        audioRecorder.prewarm()

        status = .loading
        let showOverlay = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if showOverlay {
            overlay.show(message: .modelLoading)
        }
        debugLogStore.record(category: .model, message: "App initialization started.")
        if !modelManager.isReady {
            await modelManager.loadModel()
        }
        if showOverlay {
            overlay.dismiss()
        }

        guard modelManager.isReady else {
            errorMessage = "Failed to load whisper model: \(modelManager.error?.localizedDescription ?? "unknown error")"
            status = .error
            return
        }

        await startHotkeyMonitor()

        await refreshCleanupModelState()
    }

    func relaunchApp() {
        do {
            try appRelauncher.relaunch()
        } catch {
            errorMessage = "Failed to relaunch Ghost Pepper: \(error.localizedDescription)"
        }
    }

    func startHotkeyMonitor() async {
        hotkeyMonitor.onRecordingStart = nil
        hotkeyMonitor.onRecordingStop = nil

        hotkeyMonitor.onPushToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotkeyMonitor.onPushToTalkStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.onToggleToTalkStart = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotkeyMonitor.onToggleToTalkStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }

        hotkeyMonitor.updateBindings(shortcutBindings)

        if hotkeyMonitorStarted {
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor start skipped because it is already active.")
            if status != .error {
                status = .ready
                errorMessage = nil
            }
            return
        }

        if !inputMonitoringChecker() {
            inputMonitoringPrompter()
            errorMessage = "Input Monitoring access required — grant permission then click Retry"
            status = .error
            debugLogStore.record(category: .hotkey, message: errorMessage ?? "Input Monitoring access required.")
            return
        }

        if hotkeyMonitor.start() {
            hotkeyMonitorStarted = true
            status = .ready
            errorMessage = nil
            debugLogStore.record(category: .hotkey, message: "Hotkey monitor is ready.")
        } else {
            PermissionChecker.promptAccessibility()
            errorMessage = "Accessibility access required — grant permission then click Retry"
            status = .error
            debugLogStore.record(category: .hotkey, message: errorMessage ?? "Accessibility access required.")
        }
    }

    private func startRecording() {
        // If whisper model isn't ready, show loading message
        guard status == .ready else {
            if status == .loading {
                overlay.show(message: .modelLoading)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.overlay.dismiss()
                }
            }
            return
        }

        do {
            try audioRecorder.startRecording()
            debugLogStore.record(category: .hotkey, message: "Recording started.")
            soundEffects.playStart()
            overlay.show(message: .recording)
            isRecording = true
            status = .recording
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            status = .error
        }
    }

    private func stopRecordingAndTranscribe() async {
        guard status == .recording else { return }

        debugLogStore.record(category: .hotkey, message: "Recording stopped. Starting transcription.")
        let buffer = await audioRecorder.stopRecording()
        soundEffects.playStop()
        isRecording = false
        status = .transcribing
        overlay.show(message: .transcribing)

        if let text = await transcriber.transcribe(audioBuffer: buffer) {
            var windowContext: OCRContext?
            if cleanupEnabled && canAttemptCleanup {
                status = .cleaningUp
                overlay.show(message: .cleaningUp)

                if frontmostWindowContextEnabled {
                    windowContext = await frontmostWindowOCRService.captureContext(customWords: ocrCustomWords)
                    if windowContext == nil {
                        debugLogStore.record(category: .ocr, message: "No frontmost-window OCR context was captured.")
                    }
                }
            }
            let cleanupResult = await cleanedTranscriptionResult(text, windowContext: windowContext)
            let finalText = cleanupResult.text
            let activeCleanupPrompt = cleanupResult.prompt

            recordCleanupDebugSnapshot(
                rawTranscription: text,
                basePrompt: cleanupPrompt,
                windowContext: windowContext,
                resolvedPrompt: activeCleanupPrompt,
                cleanedOutput: finalText,
                attemptedCleanup: cleanupResult.attemptedCleanup
            )

            overlay.dismiss()
            textPaster.paste(text: finalText)
        } else {
            overlay.dismiss()
            showInputCheckAlert()
            status = .ready
            debugLogStore.record(category: .model, message: "Transcription returned no text.")
            return
        }

        status = .ready
    }

    func cleanedTranscription(_ text: String) async -> String {
        let result = await cleanedTranscriptionResult(text, windowContext: nil)
        return result.text
    }

    private func showInputCheckAlert() {
        let alert = NSAlert()
        alert.messageText = "No sound coming in"
        alert.informativeText = "We didn't pick up any audio. Check that the right microphone is selected."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Dismiss")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            showSettings()
        }
    }

    private let settingsController = SettingsWindowController()
    private let promptEditorController = PromptEditorController()
    private let debugLogWindowController = DebugLogWindowController()

    func showSettings() {
        settingsController.show(appState: self)
    }

    func showPromptEditor() {
        promptEditorController.show(appState: self)
    }

    func showDebugLog() {
        debugLogWindowController.show(debugLogStore: debugLogStore)
    }

    private var shortcutBindings: [ChordAction: KeyChord] {
        [
            .pushToTalk: pushToTalkChord,
            .toggleToTalk: toggleToTalkChord
        ]
    }

    private func persistShortcutBindingsIfNeeded() {
        try? chordBindingStore.setBinding(pushToTalkChord, for: .pushToTalk)
        try? chordBindingStore.setBinding(toggleToTalkChord, for: .toggleToTalk)
    }

    private var canAttemptCleanup: Bool {
        textCleanupManager.isReady
    }

    var shouldLoadLocalCleanupModels: Bool {
        cleanupEnabled
    }

    private func cleanedTranscriptionResult(
        _ text: String,
        windowContext: OCRContext?
    ) async -> (text: String, prompt: String, attemptedCleanup: Bool) {
        guard cleanupEnabled else {
            return (text: text, prompt: cleanupPrompt, attemptedCleanup: false)
        }

        let activeCleanupPrompt: String
        if canAttemptCleanup {
            activeCleanupPrompt = cleanupPromptBuilder.buildPrompt(
                basePrompt: cleanupPrompt,
                windowContext: windowContext,
                preferredTranscriptions: correctionStore.preferredTranscriptions,
                commonlyMisheard: correctionStore.commonlyMisheard,
                includeWindowContext: frontmostWindowContextEnabled
            )
        } else {
            activeCleanupPrompt = cleanupPrompt
        }

        let cleanedText = await textCleaner.clean(text: text, prompt: activeCleanupPrompt)
        return (text: cleanedText, prompt: activeCleanupPrompt, attemptedCleanup: canAttemptCleanup)
    }

    var ocrCustomWords: [String] {
        correctionStore.preferredOCRCustomWords
    }

    func recordCleanupDebugSnapshot(
        rawTranscription: String,
        basePrompt: String,
        windowContext: OCRContext?,
        resolvedPrompt: String,
        cleanedOutput: String,
        attemptedCleanup: Bool
    ) {
        let windowContents = windowContext?.windowContents ?? "(none)"
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            Raw transcription:
            \(rawTranscription)
            """
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: "cleanupEnabled=\(cleanupEnabled) attemptedCleanup=\(attemptedCleanup) backend=\(cleanupBackend.rawValue)"
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            Base cleanup prompt:
            \(basePrompt)
            """
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            OCR window contents:
            \(windowContents)
            """
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            Resolved cleanup prompt:
            \(resolvedPrompt)
            """
        )
        debugLogStore.recordSensitive(
            category: .cleanup,
            message: """
            Final cleaned output:
            \(cleanedOutput)
            """
        )
    }

    func updateShortcut(_ chord: KeyChord, for action: ChordAction) {
        let previousPushChord = pushToTalkChord
        let previousToggleChord = toggleToTalkChord

        do {
            try chordBindingStore.setBinding(chord, for: action)
            shortcutErrorMessage = nil

            switch action {
            case .pushToTalk:
                pushToTalkChord = chord
            case .toggleToTalk:
                toggleToTalkChord = chord
            }

            hotkeyMonitor.updateBindings(shortcutBindings)
        } catch {
            pushToTalkChord = previousPushChord
            toggleToTalkChord = previousToggleChord
            shortcutErrorMessage = "That shortcut is already in use."
        }
    }

    func setShortcutCaptureActive(_ isActive: Bool) {
        hotkeyMonitor.setSuspended(isActive)
    }

    func setCleanupEnabled(_ enabled: Bool) {
        cleanupEnabled = enabled
        Task {
            await refreshCleanupModelState()
        }
    }

    func updateCleanupBackend(_ backend: CleanupBackendOption) {
        cleanupBackend = backend
        Task {
            await refreshCleanupModelState()
        }
    }

    private func refreshCleanupModelState() async {
        guard cleanupEnabled else {
            debugLogStore.record(category: .model, message: "Cleanup disabled; unloading local cleanup models.")
            textCleanupManager.unloadModel()
            objectWillChange.send()
            return
        }

        let shouldLoadLocalModels = shouldLoadLocalCleanupModels
        debugLogStore.record(
            category: .model,
            message: "Cleanup backend is \(cleanupBackend.rawValue). shouldLoadLocalModels=\(shouldLoadLocalModels)"
        )

        if shouldLoadLocalModels {
            await textCleanupManager.loadModel()
        } else {
            textCleanupManager.unloadModel()
        }

        objectWillChange.send()
    }
}
