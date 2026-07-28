import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement

extension Notification.Name {
    static let showSettingsSection = Notification.Name("showSettingsSection")
    static let meetingRecordingStopped = Notification.Name("meetingRecordingStopped")
    static let granolaImported = Notification.Name("granolaImported")
    /// Posted after `IndexBuilder.augmentGeneration` finishes stamping a
    /// freshly-written index entry. `object` is the `IndexKind`.
    static let indexEntryWritten = Notification.Name("indexEntryWritten")
}

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState, section: SettingsSection? = nil) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let section {
                NotificationCenter.default.post(name: .showSettingsSection, object: section)
            }
            return
        }

        let view = SettingsView(appState: appState, initialSection: section ?? .general)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 900, height: 680)
        window.contentViewController = NSHostingController(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
final class SettingsDictationTestController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcript: String?
    @Published private(set) var lastError: String?

    private var recorder: AudioRecorder?
    private let transcriber: SpeechTranscriber

    init(transcriber: SpeechTranscriber) {
        self.transcriber = transcriber
    }

    func start() {
        guard !isRecording else { return }
        let recorder = AudioRecorder()
        recorder.targetDeviceID = AudioDeviceManager.selectedInputDeviceID()
        recorder.prewarm()

        do {
            try recorder.startRecording()
            self.recorder = recorder
            transcript = nil
            lastError = nil
            isRecording = true
        } catch {
            lastError = "Could not start recording."
        }
    }

    func stop() {
        guard isRecording, let recorder else { return }
        isRecording = false
        isTranscribing = true
        self.recorder = nil

        Task { @MainActor in
            let buffer = await recorder.stopRecording()
            let text = await transcriber.transcribe(audioBuffer: buffer)
            self.transcript = text
            self.lastError = text == nil ? "Ghost Pepper could not transcribe that sample." : nil
            self.isTranscribing = false
        }
    }
}

// MARK: - Settings View

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case cleanup
    case models
    case modelExperiment
    case transcriptionLab
    case recognizedVoices
    case pepperChat
    case meetingTranscript

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .cleanup: "Cleanup"
        case .models: "Models"
        case .modelExperiment: "Model Experiment"
        case .transcriptionLab: "History"
        case .recognizedVoices: "Recognized Voices"
        case .pepperChat: "Context Bundler"
        case .meetingTranscript: "Meeting Transcript"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Startup behavior, shortcuts, microphone input, dictation testing, and sound feedback."
        case .cleanup: "Prompt cleanup, correction hints, OCR context, and learning behavior."
        case .models: "Speech and cleanup model downloads and runtime status."
        case .modelExperiment: "Paste prompts and context to test local model behavior."
        case .transcriptionLab: "Saved recordings, reruns, and cleanup experiments."
        case .recognizedVoices: "Reusable speaker labels and 'this is me' voice prints."
        case .pepperChat: "Capture screen context and send to Zo, Trello, or clipboard."
        case .meetingTranscript: "Auto-detect calls and transcribe meetings locally."
        }
    }

    var systemImageName: String {
        switch self {
        case .general: "gearshape"
        case .cleanup: "sparkles"
        case .models: "brain"
        case .modelExperiment: "testtube.2"
        case .transcriptionLab: "waveform.badge.magnifyingglass"
        case .recognizedVoices: "person.crop.circle.badge.checkmark"
        case .pepperChat: "bubble.right"
        case .meetingTranscript: "waveform.badge.mic"
        }
    }
}

struct RecordingSpeakerFilteringToggleState {
    let isVisible: Bool
    let isEnabled: Bool

    init(speechModel: SpeechModelDescriptor?) {
        isVisible = true
        isEnabled = speechModel?.supportsSpeakerFiltering ?? false
    }
}

private struct ModelExperimentRunResult: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var title: String
    var modelDisplayName: String
    var sourceName: String
    var systemPrompt: String
    var contextPreview: String
    var output: String
    var rawOutput: String
    var tokenCount: Int
    var duration: TimeInterval
    var rating: Int?
    var errorMessage: String?
    var createdAt: Date = Date()
}

private struct SavedModelExperimentPrompt: Identifiable, Equatable, Codable {
    var id: UUID = UUID()
    var title: String
    var systemPrompt: String
    var defaultModelKindRaw: String?
    var updatedAt: Date = Date()

    var defaultModelKind: LocalCleanupModelKind? {
        guard let defaultModelKindRaw else { return nil }
        return LocalCleanupModelKind(rawValue: defaultModelKindRaw)
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @AppStorage(AppTheme.storageKey) private var selectedThemeID = AppThemeID.current.rawValue
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    @State private var hasAccessibilityPermission = PermissionChecker.checkAccessibility()
    @State private var hasInputMonitoringPermission = PermissionChecker.checkInputMonitoring()
    @State private var permissionPollTimer: Timer?
    @State private var selectedSection: SettingsSection
    @State private var transcriptionLabPreviewSound: NSSound?
    @State private var recognizedVoices: [RecognizedVoiceProfile] = []
    @State private var recognizedVoiceSpeakerProfilesByID: [UUID: [TranscriptionLabSpeakerProfile]] = [:]
    @State private var recognizedVoicesErrorMessage: String?
    @State private var experimentModelKind: LocalCleanupModelKind = .wikiDefault
    @State private var experimentSystemPrompt = "You are a careful assistant. Use only the provided context."
    @State private var experimentContext = ""
    @State private var experimentOutput = ""
    @State private var experimentRawOutput = ""
    @State private var experimentTokenCount = 0
    @State private var experimentLoadedFileURL: URL?
    @State private var experimentRuns: [ModelExperimentRunResult] = []
    @State private var savedExperimentPrompts: [SavedModelExperimentPrompt] = []
    @State private var selectedSavedExperimentPromptID: UUID?
    @State private var experimentPromptTitle = ""
    @State private var experimentErrorMessage: String?
    @State private var isRunningExperiment = false
    @StateObject private var dictationTestController: SettingsDictationTestController
    @StateObject private var transcriptionLabController: TranscriptionLabController
    @AppStorage(MediaRecordingBehavior.storageKey) private var mediaBehaviorRaw = MediaRecordingBehavior.pause.rawValue
    @AppStorage(MediaRecordingBehavior.duckVolumePercentKey) private var duckVolumePercent = MediaRecordingBehavior.defaultDuckVolumePercent

    private static let savedExperimentPromptsDefaultsKey = "modelExperimentSavedPrompts"
    private static let experimentRunHistoryDefaultsKey = "modelExperimentRunHistory"

    private var appTheme: AppTheme {
        AppTheme.resolve(selectedThemeID)
    }

    init(appState: AppState, initialSection: SettingsSection = .general) {
        self.appState = appState
        _selectedSection = State(initialValue: initialSection)
        _dictationTestController = StateObject(
            wrappedValue: SettingsDictationTestController(transcriber: appState.transcriber)
        )
        _transcriptionLabController = StateObject(
            wrappedValue: TranscriptionLabController(
                defaultSpeechModelID: appState.speechModel,
                defaultSpeakerTaggingEnabled: appState.ignoreOtherSpeakers,
                defaultCleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind,
                loadStageTimings: {
                    try appState.loadTranscriptionLabStageTimings()
                },
                loadEntries: {
                    try appState.loadTranscriptionLabEntries()
                },
                audioURLForEntry: { entry in
                    appState.transcriptionLabAudioURL(for: entry)
                },
                runTranscription: { entry, speechModelID, speakerTaggingEnabled in
                    try await appState.rerunTranscriptionLabTranscription(
                        entry,
                        speechModelID: speechModelID,
                        speakerTaggingEnabled: speakerTaggingEnabled
                    )
                },
                runCleanup: { entry, rawTranscription, cleanupModelKind, prompt, includeWindowContext in
                    try await appState.rerunTranscriptionLabCleanup(
                        entry,
                        rawTranscription: rawTranscription,
                        cleanupModelKind: cleanupModelKind,
                        prompt: prompt,
                        includeWindowContext: includeWindowContext
                    )
                },
                loadSpeakerProfiles: { entryID in
                    try appState.loadTranscriptionLabSpeakerProfiles(for: entryID)
                },
                saveSpeakerProfile: { profile in
                    try appState.upsertTranscriptionLabSpeakerProfile(profile)
                },
                loadRecognizedVoices: {
                    try appState.loadRecognizedVoiceProfiles()
                },
                updateGlobalVoiceProfile: { localProfile in
                    try appState.updateGlobalVoiceProfile(from: localProfile)
                },
                syncSelectedSpeechModelID: { speechModelID in
                    appState.speechModel = speechModelID
                    Task {
                        await appState.loadSpeechModel(name: speechModelID)
                    }
                },
                syncSpeakerTaggingEnabled: { speakerTaggingEnabled in
                    appState.ignoreOtherSpeakers = speakerTaggingEnabled
                },
                syncSelectedCleanupModelKind: { cleanupModelKind in
                    appState.textCleanupManager.selectedCleanupModelKind = cleanupModelKind
                    Task {
                        await appState.textCleanupManager.loadModel(kind: cleanupModelKind)
                    }
                }
            )
        )
    }

    private var modelRows: [RuntimeModelRow] {
        RuntimeModelInventory.rows(
            selectedSpeechModelName: appState.speechModel,
            activeSpeechModelName: appState.modelManager.modelName,
            speechModelState: appState.modelManager.state,
            speechDownloadProgress: appState.modelManager.downloadProgress,
            cachedSpeechModelNames: appState.modelManager.cachedModelNames,
            cleanupState: appState.textCleanupManager.state,
            selectedCleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind,
            selectedWikiModelKind: appState.selectedWikiModelKind,
            cachedCleanupKinds: appState.textCleanupManager.cachedModelKinds
        )
    }


    private var speakerFilteringToggleState: RecordingSpeakerFilteringToggleState {
        RecordingSpeakerFilteringToggleState(
            speechModel: SpeechModelCatalog.model(named: appState.speechModel)
        )
    }


    var body: some View {
        HSplitView {
            ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: section.systemImageName)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .font(.body.weight(.medium))
                                Text(section.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Make the full row (icon + text + surrounding padding + trailing
                        // whitespace) hit-testable. Without this, SwiftUI hit-tests a plain
                        // Button against the opaque pixels of its label — so clicks landed only
                        // on the visible text/icon, not the empty space in the row. (Fixes #74.)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: appTheme.id == .windows95 ? 0 : 12, style: .continuous)
                                .fill(selectedSection == section ? appTheme.selectedFill : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: appTheme.id == .windows95 ? 0 : 12, style: .continuous)
                                .stroke(
                                    selectedSection == section
                                        ? appTheme.separator
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }
            }
            .frame(minWidth: 250, idealWidth: 270, maxWidth: 270, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .background(appTheme.controlBackground)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(appTheme.separator)
                    .frame(width: 1)
            }

            ScrollView {
                detailContent
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(appTheme.windowBackground)
        }
        .tint(appTheme.accent)
        .frame(minWidth: 900, minHeight: 680)
        .onAppear {
            refreshInputDevices()
            refreshScreenRecordingPermission()
            refreshRequiredPermissions()
            startPermissionPollingIfNeeded()
            syncTranscriptionLabRerunDefaults()
            transcriptionLabController.reloadEntries()
            reloadRecognizedVoices()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshInputDevices()
            refreshScreenRecordingPermission()
            refreshRequiredPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsSection)) { note in
            if let section = note.object as? SettingsSection {
                selectedSection = section
            }
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .transcriptionLab {
                syncTranscriptionLabRerunDefaults()
                transcriptionLabController.reloadEntries()
            } else if newSection == .recognizedVoices {
                reloadRecognizedVoices()
            }
        }
        .onChange(of: appState.speechModel) { _, _ in
            syncTranscriptionLabRerunDefaults()
        }
        .onChange(of: appState.textCleanupManager.selectedCleanupModelKind) { _, _ in
            syncTranscriptionLabRerunDefaults()
        }
        .onDisappear {
            if dictationTestController.isRecording {
                dictationTestController.stop()
            }
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    private func refreshScreenRecordingPermission() {
        hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    }

    private func refreshInputDevices() {
        let devices = AudioDeviceManager.listInputDevices()
        inputDevices = devices
        selectedDeviceID = AudioDeviceManager.preferredInputDeviceID(
            inputDevices: { devices }
        ) ?? 0
    }

    private func downloadModel(_ row: RuntimeModelRow) {
        if row.id.hasPrefix("cleanup-") {
            if let kind = TextCleanupManager.cleanupModels.first(where: { "cleanup-\($0.fileName)" == row.id })?.kind {
                Task { await appState.textCleanupManager.loadModel(kind: kind) }
            }
        } else {
            // Select and load the requested model (triggers download if not cached)
            appState.speechModel = row.id
            Task { await appState.loadSpeechModel(name: row.id) }
        }
    }

    private func offloadModel(_ row: RuntimeModelRow) {
        if row.id.hasPrefix("cleanup-") {
            // Cleanup model
            if let kind = TextCleanupManager.cleanupModels.first(where: { "cleanup-\($0.fileName)" == row.id })?.kind {
                appState.textCleanupManager.deleteCachedModel(kind: kind)
            }
        } else {
            // Speech model
            if let model = SpeechModelCatalog.model(named: row.id) {
                appState.modelManager.deleteCachedModel(model)
            }
        }
    }

    private func refreshRequiredPermissions() {
        hasAccessibilityPermission = PermissionChecker.checkAccessibility()
        hasInputMonitoringPermission = PermissionChecker.checkInputMonitoring()
        if hasAccessibilityPermission && hasInputMonitoringPermission {
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        }
    }

    private func startPermissionPollingIfNeeded() {
        guard !hasAccessibilityPermission || !hasInputMonitoringPermission else { return }
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            refreshRequiredPermissions()
        }
    }

    private func syncTranscriptionLabRerunDefaults() {
        transcriptionLabController.applyCurrentRerunDefaults(
            speechModelID: appState.speechModel,
            speakerTaggingEnabled: appState.ignoreOtherSpeakers,
            cleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind
        )
    }

    private func reloadRecognizedVoices() {
        do {
            recognizedVoices = try appState.loadRecognizedVoiceProfiles()
            recognizedVoiceSpeakerProfilesByID = Dictionary(
                grouping: try appState.loadAllTranscriptionLabSpeakerProfiles().filter { $0.recognizedVoiceID != nil },
                by: { $0.recognizedVoiceID! }
            )
            recognizedVoicesErrorMessage = nil
        } catch {
            recognizedVoices = []
            recognizedVoiceSpeakerProfilesByID = [:]
            recognizedVoicesErrorMessage = "Could not load recognized voices."
        }
    }

    private func upsertRecognizedVoiceProfile(_ profile: RecognizedVoiceProfile) {
        do {
            try appState.upsertRecognizedVoiceProfile(profile)
            replaceRecognizedVoiceProfile(profile)
            recognizedVoicesErrorMessage = nil
        } catch {
            recognizedVoicesErrorMessage = "Could not save that recognized voice."
        }
    }

    private func replaceRecognizedVoiceProfile(_ updatedProfile: RecognizedVoiceProfile) {
        guard let existingIndex = recognizedVoices.firstIndex(where: { $0.id == updatedProfile.id }) else {
            recognizedVoices.append(updatedProfile)
            return
        }

        recognizedVoices[existingIndex] = updatedProfile
    }

    private func unlinkSpeakerProfileFromRecognizedVoice(_ profile: TranscriptionLabSpeakerProfile) {
        var updatedProfile = profile
        updatedProfile.recognizedVoiceID = nil

        do {
            try appState.upsertTranscriptionLabSpeakerProfile(updatedProfile)
            reloadRecognizedVoices()
            transcriptionLabController.reloadEntries()
        } catch {
            recognizedVoicesErrorMessage = "Could not unlink that speaker print."
        }
    }

    private func playTranscriptionLabAudio(for entry: TranscriptionLabEntry) {
        let sound = NSSound(contentsOf: transcriptionLabController.audioURL(for: entry), byReference: false)
        transcriptionLabPreviewSound?.stop()
        transcriptionLabPreviewSound = sound
        transcriptionLabPreviewSound?.play()
    }

    private func copyTranscriptionLabTranscript(for entry: TranscriptionLabEntry) {
        let transcript = preferredTranscriptToCopy(for: entry)
        guard !transcript.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    private func preferredTranscriptToCopy(for entry: TranscriptionLabEntry) -> String {
        if let corrected = entry.correctedTranscription, !corrected.isEmpty {
            return corrected
        }

        return entry.rawTranscription ?? ""
    }

    private func experimentModelStatusText(_ descriptor: CleanupModelDescriptor) -> String {
        let downloaded = appState.textCleanupManager.cachedModelKinds.contains(descriptor.kind)
        if !downloaded {
            return "This model is not downloaded yet. Download it from Settings > Models first."
        }
        if descriptor.runtime != .gguf {
            return "This model is downloaded/selectable, but MLX inference is not wired yet. Choose a GGUF model for now."
        }
        return "Downloaded and runnable locally."
    }

    private func experimentPromptBudgetText(_ descriptor: CleanupModelDescriptor) -> String {
        let prompt = LocalStructuredLLM.buildPrompt(system: experimentSystemPrompt, user: experimentContext)
        let estimatedTokens = max(1, Int(ceil(Double(prompt.count) / 4.0)))
        let maxTokens = Int(descriptor.maxTokenCount)
        let outputRoom = max(0, maxTokens - estimatedTokens)
        return "Estimated prompt: ~\(estimatedTokens) tokens of \(maxTokens) · output room: ~\(outputRoom) tokens"
    }

    private func loadSavedExperimentPrompts() {
        guard let data = UserDefaults.standard.data(forKey: Self.savedExperimentPromptsDefaultsKey),
              let prompts = try? JSONDecoder().decode([SavedModelExperimentPrompt].self, from: data) else {
            savedExperimentPrompts = []
            return
        }
        savedExperimentPrompts = prompts.sorted { $0.updatedAt > $1.updatedAt }
        persistSavedExperimentPrompts()
    }

    private func persistSavedExperimentPrompts() {
        guard let data = try? JSONEncoder().encode(savedExperimentPrompts) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedExperimentPromptsDefaultsKey)
    }

    private func loadExperimentRunHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.experimentRunHistoryDefaultsKey),
              let runs = try? JSONDecoder().decode([ModelExperimentRunResult].self, from: data) else {
            experimentRuns = []
            return
        }
        experimentRuns = runs.sorted { $0.createdAt > $1.createdAt }
    }

    private func persistExperimentRunHistory() {
        let cappedRuns = Array(experimentRuns.prefix(100))
        guard let data = try? JSONEncoder().encode(cappedRuns) else { return }
        UserDefaults.standard.set(data, forKey: Self.experimentRunHistoryDefaultsKey)
    }

    private func insertExperimentRun(_ run: ModelExperimentRunResult) {
        experimentRuns.insert(run, at: 0)
        experimentRuns = Array(experimentRuns.prefix(100))
        persistExperimentRunHistory()
    }

    private func rateExperimentRun(id: UUID, rating: Int?) {
        guard let index = experimentRuns.firstIndex(where: { $0.id == id }) else { return }
        experimentRuns[index].rating = rating
        persistExperimentRunHistory()
    }

    private func saveCurrentExperimentPrompt() {
        let title = experimentPromptTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            experimentErrorMessage = "Give this function a title before saving."
            return
        }
        let existingID = selectedSavedExperimentPromptID
        let prompt = SavedModelExperimentPrompt(
            id: existingID ?? UUID(),
            title: title,
            systemPrompt: experimentSystemPrompt,
            defaultModelKindRaw: experimentModelKind.rawValue,
            updatedAt: Date()
        )
        if let existingID,
           let index = savedExperimentPrompts.firstIndex(where: { $0.id == existingID }) {
            savedExperimentPrompts[index] = prompt
        } else if let index = savedExperimentPrompts.firstIndex(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            savedExperimentPrompts[index] = prompt
            selectedSavedExperimentPromptID = prompt.id
        } else {
            savedExperimentPrompts.insert(prompt, at: 0)
            selectedSavedExperimentPromptID = prompt.id
        }
        savedExperimentPrompts.sort { $0.updatedAt > $1.updatedAt }
        persistSavedExperimentPrompts()
        experimentErrorMessage = nil
    }

    private func loadSelectedExperimentPrompt() {
        guard let selectedSavedExperimentPromptID,
              let prompt = savedExperimentPrompts.first(where: { $0.id == selectedSavedExperimentPromptID }) else {
            return
        }
        experimentPromptTitle = prompt.title
        experimentSystemPrompt = prompt.systemPrompt
        if let defaultModelKind = prompt.defaultModelKind,
           downloadedRunnableExperimentModels.contains(where: { $0.kind == defaultModelKind }) {
            experimentModelKind = defaultModelKind
            experimentErrorMessage = nil
        } else if let defaultModelKind = prompt.defaultModelKind {
            experimentErrorMessage = "Saved function default model is not downloaded or wired up: \(defaultModelKind.rawValue)"
        }
        experimentLoadedFileURL = nil
        if prompt.defaultModelKind == nil {
            experimentErrorMessage = nil
        }
    }

    private func deleteSelectedExperimentPrompt() {
        guard let selectedSavedExperimentPromptID else { return }
        savedExperimentPrompts.removeAll { $0.id == selectedSavedExperimentPromptID }
        self.selectedSavedExperimentPromptID = savedExperimentPrompts.first?.id
        if let first = savedExperimentPrompts.first {
            experimentPromptTitle = first.title
        } else {
            experimentPromptTitle = ""
        }
        persistSavedExperimentPrompts()
    }

    private func functionPickerTitle(_ prompt: SavedModelExperimentPrompt) -> String {
        guard let raw = prompt.defaultModelKindRaw else { return prompt.title }
        let modelName = TextCleanupManager.cleanupModels.first(where: { $0.kind.rawValue == raw })?.displayName ?? raw
        return "\(prompt.title) · \(modelName)"
    }

    private var downloadedRunnableExperimentModels: [CleanupModelDescriptor] {
        TextCleanupManager.wikiGenerationModels.filter { descriptor in
            descriptor.runtime == .gguf && appState.textCleanupManager.cachedModelKinds.contains(descriptor.kind)
        }
    }

    private func runModelExperiment() {
        guard let descriptor = TextCleanupManager.cleanupModels.first(where: { $0.kind == experimentModelKind }) else {
            experimentErrorMessage = "Unknown model."
            return
        }
        runModelExperiment(models: [descriptor])
    }

    private func runAllDownloadedModelExperiments() {
        let models = downloadedRunnableExperimentModels
        guard !models.isEmpty else {
            experimentErrorMessage = "Download a runnable GGUF model before running the lab."
            return
        }
        runModelExperiment(models: models)
    }

    private func runModelExperiment(models: [CleanupModelDescriptor]) {
        guard !isRunningExperiment else { return }
        let runnableModels = models.filter { descriptor in
            appState.textCleanupManager.cachedModelKinds.contains(descriptor.kind) && descriptor.runtime == .gguf
        }
        guard runnableModels.count == models.count else {
            if let blocked = models.first(where: { !appState.textCleanupManager.cachedModelKinds.contains($0.kind) }) {
                experimentErrorMessage = "Download \(blocked.displayName) before running it."
            } else if let blocked = models.first(where: { $0.runtime != .gguf }) {
                experimentErrorMessage = "\(blocked.displayName) uses MLX. This experiment runner can list it, but MLX inference is not wired yet."
            }
            return
        }

        let system = experimentSystemPrompt
        let context = experimentContext
        let sourceName = experimentLoadedFileURL?.lastPathComponent ?? "Pasted context"
        isRunningExperiment = true
        experimentErrorMessage = nil
        experimentOutput = ""
        experimentRawOutput = ""
        experimentTokenCount = 0

        Task { @MainActor in
            for descriptor in runnableModels {
                do {
                    let result = try await runSingleModelExperiment(
                        descriptor: descriptor,
                        system: system,
                        context: context,
                        sourceName: sourceName
                    )
                    insertExperimentRun(result)
                } catch {
                    let result = ModelExperimentRunResult(
                        title: descriptor.displayName,
                        modelDisplayName: descriptor.displayName,
                        sourceName: sourceName,
                        systemPrompt: system,
                        contextPreview: Self.previewText(context),
                        output: "",
                        rawOutput: "",
                        tokenCount: 0,
                        duration: 0,
                        rating: nil,
                        errorMessage: error.localizedDescription
                    )
                    insertExperimentRun(result)
                    experimentErrorMessage = error.localizedDescription
                }
            }
            isRunningExperiment = false
        }
    }

    private func runSingleModelExperiment(
        descriptor: CleanupModelDescriptor,
        system: String,
        context: String,
        sourceName: String
    ) async throws -> ModelExperimentRunResult {
        let startedAt = Date()
        let prompt = LocalStructuredLLM.buildPrompt(system: system, user: context)
        let stream = try await appState.textCleanupManager.streamCompletion(
            prompt: prompt,
            modelKind: descriptor.kind,
            thinkingMode: .none
        )
        var output = ""
        var tokenCount = 0
        experimentOutput = ""
        experimentRawOutput = ""
        experimentTokenCount = 0
        for await token in stream {
            if Task.isCancelled { break }
            output += token
            tokenCount += 1
            experimentRawOutput = output
            experimentTokenCount = tokenCount
            let cleaned = LocalStructuredLLM.stripThinking(output)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            experimentOutput = cleaned.isEmpty ? output : cleaned
        }
        experimentRawOutput = output
        experimentTokenCount = tokenCount
        let cleaned = LocalStructuredLLM.stripThinking(output)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        experimentOutput = cleaned.isEmpty ? output : cleaned
        let duration = Date().timeIntervalSince(startedAt)
        let emptyOutputMessage: String?
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let estimatedTokens = max(1, Int(ceil(Double(prompt.count) / 4.0)))
            emptyOutputMessage = "The model returned no tokens. Estimated prompt size is ~\(estimatedTokens) tokens."
            experimentErrorMessage = emptyOutputMessage
        } else {
            emptyOutputMessage = nil
        }
        return ModelExperimentRunResult(
            title: "\(descriptor.displayName) · \(sourceName)",
            modelDisplayName: descriptor.displayName,
            sourceName: sourceName,
            systemPrompt: system,
            contextPreview: Self.previewText(context),
            output: experimentOutput,
            rawOutput: output,
            tokenCount: tokenCount,
            duration: duration,
            rating: nil,
            errorMessage: emptyOutputMessage
        )
    }

    private func loadExperimentContextFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a transcript, markdown file, or text file to use as Model Lab context."
        panel.prompt = "Use File"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                experimentContext = try String(contentsOf: url, encoding: .utf8)
                experimentLoadedFileURL = url
                experimentErrorMessage = nil
            } catch {
                experimentErrorMessage = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private static func previewText(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 700 else { return cleaned }
        return String(cleaned.prefix(700)) + "\n..."
    }


    private func formattedStageDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((duration * 1000).rounded())) ms"
        }

        return String(format: "%.2f s", duration)
    }

    private func formattedOriginalStageDuration(_ duration: TimeInterval?) -> String {
        guard let duration else {
            return "Not recorded"
        }

        return formattedStageDuration(duration)
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if !(selectedSection == .transcriptionLab && transcriptionLabController.selectedEntry != nil) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedSection.title)
                        .font(.system(size: 28, weight: .semibold))
                    if selectedSection != .transcriptionLab {
                        Text(selectedSection.subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            switch selectedSection {
            case .general:
                generalSection
            case .cleanup:
                cleanupSection
            case .models:
                modelsSection
            case .modelExperiment:
                modelExperimentSection
            case .transcriptionLab:
                transcriptionLabSection
            case .recognizedVoices:
                recognizedVoicesSection
            case .pepperChat:
                pepperChatSection
            case .meetingTranscript:
                meetingTranscriptSection
            }

            Spacer(minLength: 0)
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !hasAccessibilityPermission || !hasInputMonitoringPermission {
                SettingsCard("Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        PermissionStatusRow(
                            title: "Accessibility",
                            isGranted: hasAccessibilityPermission,
                            action: {
                                PermissionChecker.promptAccessibility()
                                PermissionChecker.openAccessibilitySettings()
                                startPermissionPollingIfNeeded()
                            }
                        )
                        PermissionStatusRow(
                            title: "Input Monitoring",
                            isGranted: hasInputMonitoringPermission,
                            action: {
                                PermissionChecker.promptInputMonitoring()
                                PermissionChecker.openInputMonitoringSettings()
                                startPermissionPollingIfNeeded()
                            }
                        )

                        RunningAppDragTile()

                        Text("Both permissions are required for hotkeys and pasting to work reliably. Open each permission list, then drag the app shown above into it. Quit and reopen Ghost Pepper after granting access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("Shortcuts") {
                VStack(alignment: .leading, spacing: 16) {
                    ShortcutRecorderView(
                        title: "Hold to Record",
                        chord: appState.pushToTalkChord,
                        onRecordingStateChange: appState.setShortcutCaptureActive
                    ) { chord in
                        appState.updateShortcut(chord, for: .pushToTalk)
                    }

                    ShortcutRecorderView(
                        title: "Toggle Recording",
                        chord: appState.toggleToTalkChord,
                        onRecordingStateChange: appState.setShortcutCaptureActive
                    ) { chord in
                        appState.updateShortcut(chord, for: .toggleToTalk)
                    }

                    if let shortcutErrorMessage = appState.shortcutErrorMessage {
                        Text(shortcutErrorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text("Push to talk records while the hold chord stays down. Toggle recording starts and stops when you press the full toggle chord.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("Input") {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsField("Microphone") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .center, spacing: 12) {
                                if inputDevices.isEmpty {
                                    Text("No microphones detected")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Picker("Microphone", selection: $selectedDeviceID) {
                                        ForEach(inputDevices) { device in
                                            Text(device.name).tag(device.id)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: 320, alignment: .leading)
                                    .onChange(of: selectedDeviceID) { _, newValue in
                                        AudioDeviceManager.setSelectedInputDevice(newValue)
                                        appState.resetAudioEngine()
                                    }
                                }

                                Button("Detect available microphones") {
                                    refreshInputDevices()
                                }
                                .buttonStyle(.bordered)
                            }

                            Text("If you plugged in a microphone after opening Settings, click Detect available microphones to rescan.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Toggle(
                        "Play sounds",
                        isOn: Binding(
                            get: { appState.playSounds },
                            set: { appState.playSounds = $0 }
                        )
                    )

                    SettingsField("While recording") {
                        Picker("While recording", selection: $mediaBehaviorRaw) {
                            ForEach(MediaRecordingBehavior.allCases) { behavior in
                                Text(behavior.displayName).tag(behavior.rawValue)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    if mediaBehaviorRaw == MediaRecordingBehavior.duck.rawValue {
                        SettingsField("Duck to") {
                            HStack(spacing: 12) {
                                Slider(value: $duckVolumePercent, in: 10...90, step: 5)
                                    .frame(maxWidth: 240)
                                Text("\(Int(duckVolumePercent))%")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }

                    Text("Lower the volume keeps background audio playing quietly while you record and restores it when you stop. Pause playback stops it instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if speakerFilteringToggleState.isVisible {
                        Toggle(
                            "Ignore other speakers",
                            isOn: Binding(
                                get: { appState.ignoreOtherSpeakers },
                                set: { appState.ignoreOtherSpeakers = $0 }
                            )
                        )
                        .disabled(!speakerFilteringToggleState.isEnabled)
                    }
                }
            }

            SettingsCard("Automatic Pasting") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Ghost Pepper normally verifies that an editable field is focused before pressing ⌘V. Apps listed here are allowed even when their text editor cannot be detected reliably.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if appState.alwaysAllowedPasteApplications.isEmpty {
                        Text("No apps are always allowed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.alwaysAllowedPasteApplications) { application in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: NSWorkspace.shared.urlForApplication(withBundleIdentifier: application.bundleIdentifier)?.path ?? ""))
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(application.displayName)
                                    Text(application.bundleIdentifier)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Remove") {
                                    appState.removeAlwaysAllowedPasteApplication(
                                        bundleIdentifier: application.bundleIdentifier
                                    )
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            SettingsCard("Test dictation") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Record a short sample with your current microphone and speech model without leaving Settings.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Button(dictationTestController.isRecording ? "Stop test dictation" : "Start test dictation") {
                            if dictationTestController.isRecording {
                                dictationTestController.stop()
                            } else {
                                dictationTestController.start()
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if dictationTestController.isRecording {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 10, height: 10)
                                Text("Recording…")
                                    .foregroundStyle(.secondary)
                            }
                        } else if dictationTestController.isTranscribing {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Transcribing…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let transcript = dictationTestController.transcript {
                        Text(transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                    } else if let lastError = dictationTestController.lastError {
                        Text(lastError)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            SettingsCard("Appearance") {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Theme", selection: $selectedThemeID) {
                        ForEach(AppThemeID.allCases) { themeID in
                            Text(themeID.displayName).tag(themeID.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420, alignment: .leading)

                    HStack(spacing: 12) {
                        ForEach(AppThemeID.allCases) { themeID in
                            ThemeSwatch(
                                theme: AppTheme(id: themeID),
                                title: themeID.displayName,
                                subtitle: themeID.subtitle,
                                isSelected: selectedThemeID == themeID.rawValue
                            ) {
                                selectedThemeID = themeID.rawValue
                            }
                        }
                    }
                }
            }

            SettingsCard("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !enabled
                        }
                    }
            }
        }
    }

    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Cleanup") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(
                        "Enable cleanup",
                        isOn: Binding(
                            get: { appState.cleanupEnabled },
                            set: { appState.setCleanupEnabled($0) }
                        )
                    )

                    if appState.cleanupEnabled {
                        if appState.textCleanupManager.state == .error {
                            Text(appState.textCleanupManager.errorMessage ?? "Error loading model")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("When enabled, Ghost Pepper runs local cleanup with the selected cleanup model from the Models section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard("Cleanup prompt") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ghost Pepper uses this prompt before adding OCR context and correction hints.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    BorderedTextEditor(
                        text: $appState.cleanupPrompt,
                        minimumHeight: 140,
                        maximumHeight: 260,
                        monospaced: false
                    )

                    HStack {
                        Spacer()

                        Button("Reset to Default") {
                            appState.cleanupPrompt = TextCleaner.defaultPrompt
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsCard("Correction hints") {
                VStack(alignment: .leading, spacing: 20) {
                    CorrectionsEditor(
                        title: "Preferred transcriptions",
                        text: Binding(
                            get: { appState.correctionStore.preferredTranscriptionsText },
                            set: { appState.correctionStore.preferredTranscriptionsText = $0 }
                        ),
                        prompt: "One preferred word or phrase per line"
                    )

                    Divider()

                    CorrectionsEditor(
                        title: "Commonly misheard",
                        text: Binding(
                            get: { appState.correctionStore.commonlyMisheardText },
                            set: { appState.correctionStore.commonlyMisheardText = $0 }
                        ),
                        prompt: "One likely phrase pair per line using probably wrong -> probably right"
                    )

                    Text("Correction hints are added to the cleanup prompt; they are not applied as regexes or deterministic substitutions. Preferred transcriptions are also forwarded into OCR custom words.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard("Context") {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(
                        "Use frontmost window OCR context",
                        isOn: Binding(
                            get: { appState.frontmostWindowContextEnabled },
                            set: { appState.frontmostWindowContextEnabled = $0 }
                        )
                    )

                    if appState.frontmostWindowContextEnabled && !hasScreenRecordingPermission {
                        ScreenRecordingRecoveryView {
                            _ = PermissionChecker.requestScreenRecordingPermission()
                            PermissionChecker.openScreenRecordingSettings()
                            refreshScreenRecordingPermission()
                        }
                    }

                    Toggle(
                        "Learn from manual corrections after paste",
                        isOn: Binding(
                            get: { appState.postPasteLearningEnabled },
                            set: { appState.postPasteLearningEnabled = $0 }
                        )
                    )

                    if appState.postPasteLearningEnabled && !hasScreenRecordingPermission {
                        ScreenRecordingRecoveryView {
                            _ = PermissionChecker.requestScreenRecordingPermission()
                            PermissionChecker.openScreenRecordingSettings()
                            refreshScreenRecordingPermission()
                        }
                    }

                    Text("Ghost Pepper uses high-quality OCR on the frontmost window and adds the result to the cleanup prompt. When learning is enabled, Ghost Pepper does a high-quality OCR check about 15 seconds after paste and only keeps narrow, high-confidence corrections.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Speech model") {
                SettingsField("Active speech model") {
                    Picker("Speech Model", selection: $appState.speechModel) {
                        ForEach(ModelManager.availableModels) { model in
                            Text(model.pickerLabel).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: appState.speechModel) { _, newModel in
                        Task {
                            await appState.loadSpeechModel(name: newModel)
                        }
                    }
                }

                Text("Ghost Pepper uses this model for speech recognition everywhere in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SettingsField("Language") {
                    Picker("Language", selection: $appState.preferredLanguage) {
                        Text(
                            SpeechModelCatalog.model(named: appState.speechModel)?.automaticLanguageLabel
                                ?? "Auto-detect"
                        ).tag("auto")
                        Text("English").tag("en")
                        Text("Spanish").tag("es")
                        Text("French").tag("fr")
                        Text("German").tag("de")
                        Text("Portuguese").tag("pt")
                        Text("Italian").tag("it")
                        Text("Dutch").tag("nl")
                        Text("Chinese").tag("zh")
                        Text("Japanese").tag("ja")
                        Text("Korean").tag("ko")
                        Text("Russian").tag("ru")
                        Text("Arabic").tag("ar")
                        Text("Hindi").tag("hi")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                    .onChange(of: appState.preferredLanguage) { _, _ in
                        Task {
                            await appState.reloadSpeechAnalyzerForPreferredLanguageIfNeeded()
                        }
                    }
                }

                if appState.preferredLanguage != "auto" && appState.preferredLanguage != "en" && SpeechModelCatalog.model(named: appState.speechModel)?.isEnglishOnly == true {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("You've selected a non-English language but are using an English-only model. Switch to **Multilingual** or **Parakeet v3** above for best results.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard("Cleanup model") {
                SettingsField("Active cleanup model") {
                    Picker(
                        "Cleanup model",
                        selection: Binding(
                            get: { appState.textCleanupManager.selectedCleanupModelKind },
                            set: { appState.textCleanupManager.selectedCleanupModelKind = $0 }
                        )
                    ) {
                        ForEach(TextCleanupManager.cleanupGenerationModels, id: \.kind) { model in
                            Text(model.displayName).tag(model.kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360, alignment: .leading)
                    .onChange(of: appState.textCleanupManager.selectedCleanupModelKind) { _, _ in
                        Task {
                            await appState.textCleanupManager.loadModel()
                        }
                    }
                }

                Text("Recommended cleanup models are marked Very fast, Fast, and Full.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard("2nd Brain generation model") {
                SettingsField("Default 2nd Brain model") {
                    Picker(
                        "2nd Brain model",
                        selection: Binding(
                            get: { appState.selectedWikiModelKind },
                            set: { appState.selectedWikiModelKind = $0 }
                        )
                    ) {
                        ForEach(TextCleanupManager.wikiGenerationModels, id: \.kind) { model in
                            Text(model.displayName).tag(model.kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 420, alignment: .leading)
                }

                Text("2nd Brain generation can use a larger downloaded local model than live dictation cleanup. Gemma 4 12B MLX is the recommended target, but MLX inference support is still being wired in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard("Runtime models") {
                VStack(alignment: .leading, spacing: 16) {
                    ModelInventoryCard(rows: modelRows, onDelete: offloadModel, onDownload: downloadModel)

                    if let activeDownloadText = RuntimeModelInventory.activeDownloadText(rows: modelRows) {
                        Text(activeDownloadText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var modelExperimentSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Run a local model") {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsField("Local function") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                TextField("Function title", text: $experimentPromptTitle)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 340)
                                    .disabled(isRunningExperiment)

                                Button {
                                    saveCurrentExperimentPrompt()
                                } label: {
                                    Label("Save", systemImage: "tray.and.arrow.down")
                                }
                                .disabled(isRunningExperiment)
                            }

                            HStack(spacing: 10) {
                                Picker(
                                    "Local functions",
                                    selection: Binding(
                                        get: { selectedSavedExperimentPromptID },
                                        set: { selectedSavedExperimentPromptID = $0 }
                                    )
                                ) {
                                    Text("Choose local function").tag(Optional<UUID>.none)
                                    ForEach(savedExperimentPrompts) { prompt in
                                        Text(functionPickerTitle(prompt)).tag(Optional(prompt.id))
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 340)
                                .disabled(isRunningExperiment || savedExperimentPrompts.isEmpty)

                                Button {
                                    loadSelectedExperimentPrompt()
                                } label: {
                                    Label("Load", systemImage: "arrow.down.doc")
                                }
                                .disabled(isRunningExperiment || selectedSavedExperimentPromptID == nil)

                                Button {
                                    deleteSelectedExperimentPrompt()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(isRunningExperiment || selectedSavedExperimentPromptID == nil)
                            }
                        }
                    }

                    SettingsField("Input file") {
                        HStack(spacing: 10) {
                            Button {
                                loadExperimentContextFromFile()
                            } label: {
                                Label("Choose File", systemImage: "doc.badge.plus")
                            }
                            .disabled(isRunningExperiment)

                            Text(experimentLoadedFileURL?.path ?? "No file selected; using pasted context.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    SettingsField("Model") {
                        Picker(
                            "Model",
                            selection: $experimentModelKind
                        ) {
                            ForEach(downloadedRunnableExperimentModels, id: \.kind) { model in
                                Text(model.displayName).tag(model.kind)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 460, alignment: .leading)
                        .disabled(isRunningExperiment || downloadedRunnableExperimentModels.isEmpty)
                    }

                    if downloadedRunnableExperimentModels.isEmpty {
                        Text("No downloaded wired-up GGUF models are available. Download one from Settings > Models first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let descriptor = downloadedRunnableExperimentModels.first(where: { $0.kind == experimentModelKind }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(experimentModelStatusText(descriptor))
                            Text(experimentPromptBudgetText(descriptor))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("System prompt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        BorderedTextEditor(
                            text: $experimentSystemPrompt,
                            minimumHeight: 90,
                            maximumHeight: 140,
                            monospaced: false
                        )
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context / user prompt")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        BorderedTextEditor(
                            text: $experimentContext,
                            minimumHeight: 180,
                            maximumHeight: 320,
                            monospaced: false
                        )
                    }

                    HStack(spacing: 10) {
                        Button(isRunningExperiment ? "Running..." : "Run") {
                            runModelExperiment()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isRunningExperiment ||
                            experimentContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            !downloadedRunnableExperimentModels.contains(where: { $0.kind == experimentModelKind })
                        )

                        Button("Run All Downloaded") {
                            runAllDownloadedModelExperiments()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRunningExperiment || experimentContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || downloadedRunnableExperimentModels.isEmpty)

                        Button("Clear Output") {
                            experimentOutput = ""
                            experimentRawOutput = ""
                            experimentTokenCount = 0
                            experimentErrorMessage = nil
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRunningExperiment || (experimentOutput.isEmpty && experimentRawOutput.isEmpty && experimentErrorMessage == nil))

                        Button("Clear History") {
                            experimentRuns.removeAll()
                            persistExperimentRunHistory()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isRunningExperiment || experimentRuns.isEmpty)

                        if isRunningExperiment {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let experimentErrorMessage {
                        Label(experimentErrorMessage, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .cornerRadius(8)
                    }
                }
            }

            SettingsCard("Output") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Model output")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(experimentTokenCount) token\(experimentTokenCount == 1 ? "" : "s") · \(experimentRawOutput.count) raw chars")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(experimentOutput.isEmpty ? "(empty)" : experimentOutput)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
                        .padding(12)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .cornerRadius(8)

                    if experimentRawOutput != experimentOutput {
                        Text("Raw stream")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(experimentRawOutput.isEmpty ? "(empty)" : experimentRawOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .padding(12)
                            .background(Color(nsColor: .textBackgroundColor))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                            .cornerRadius(8)
                    }
                }
            }

            if !experimentRuns.isEmpty {
                SettingsCard("Run History") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(experimentRuns) { run in
                            ModelExperimentRunCard(run: run) { rating in
                                rateExperimentRun(id: run.id, rating: rating)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if downloadedRunnableExperimentModels.contains(where: { $0.kind == appState.selectedWikiModelKind }) {
                experimentModelKind = appState.selectedWikiModelKind
            } else if let first = downloadedRunnableExperimentModels.first {
                experimentModelKind = first.kind
            }
            loadSavedExperimentPrompts()
            loadExperimentRunHistory()
            if selectedSavedExperimentPromptID == nil {
                selectedSavedExperimentPromptID = savedExperimentPrompts.first?.id
            }
        }
    }

    private var transcriptionLabSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let selectedEntry = transcriptionLabController.selectedEntry {
                transcriptionLabDetail(for: selectedEntry)
            } else {
                Toggle(
                    "Save voice-to-text recordings to history",
                    isOn: $appState.transcriptionLabEnabled
                )

                if !appState.transcriptionLabEnabled {
                    Text("Voice-to-text history is off. Audio from dictation is not saved to disk. Meeting transcripts are saved separately as markdown files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                transcriptionLabBrowser
            }
        }
    }

    private var recognizedVoicesSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ghost Pepper auto-creates reusable voice prints from speaker-tagged lab reruns. Marking more than one voice print as \"This is me\" is allowed.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let recognizedVoicesErrorMessage {
                Text(recognizedVoicesErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if recognizedVoices.isEmpty {
                ContentUnavailableView(
                    "No Recognized Voices",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Run speaker tagging in History to create reusable voice prints.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(recognizedVoices) { profile in
                        RecognizedVoiceProfileEditor(
                            profile: profile,
                            linkedSpeakerProfiles: recognizedVoiceSpeakerProfilesByID[profile.id] ?? [],
                            onChange: { updatedProfile in
                                upsertRecognizedVoiceProfile(updatedProfile)
                            },
                            onUnlinkSpeakerProfile: { speakerProfile in
                                unlinkSpeakerProfileFromRecognizedVoice(speakerProfile)
                            }
                        )
                    }
                }
            }
        }
    }

    @State private var showClearHistoryConfirmation = false
    @State private var isTranscriptionStageExpanded = true
    @State private var isDiarizationStageExpanded = true
    @State private var isCleanupStageExpanded = true

    private var transcriptionLabBrowser: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent recordings")
                    .font(.title3.weight(.semibold))
                Spacer()
                if !transcriptionLabController.entries.isEmpty {
                    Button("Clear History", role: .destructive) {
                        showClearHistoryConfirmation = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .alert("Clear All History?", isPresented: $showClearHistoryConfirmation) {
                Button("Clear", role: .destructive) {
                    transcriptionLabController.deleteAllEntries(using: appState.transcriptionLabStore)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes all saved recordings and transcriptions.")
            }

            TextField("Search transcriptions", text: $transcriptionLabController.searchText)
                .textFieldStyle(.roundedBorder)

            if transcriptionLabController.filteredEntries.isEmpty {
                if transcriptionLabController.searchText.isEmpty {
                    ContentUnavailableView(
                        "No Saved Recordings",
                        systemImage: "waveform",
                        description: Text("Make a few dictations in Ghost Pepper and they will appear here.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "magnifyingglass",
                        description: Text("No transcriptions match \"\(transcriptionLabController.searchText)\".")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(transcriptionLabController.filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Button {
                                transcriptionLabController.selectEntry(entry.id)
                            } label: {
                                CompactTranscriptionLabEntryRow(entry: entry)
                            }
                            .buttonStyle(.plain)

                            Button {
                                copyTranscriptionLabTranscript(for: entry)
                            } label: {
                                Image(systemName: "square.on.square")
                                    .font(.callout)
                            }
                            .buttonStyle(.borderless)
                            .help("Copy this transcript")
                            .disabled(preferredTranscriptToCopy(for: entry).isEmpty)
                            .padding(.top, 12)

                            Button {
                                transcriptionLabController.deleteEntry(entry.id, using: appState.transcriptionLabStore)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this recording")
                            .padding(.top, 12)
                        }
                    }
                }
            }
        }
    }

    private func transcriptionLabDetail(for entry: TranscriptionLabEntry) -> some View {
        let canPlayRecording = transcriptionLabController.audioURL(for: entry).pathExtension.lowercased() == "wav"
        let originalSpeechModelName = SpeechModelCatalog.model(named: entry.speechModelID)?.pickerLabel ?? entry.speechModelID

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    transcriptionLabController.closeDetail()
                } label: {
                    Label("Back to recordings", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }

            TranscriptionLabWorkshopSummary(
                entry: entry,
                speechModelName: originalSpeechModelName,
                hasOriginalDiarization: transcriptionLabController.originalDiarizationVisualization != nil
            )
            TranscriptionLabSourceRecordingSummary(
                entry: entry,
                canPlayRecording: canPlayRecording
            ) {
                playTranscriptionLabAudio(for: entry)
            }
            transcriptionLabTranscriptionStage(for: entry, originalSpeechModelName: originalSpeechModelName)
            transcriptionLabDiarizationStage(for: entry, originalSpeechModelName: originalSpeechModelName)
            transcriptionLabCleanupStage(for: entry)

            if let errorMessage = transcriptionLabController.errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private func transcriptionLabTranscriptionStage(
        for entry: TranscriptionLabEntry,
        originalSpeechModelName: String
    ) -> some View {
        TranscriptionLabStageDisclosure(
            "Transcription",
            isExpanded: $isTranscriptionStageExpanded
        ) {
            Text(originalSpeechModelName)
            Text(entry.rawTranscription?.isEmpty == false ? "Original available" : "No original text")
            Text(formattedOriginalStageDuration(transcriptionLabController.originalTranscriptionDuration))
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Original model and options")
                    .font(.subheadline.weight(.medium))
                Text("Originally transcribed with \(originalSpeechModelName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TranscriptionLabOutputComparison(
                originalTitle: "Original output",
                newTitle: "New output",
                hasNewOutput: !transcriptionLabController.experimentRawTranscription.isEmpty,
                placeholder: "Rerun transcription to compare a new transcript."
            ) {
                ReadOnlyTextPane(
                    text: entry.rawTranscription ?? "No transcription was captured for this recording.",
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )
            } options: {
                HStack(alignment: .center, spacing: 12) {
                    Text("Rerun transcription options")
                        .font(.subheadline.weight(.medium))

                    Picker("Speech Model", selection: $transcriptionLabController.selectedSpeechModelID) {
                        ForEach(ModelManager.availableModels) { model in
                            Text(model.pickerLabel).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)

                    Spacer()
                }
            } action: {
                HStack(alignment: .center, spacing: 12) {
                    transcriptionLabRerunButton(
                        title: "Rerun transcription",
                        runningTitle: "Running...",
                        isRunning: transcriptionLabController.isRunningTranscription,
                        disabled: transcriptionLabController.runningStage != nil
                    ) {
                        Task {
                            await transcriptionLabController.rerunTranscription()
                        }
                    }

                    Spacer()

                    if let duration = transcriptionLabController.experimentTranscriptionDuration {
                        Text(formattedStageDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } newOutput: {
                DiffReadOnlyTextPane(
                    originalText: entry.rawTranscription ?? "",
                    text: transcriptionLabController.experimentRawTranscription,
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )
            }
        }
    }

    private func transcriptionLabDiarizationStage(
        for entry: TranscriptionLabEntry,
        originalSpeechModelName: String
    ) -> some View {
        let selectedModelSupportsSpeakerTagging = SpeechModelCatalog.model(
            named: transcriptionLabController.selectedSpeechModelID
        )?.supportsSpeakerFiltering == true

        return TranscriptionLabStageDisclosure(
            "Diarization",
            isExpanded: $isDiarizationStageExpanded
        ) {
            Text(entry.speakerFilteringRan ? "Original tagged" : "Original off")
            Text(transcriptionLabController.originalDiarizationVisualization == nil ? "No timeline" : "Timeline available")
            Text(originalSpeechModelName)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Original model and options")
                    .font(.subheadline.weight(.medium))
                Text(entry.speakerFilteringRan
                     ? "Speaker tagging ran with \(originalSpeechModelName)."
                     : "Speaker tagging was off for the original transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TranscriptionLabOutputComparison(
                originalTitle: "Original timeline",
                newTitle: "New timeline",
                hasNewOutput: transcriptionLabController.experimentDiarizationVisualization != nil,
                placeholder: "Rerun speaker tagging to compare a new speaker timeline."
            ) {
                if let originalVisualization = transcriptionLabController.originalDiarizationVisualization {
                    TranscriptionLabDiarizationSummaryView(visualization: originalVisualization)
                } else {
                    Text("No original speaker tagging data was captured for this recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } options: {
                VStack(alignment: .leading, spacing: 12) {
                    transcriptionLabSpeakerIdentitiesSection

                    Text("Rerun speaker tagging options")
                        .font(.subheadline.weight(.medium))

                    HStack(alignment: .center, spacing: 12) {
                        Toggle(
                            "Run speaker tagging",
                            isOn: $transcriptionLabController.usesSpeakerTagging
                        )
                        .toggleStyle(.checkbox)
                        .disabled(!selectedModelSupportsSpeakerTagging || transcriptionLabController.runningStage != nil)

                        if !selectedModelSupportsSpeakerTagging {
                            Text("Speaker tagging is available only for FluidAudio models.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                }
            } action: {
                HStack(alignment: .center, spacing: 12) {
                    transcriptionLabRerunButton(
                        title: "Rerun speaker tagging",
                        runningTitle: "Running...",
                        isRunning: transcriptionLabController.isRunningTranscription,
                        disabled: transcriptionLabController.runningStage != nil || !selectedModelSupportsSpeakerTagging
                    ) {
                        Task {
                            await transcriptionLabController.rerunDiarization()
                        }
                    }

                    Spacer()

                    if let duration = transcriptionLabController.experimentTranscriptionDuration,
                       transcriptionLabController.experimentDiarizationVisualization != nil {
                        Text(formattedStageDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } newOutput: {
                if let experimentVisualization = transcriptionLabController.experimentDiarizationVisualization {
                    TranscriptionLabDiarizationSummaryView(visualization: experimentVisualization)

                    if let displayedSpeakerTaggedTranscriptText = transcriptionLabController.displayedSpeakerTaggedTranscriptText {
                        ReadOnlyTextPane(
                            text: displayedSpeakerTaggedTranscriptText,
                            minimumHeight: 84,
                            maximumHeight: 220,
                            monospaced: false
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptionLabSpeakerIdentitiesSection: some View {
        if transcriptionLabController.speakerProfilesInDisplayOrder.isEmpty == false {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speaker identities")
                    .font(.subheadline.weight(.medium))

                ForEach(transcriptionLabController.speakerProfilesInDisplayOrder, id: \.speakerID) { profile in
                    TranscriptionLabSpeakerProfileEditor(
                        profile: profile,
                        effectiveDisplayName: transcriptionLabController.displayName(for: profile.speakerID) ?? profile.speakerID,
                        recognizedVoiceOptions: transcriptionLabController.recognizedVoiceOptions,
                        showsGlobalUpdateButton: transcriptionLabController.hasPendingGlobalVoiceUpdate(for: profile.speakerID),
                        onDisplayNameChange: { updatedDisplayName in
                            transcriptionLabController.updateSpeakerDisplayName(
                                updatedDisplayName,
                                for: profile.speakerID
                            )
                        },
                        onIsMeChange: { isMe in
                            transcriptionLabController.setSpeakerIsMe(isMe, for: profile.speakerID)
                        },
                        onRecognizedVoiceChange: { recognizedVoiceID in
                            transcriptionLabController.setSpeakerRecognizedVoiceID(
                                recognizedVoiceID,
                                for: profile.speakerID
                            )
                            reloadRecognizedVoices()
                        },
                        onUpdateGlobalVoice: {
                            transcriptionLabController.pushSpeakerProfileToGlobalVoice(for: profile.speakerID)
                            reloadRecognizedVoices()
                        }
                    )
                }
            }
        } else if transcriptionLabController.diarizationVisualization != nil {
            Text("Run speaker tagging again on this recording to attach editable speaker names and reusable voice prints.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func transcriptionLabCleanupStage(for entry: TranscriptionLabEntry) -> some View {
        TranscriptionLabStageDisclosure(
            "Cleanup",
            isExpanded: $isCleanupStageExpanded
        ) {
            Text(entry.cleanupModelName)
            Text(entry.correctedTranscription?.isEmpty == false ? "Original available" : "No original text")
            Text(formattedOriginalStageDuration(transcriptionLabController.originalCleanupDuration))
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Original model and options")
                    .font(.subheadline.weight(.medium))
                Text("Originally cleaned with \(entry.cleanupModelName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TranscriptionLabOutputComparison(
                originalTitle: "Original output",
                newTitle: "New output",
                hasNewOutput: !transcriptionLabController.experimentCorrectedTranscription.isEmpty,
                placeholder: "Rerun cleanup to compare a new cleanup output."
            ) {
                ReadOnlyTextPane(
                    text: entry.correctedTranscription ?? "No corrected output was captured for this recording.",
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )
            } options: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rerun cleanup options")
                        .font(.subheadline.weight(.medium))

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Cleanup prompt")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Reset to Default") {
                                appState.cleanupPrompt = TextCleaner.defaultPrompt
                            }
                            .buttonStyle(.bordered)
                            .disabled(transcriptionLabController.runningStage != nil)
                        }

                        BorderedTextEditor(
                            text: $appState.cleanupPrompt,
                            minimumHeight: 84,
                            maximumHeight: 132,
                            monospaced: false
                        )
                        .disabled(transcriptionLabController.runningStage != nil)
                    }

                    HStack(alignment: .center, spacing: 12) {
                        Toggle(
                            "Use captured OCR",
                            isOn: $transcriptionLabController.usesCapturedOCR
                        )
                        .toggleStyle(.checkbox)
                        .disabled(entry.windowContext == nil || transcriptionLabController.runningStage != nil)

                        Text("Clean with")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Picker("Cleanup model", selection: $transcriptionLabController.selectedCleanupModelKind) {
                            ForEach(TextCleanupManager.cleanupGenerationModels, id: \.kind) { model in
                                Text(model.displayName).tag(model.kind)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300, alignment: .leading)

                        Button("Show full cleanup transcript") {
                            if let transcript = transcriptionLabController.latestCleanupTranscript {
                                appState.showCleanupTranscript(transcript)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(transcriptionLabController.latestCleanupTranscript == nil)

                        Spacer()
                    }

                    DisclosureGroup("Correction hints") {
                        addCorrectionSection
                            .padding(.top, 8)
                    }

                    DisclosureGroup("Cleanup examples") {
                        addExampleSection(for: entry)
                            .padding(.top, 8)
                    }
                }
            } action: {
                HStack(alignment: .center, spacing: 12) {
                    transcriptionLabRerunButton(
                        title: "Rerun cleanup",
                        runningTitle: "Running...",
                        isRunning: transcriptionLabController.isRunningCleanup,
                        disabled: transcriptionLabController.runningStage != nil
                    ) {
                        Task {
                            await transcriptionLabController.rerunCleanup(prompt: appState.cleanupPrompt)
                        }
                    }

                    Spacer()

                    if let duration = transcriptionLabController.experimentCleanupDuration {
                        Text(formattedStageDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } newOutput: {
                DiffReadOnlyTextPane(
                    originalText: entry.correctedTranscription ?? "",
                    text: transcriptionLabController.experimentCorrectedTranscription,
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )
            }
        }
    }

    private func transcriptionLabRerunButton(
        title: String,
        runningTitle: String,
        isRunning: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.trianglehead.clockwise")
                }
                Text(isRunning ? runningTitle : title)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
    }

    @State private var exampleInput: String = ""
    @State private var exampleOutput: String = ""
    @State private var exampleAdded: Bool = false
    @State private var correctionWrong: String = ""
    @State private var correctionRight: String = ""
    @State private var correctionAdded: Bool = false

    private var addCorrectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a word correction")
                .font(.subheadline.weight(.medium))

            Text("If a word is consistently misheard, add it here. Correction hints are added to the cleanup prompt.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Misheard as:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. open claw", text: $correctionWrong)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Should be:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. OpenClaw", text: $correctionRight)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                }

                Button(action: {
                    guard !correctionWrong.isEmpty, !correctionRight.isEmpty else { return }
                    appState.correctionStore.appendCommonlyMisheard(
                        MisheardReplacement(wrong: correctionWrong, right: correctionRight)
                    )
                    correctionAdded = true
                    correctionWrong = ""
                    correctionRight = ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { correctionAdded = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: correctionAdded ? "checkmark" : "plus.circle")
                        Text(correctionAdded ? "Added!" : "Add")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.top, 16)
                .disabled(correctionWrong.isEmpty || correctionRight.isEmpty)
            }
        }
    }

    private func addExampleSection(for entry: TranscriptionLabEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add an example to the cleanup prompt")
                .font(.subheadline.weight(.medium))

            Text("If the cleanup got it wrong, add an example so it handles similar cases correctly in the future.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Input (what was said):")
                    .font(.subheadline.weight(.medium))
                BorderedTextEditor(
                    text: $exampleInput,
                    minimumHeight: 50,
                    maximumHeight: 80,
                    monospaced: false
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Output (what it should be):")
                    .font(.subheadline.weight(.medium))
                BorderedTextEditor(
                    text: $exampleOutput,
                    minimumHeight: 50,
                    maximumHeight: 80,
                    monospaced: false
                )
            }

            HStack {
                Button(action: {
                    guard !exampleInput.isEmpty, !exampleOutput.isEmpty else { return }
                    let example = "\n\nInput: \"\(exampleInput)\"\nOutput: \(exampleOutput)\n"
                    if let range = appState.cleanupPrompt.range(of: "</EXAMPLES>") {
                        appState.cleanupPrompt.insert(contentsOf: example, at: range.lowerBound)
                    } else {
                        // No EXAMPLES block — append to end
                        appState.cleanupPrompt += "\n\n<EXAMPLES>\(example)</EXAMPLES>"
                    }
                    exampleAdded = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exampleAdded = false }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: exampleAdded ? "checkmark" : "plus.circle")
                        Text(exampleAdded ? "Example added!" : "Add Example")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(exampleInput.isEmpty || exampleOutput.isEmpty)

                Spacer()
            }
        }
        .onAppear {
            exampleInput = entry.rawTranscription ?? ""
            exampleOutput = entry.correctedTranscription ?? ""
            exampleAdded = false
        }
    }

    @State private var pepperChatTestResult: String?

    private var pepperChatSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Availability") {
                Toggle("Enable Context Bundler", isOn: $appState.pepperChatEnabled)

                Text("When disabled, Context Bundler stays out of the menu bar and its shortcut will not start new chats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard("Shortcut") {
                ShortcutRecorderView(
                    title: "Context Bundler (hold to speak)",
                    chord: appState.pepperChatChord,
                    onRecordingStateChange: appState.setShortcutCaptureActive
                ) { chord in
                    appState.updateShortcut(chord, for: .pepperChat)
                }

                Text("Hold the shortcut, speak your question, then release. The response appears in a floating chat window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SettingsCard("Zo API") {
                VStack(alignment: .leading, spacing: 18) {
                    SettingsField("API Key") {
                        SecureField("Zo API key (zo_sk_...)", text: $appState.pepperChatApiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                    }

                    Text("Get your API key from [Zo Settings > Advanced > Access Tokens](https://zo.computer).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Include screen context",
                        isOn: $appState.pepperChatIncludeScreenContext
                    )

                    Text("When enabled, text from your frontmost window is sent as context with your voice prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("Test Connection") {
                            pepperChatTestResult = nil
                            Task {
                                do {
                                    let backend = appState.makePepperChatBackend()
                                    guard let backend else {
                                        pepperChatTestResult = "Add your Zo API key above."
                                        return
                                    }
                                    var response = ""
                                    try await backend.send(prompt: "Say hello in one short sentence.", screenContext: nil) { chunk in
                                        response += chunk
                                    }
                                    pepperChatTestResult = response.isEmpty ? "Connected but got empty response." : "Connected! Response: \(String(response.prefix(100)))"
                                } catch {
                                    pepperChatTestResult = "Failed: \(error.localizedDescription)"
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)

                        if let result = pepperChatTestResult {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(result.hasPrefix("Connected") ? .green : .red)
                                .lineLimit(2)
                        }
                    }
                }
            }

            SettingsCard("Trello (optional)") {
                VStack(alignment: .leading, spacing: 18) {
                    if appState.trelloToken.isEmpty {
                        // Not connected
                        Text("Connect your Trello account to add cards directly from the Context Bundler. Get your API key from [trello.com/power-ups/admin](https://trello.com/power-ups/admin) → click **New** → copy the API key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        SettingsField("App Key") {
                            TextField("Paste your Trello API key", text: $appState.trelloApiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                        }

                        Button(action: {
                            let authURL = "https://trello.com/1/authorize?key=\(appState.trelloApiKey)&name=Ghost%20Pepper&scope=read,write&response_type=token&expiration=never"
                            if let url = URL(string: authURL) {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                Text("Connect Trello")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(appState.trelloApiKey.isEmpty)

                        Text("After clicking Allow on Trello's page, paste the token below:")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        SettingsField("Token") {
                            SecureField("Paste your Trello token here", text: $appState.trelloToken)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 320)
                        }
                    } else {
                        // Connected
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                            Text("Trello connected")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Button("Refresh boards") {
                                Task { await appState.fetchTrelloBoards() }
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                            Button("Disconnect") {
                                appState.trelloToken = ""
                                appState.trelloDefaultListId = ""
                                appState.trelloBoards = []
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }

                        // Default list picker
                        if !appState.trelloBoards.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Default list (used when you don't specify a board/list name):")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Picker("Default list", selection: $appState.trelloDefaultListId) {
                                    Text("Auto (first list)").tag("")
                                    ForEach(appState.trelloBoards) { board in
                                        ForEach(board.lists) { list in
                                            Text("\(board.name) → \(list.name)").tag(list.id)
                                        }
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 400)
                            }

                            Text("You can also say a board or list name when speaking — Ghost Pepper will match it automatically. \(appState.trelloBoards.count) boards, \(appState.trelloBoards.flatMap(\.lists).count) lists loaded.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Fetch boards & lists") {
                                Task { await appState.fetchTrelloBoards() }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if !appState.trelloToken.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                            Text("\"Add to Trello\" will appear in the Context Bundler")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onAppear {
            appState.loadStoredIntegrationKeysIfNeeded()
        }
    }

    @ObservedObject private var calendarService = GoogleCalendarService.shared
    @State private var googleAuthCode = ""
    @State private var meetingDirectoryBookmark: URL? = {
        MeetingTranscriptSettings.loadSaveDirectory()
    }()
    @State private var claudeAPIKeyInput: String = ""
    @State private var claudeAPIKeySaved: Bool = false
    @State private var didLoadClaudeAPIKey = false

    private var crossMeetingQACard: some View {
        SettingsCard("Cloud API (optional)") {
            VStack(alignment: .leading, spacing: 14) {
                Text("2nd Brain Q&A now runs locally. This Claude key is kept for optional cloud-backed legacy indexing and experiments.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Model", selection: $appState.claudeAPIModel) {
                    ForEach(ClaudeAPIModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }

                HStack(spacing: 8) {
                    SecureField("sk-ant-...", text: $claudeAPIKeyInput)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: claudeAPIKeyInput) { _, _ in
                            claudeAPIKeySaved = false
                        }
                    Button(claudeAPIKeySaved ? "Saved" : "Save") {
                        _ = KeychainHelper.set(claudeAPIKeyInput, for: AnthropicProvider.keychainKey)
                        claudeAPIKeySaved = true
                    }
                    .disabled(claudeAPIKeyInput.isEmpty)
                    Button("Clear") {
                        KeychainHelper.delete(AnthropicProvider.keychainKey)
                        claudeAPIKeyInput = ""
                        claudeAPIKeySaved = false
                    }
                    .disabled(claudeAPIKeyInput.isEmpty && !claudeAPIKeySaved)
                }

                Text("API key is stored in your macOS Keychain. Get one at [console.anthropic.com](https://console.anthropic.com/settings/keys).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var meetingTranscriptSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Image(systemName: "flask")
                    .foregroundColor(.orange)
                Text("Experimental")
                    .font(.caption.bold())
                    .foregroundColor(.orange)
            }
            .padding(.horizontal, 4)

            SettingsCard("Meeting Transcription") {
                VStack(alignment: .leading, spacing: 18) {
                    Toggle(
                        "Enable meeting transcription",
                        isOn: $appState.meetingTranscriptEnabled
                    )
                    .onChange(of: appState.meetingTranscriptEnabled) { _, _ in
                        appState.setupMeetingDetector()
                    }

                    Text("When enabled, Ghost Pepper can detect video calls and offer to transcribe them locally. Requires Screen Recording permission for system audio capture.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if appState.meetingTranscriptEnabled {
                        Toggle(
                            "Auto-detect meeting apps",
                            isOn: $appState.meetingAutoDetectEnabled
                        )
                        .onChange(of: appState.meetingAutoDetectEnabled) { _, _ in
                            appState.setupMeetingDetector()
                        }

                        Text("Monitors for Zoom, Teams, FaceTime, Meet, and other call apps. When detected, the pepper character will ask if you'd like to transcribe.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle(
                            "Float the meeting window while recording",
                            isOn: $appState.meetingWindowFloatsWhileRecording
                        )
                        .onChange(of: appState.meetingWindowFloatsWhileRecording) { _, _ in
                            appState.refreshMeetingTranscriptWindowPresentation()
                        }

                        Text("Keeps the current meeting window above other windows only while an active meeting is recording.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if appState.meetingTranscriptEnabled {
                SettingsCard("Google Calendar") {
                    VStack(alignment: .leading, spacing: 12) {
                        if calendarService.isSignedIn {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Connected to Google Calendar")
                                    .font(.body)
                                Spacer()
                                Button("Disconnect") {
                                    calendarService.signOut()
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.red)
                                .font(.caption)
                            }
                            Text("Meeting titles and attendees will be auto-populated from your calendar when you start a recording.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if calendarService.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7)
                                Text("Connecting...")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Connect Google Calendar to automatically populate meeting titles and attendees when recording.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if !GoogleCalendarService.isConfigured {
                                Text("Google Calendar OAuth is not configured in this build.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            if let authError = calendarService.authError {
                                Text(authError)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }

                            Button("Connect Google Calendar") {
                                calendarService.signIn()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .disabled(!GoogleCalendarService.isConfigured)
                        }
                    }
                }

                SettingsCard("Transcript Storage") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Save directory:")
                                .font(.body)

                            Text(meetingDirectoryBookmark?.path ?? MeetingTranscriptSettings.defaultSaveDirectory().path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button("Choose...") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false
                                panel.canChooseDirectories = true
                                panel.allowsMultipleSelection = false
                                panel.canCreateDirectories = true
                                panel.message = "Choose where to save Ghost Pepper meetings and 2nd Brain files"
                                panel.prompt = "Select Folder"

                                if panel.runModal() == .OK, let url = panel.url {
                                    MeetingTranscriptSettings.saveSaveDirectory(url)
                                    meetingDirectoryBookmark = url
                                }
                            }
                        }

                        Text("Meetings are saved as Markdown files organized in date folders. Generated 2nd Brain files are saved under the same folder in wikis/.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                SettingsCard("Summary Prompt") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This prompt is used to generate a summary after a meeting ends. The transcript is sent to your local cleanup model.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $appState.meetingSummaryPrompt)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 100)
                            .padding(4)
                            .background(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

                        HStack {
                            Button("Reset to Default") {
                                appState.meetingSummaryPrompt = MeetingSummaryGenerator.finalSummaryPrompt
                            }
                            .font(.caption)
                        }
                    }
                }

                crossMeetingQACard

                if !PermissionChecker.hasScreenRecordingPermission() {
                    SettingsCard("Permissions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Screen Recording permission is required to capture system audio (what other call participants say).")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button("Grant Screen Recording Permission") {
                                PermissionChecker.requestScreenRecordingPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                        }
                    }
                }
            }
        }
        .onAppear {
            guard !didLoadClaudeAPIKey else { return }
            didLoadClaudeAPIKey = true
            let storedKey = KeychainHelper.get(AnthropicProvider.keychainKey) ?? ""
            claudeAPIKeyInput = storedKey
            claudeAPIKeySaved = !storedKey.isEmpty
        }
    }

}

private struct TranscriptionLabSpeakerProfileEditor: View {
    let profile: TranscriptionLabSpeakerProfile
    let effectiveDisplayName: String
    let recognizedVoiceOptions: [RecognizedVoiceProfile]
    let showsGlobalUpdateButton: Bool
    let onDisplayNameChange: (String) -> Void
    let onIsMeChange: (Bool) -> Void
    let onRecognizedVoiceChange: (UUID?) -> Void
    let onUpdateGlobalVoice: () -> Void

    @State private var draftDisplayName: String
    @FocusState private var isNameFieldFocused: Bool

    init(
        profile: TranscriptionLabSpeakerProfile,
        effectiveDisplayName: String,
        recognizedVoiceOptions: [RecognizedVoiceProfile],
        showsGlobalUpdateButton: Bool,
        onDisplayNameChange: @escaping (String) -> Void,
        onIsMeChange: @escaping (Bool) -> Void,
        onRecognizedVoiceChange: @escaping (UUID?) -> Void,
        onUpdateGlobalVoice: @escaping () -> Void
    ) {
        self.profile = profile
        self.effectiveDisplayName = effectiveDisplayName
        self.recognizedVoiceOptions = recognizedVoiceOptions
        self.showsGlobalUpdateButton = showsGlobalUpdateButton
        self.onDisplayNameChange = onDisplayNameChange
        self.onIsMeChange = onIsMeChange
        self.onRecognizedVoiceChange = onRecognizedVoiceChange
        self.onUpdateGlobalVoice = onUpdateGlobalVoice
        _draftDisplayName = State(initialValue: profile.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text(profile.speakerID)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                if profile.recognizedVoiceID != nil {
                    Text("Reusable voice print")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                }

                Spacer()
            }

            HStack(alignment: .center, spacing: 12) {
                TextField(
                    "Name this speaker",
                    text: $draftDisplayName,
                    prompt: Text(effectiveDisplayName)
                )
                .textFieldStyle(.roundedBorder)
                .focused($isNameFieldFocused)
                .onSubmit(commitDisplayName)
                .onChange(of: isNameFieldFocused) { _, isFocused in
                    if !isFocused {
                        commitDisplayName()
                    }
                }

                Toggle(
                    "This is me",
                    isOn: Binding(
                        get: { profile.isMe },
                        set: onIsMeChange
                    )
                )
                .toggleStyle(.checkbox)
                .fixedSize()
            }

            if recognizedVoiceOptions.isEmpty == false || profile.recognizedVoiceID != nil {
                HStack(alignment: .center, spacing: 10) {
                    Text("Matched to")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .leading)

                    Picker(
                        "Voice print",
                        selection: Binding(
                            get: { profile.recognizedVoiceID },
                            set: onRecognizedVoiceChange
                        )
                    ) {
                        Text("No reusable voice print").tag(UUID?.none)

                        ForEach(recognizedVoiceOptions) { recognizedVoice in
                            Text(recognizedVoice.displayName)
                                .tag(UUID?.some(recognizedVoice.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260, alignment: .leading)

                    if profile.recognizedVoiceID != nil {
                        Button("Split") {
                            onRecognizedVoiceChange(nil)
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }

                    Spacer()
                }
            }

            if profile.evidenceTranscript.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tagged transcript evidence")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ReadOnlyTextPane(
                        text: profile.evidenceTranscript,
                        minimumHeight: 52,
                        maximumHeight: 110,
                        monospaced: false
                    )
                }
            }

            if profile.recognizedVoiceID == nil {
                Text("This speaker only has a recording-local label because Ghost Pepper could not build a reusable voice print from this sample.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if showsGlobalUpdateButton {
                Button("Update global voice print") {
                    commitDisplayName()
                    onUpdateGlobalVoice()
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onChange(of: profile.displayName) { _, newValue in
            if newValue != draftDisplayName {
                draftDisplayName = newValue
            }
        }
    }

    private func commitDisplayName() {
        guard draftDisplayName != profile.displayName else {
            return
        }

        onDisplayNameChange(draftDisplayName)
    }
}

private struct RecognizedVoiceProfileEditor: View {
    let profile: RecognizedVoiceProfile
    let linkedSpeakerProfiles: [TranscriptionLabSpeakerProfile]
    let onChange: (RecognizedVoiceProfile) -> Void
    let onUnlinkSpeakerProfile: (TranscriptionLabSpeakerProfile) -> Void

    @State private var draftDisplayName: String
    @State private var showsLinkedSpeakerProfiles = false
    @FocusState private var isNameFieldFocused: Bool

    init(
        profile: RecognizedVoiceProfile,
        linkedSpeakerProfiles: [TranscriptionLabSpeakerProfile],
        onChange: @escaping (RecognizedVoiceProfile) -> Void,
        onUnlinkSpeakerProfile: @escaping (TranscriptionLabSpeakerProfile) -> Void
    ) {
        self.profile = profile
        self.linkedSpeakerProfiles = linkedSpeakerProfiles
        self.onChange = onChange
        self.onUnlinkSpeakerProfile = onUnlinkSpeakerProfile
        _draftDisplayName = State(initialValue: profile.displayName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                TextField("Recognized voice name", text: $draftDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFieldFocused)
                    .onSubmit(commitDisplayName)
                    .onChange(of: isNameFieldFocused) { _, isFocused in
                        if !isFocused {
                            commitDisplayName()
                        }
                    }

                Toggle(
                    "This is me",
                    isOn: Binding(
                        get: { profile.isMe },
                        set: { isMe in
                            var updatedProfile = profile
                            updatedProfile.isMe = isMe
                            updatedProfile.updatedAt = Date()
                            onChange(updatedProfile)
                        }
                    )
                )
                .toggleStyle(.checkbox)
                .fixedSize()
            }

            HStack(alignment: .center, spacing: 12) {
                Text("Updated \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(profile.updateCount) matches")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(linkedSpeakerPrintCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }

            if profile.evidenceTranscript.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latest transcript evidence")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    ReadOnlyTextPane(
                        text: profile.evidenceTranscript,
                        minimumHeight: 52,
                        maximumHeight: 110,
                        monospaced: false
                    )
                }
            }

            DisclosureGroup(isExpanded: $showsLinkedSpeakerProfiles) {
                if linkedSpeakerProfiles.isEmpty {
                    Text("No saved recording speaker prints are linked to this voice.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(linkedSpeakerProfiles, id: \.recognizedVoiceLinkID) { speakerProfile in
                            RecognizedVoiceLinkedSpeakerProfileRow(
                                profile: speakerProfile,
                                onUnlink: {
                                    onUnlinkSpeakerProfile(speakerProfile)
                                }
                            )
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                Text("Linked speaker prints")
                    .font(.caption.weight(.medium))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onChange(of: profile.displayName) { _, newValue in
            if newValue != draftDisplayName {
                draftDisplayName = newValue
            }
        }
    }

    private func commitDisplayName() {
        guard draftDisplayName != profile.displayName else {
            return
        }

        let normalizedName = draftDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else {
            draftDisplayName = profile.displayName
            return
        }

        var updatedProfile = profile
        updatedProfile.displayName = normalizedName
        updatedProfile.updatedAt = Date()
        onChange(updatedProfile)
    }

    private var linkedSpeakerPrintCountText: String {
        let count = linkedSpeakerProfiles.count
        return count == 1 ? "1 linked speaker print" : "\(count) linked speaker prints"
    }
}

private struct RecognizedVoiceLinkedSpeakerProfileRow: View {
    let profile: TranscriptionLabSpeakerProfile
    let onUnlink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(profile.speakerID)
                    .font(.caption.weight(.medium))

                Text(profile.entryID.uuidString.prefix(8))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Unlink", action: onUnlink)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if profile.evidenceTranscript.isEmpty == false {
                Text(profile.evidenceTranscript)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }
}

private extension TranscriptionLabSpeakerProfile {
    var recognizedVoiceLinkID: String {
        "\(entryID.uuidString)-\(speakerID)"
    }
}

private struct ScreenRecordingRecoveryView: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ghost Pepper needs Screen Recording access. Grant it in System Settings, then return to Ghost Pepper.")
                .font(.caption)
                .foregroundStyle(.red)

            Button("Open Screen Recording Settings", action: onOpenSettings)
            .controlSize(.small)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            content
        }
    }
}

private struct ThemeSwatch: View {
    let theme: AppTheme
    let title: String
    let subtitle: String
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: theme.id == .windows95 ? 0 : 8, style: .continuous)
                        .fill(theme.contextBubbleBackground)
                        .frame(height: 54)
                        .overlay(alignment: .topLeading) {
                            HStack(spacing: 5) {
                                Circle().fill(theme.accent).frame(width: 8, height: 8)
                                RoundedRectangle(cornerRadius: theme.id == .windows95 ? 0 : 3)
                                    .fill(theme.textBackground.opacity(0.85))
                                    .frame(width: 52, height: 8)
                            }
                            .padding(8)
                        }

                    Rectangle()
                        .fill(theme.accent)
                        .frame(height: theme.id == .windows95 ? 8 : 5)
                }

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(width: 150, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: theme.id == .windows95 ? 0 : 10, style: .continuous)
                    .fill(theme.controlBackground.opacity(theme.id == .current ? 0.45 : 1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.id == .windows95 ? 0 : 10, style: .continuous)
                    .stroke(isSelected ? theme.accent : theme.separator, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ModelExperimentRunCard: View {
    let run: ModelExperimentRunResult
    let onRate: (Int?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.modelDisplayName)
                        .font(.subheadline.weight(.semibold))
                    Text(run.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(run.tokenCount) token\(run.tokenCount == 1 ? "" : "s")")
                    Text(Self.durationText(run.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Text("Rating")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(1...5, id: \.self) { value in
                    Button {
                        onRate(run.rating == value ? nil : value)
                    } label: {
                        Image(systemName: (run.rating ?? 0) >= value ? "star.fill" : "star")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle((run.rating ?? 0) >= value ? .yellow : .secondary)
                    .help("\(value) star\(value == 1 ? "" : "s")")
                }
                if run.rating != nil {
                    Button("Clear") {
                        onRate(nil)
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = run.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Text(run.output.isEmpty ? "(empty)" : run.output)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .cornerRadius(8)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .cornerRadius(10)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        if duration <= 0 { return "not timed" }
        if duration < 1 { return "\(Int((duration * 1000).rounded())) ms" }
        if duration < 60 { return String(format: "%.1fs", duration) }
        let minutes = Int(duration / 60)
        let seconds = Int(duration.truncatingRemainder(dividingBy: 60))
        return "\(minutes)m \(seconds)s"
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? .green : .red)
            Text(title)
                .font(.callout)
            Spacer()
            if !isGranted {
                Button("Grant") { action() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
            }
        }
    }
}

private struct CorrectionsEditor: View {
    let title: String
    let text: Binding<String>
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))

            BorderedTextEditor(text: text, minimumHeight: 96, maximumHeight: 160, monospaced: false)

            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct CompactTranscriptionLabEntryRow: View {
    let entry: TranscriptionLabEntry
    @State private var isHovered = false

    private var titleText: String {
        if let corrected = entry.correctedTranscription, !corrected.isEmpty {
            return corrected
        }

        if let raw = entry.rawTranscription, !raw.isEmpty {
            return raw
        }

        return "Recording without transcription"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.createdAt, style: .time)
                        .font(.subheadline.weight(.semibold))
                    Text(entry.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(titleText)
                    .font(.body)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(alignment: .trailing, spacing: 8) {
                Text(String(format: "%.1fs", entry.audioDuration))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.08) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct DiffReadOnlyTextPane: View {
    let originalText: String
    let text: String
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let monospaced: Bool

    private var segments: [TranscriptionLabTextDiffSegment] {
        TranscriptionLabTextDiff.segments(from: originalText, to: text)
    }

    private var renderedText: String {
        TranscriptionLabTextDiff.renderedText(from: segments)
    }

    var body: some View {
        ScrollView {
            diffText
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(
            height: textPaneHeight(
                for: renderedText.isEmpty ? text : renderedText,
                minimumHeight: minimumHeight,
                maximumHeight: maximumHeight
            )
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var diffText: Text {
        let font = monospaced ? Font.system(.body, design: .monospaced) : .body

        guard !segments.isEmpty else {
            return Text(text).font(font)
        }

        return segments.enumerated().reduce(Text("")) { result, item in
            let (index, segment) = item
            let prefix = index == 0 || !segment.needsLeadingSpace ? Text("") : Text(" ")
            return result + prefix + styledText(for: segment, font: font)
        }
    }

    private func styledText(for segment: TranscriptionLabTextDiffSegment, font: Font) -> Text {
        let base = Text(segment.text).font(font)

        switch segment.kind {
        case .unchanged:
            return base
        case .inserted:
            return base
                .foregroundColor(Color(nsColor: .systemGreen))
                .underline()
                .bold()
        case .removed:
            return base
                .foregroundColor(Color(nsColor: .systemRed))
                .strikethrough()
        }
    }
}

private struct BorderedTextEditor: View {
    let text: Binding<String>
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let monospaced: Bool

    var body: some View {
        TextEditor(text: text)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .scrollContentBackground(.hidden)
            .frame(height: textPaneHeight(for: text.wrappedValue, minimumHeight: minimumHeight, maximumHeight: maximumHeight))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}

private func textPaneHeight(
    for text: String,
    minimumHeight: CGFloat,
    maximumHeight: CGFloat
) -> CGFloat {
    let lineCount = max(text.components(separatedBy: "\n").count, 1)
    let estimatedHeight = CGFloat(lineCount) * 20 + 28
    return min(max(estimatedHeight, minimumHeight), maximumHeight)
}

private struct TranscriptionLabWorkshopSummary: View {
    let entry: TranscriptionLabEntry
    let speechModelName: String
    let hasOriginalDiarization: Bool

    private var hasRawTranscription: Bool {
        entry.rawTranscription?.isEmpty == false
    }

    private var hasCleanedTranscription: Bool {
        entry.correctedTranscription?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    Text("Transcript workshop")
                        .font(.title3.weight(.semibold))

                    Spacer(minLength: 16)

                    statusPills
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Transcript workshop")
                        .font(.title3.weight(.semibold))

                    statusPills
                }
            }

            TranscriptionLabMetadataLine(items: [
                TranscriptionLabMetadataItem("Recorded", entry.createdAt.formatted(date: .abbreviated, time: .shortened)),
                TranscriptionLabMetadataItem("Duration", String(format: "%.1fs", entry.audioDuration)),
                TranscriptionLabMetadataItem("Speech", speechModelName),
                TranscriptionLabMetadataItem("Cleanup", entry.cleanupModelName),
            ])

            TranscriptionLabSettingsNotice()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var statusPills: some View {
        HStack(alignment: .center, spacing: 8) {
            TranscriptionLabStatusPill(
                title: "Transcribed",
                systemImage: "text.quote",
                tint: hasRawTranscription ? .green : .secondary
            )
            TranscriptionLabStatusPill(
                title: "Tagged",
                systemImage: "person.2.wave.2",
                tint: hasOriginalDiarization ? .green : .secondary
            )
            TranscriptionLabStatusPill(
                title: entry.cleanupUsedFallback ? "Cleanup fallback" : "Cleaned",
                systemImage: entry.cleanupUsedFallback ? "exclamationmark.triangle" : "sparkles",
                tint: hasCleanedTranscription && !entry.cleanupUsedFallback ? .green : .orange
            )
        }
    }
}

private struct TranscriptionLabMetadataItem: Identifiable {
    let label: String
    let value: String

    var id: String {
        "\(label)-\(value)"
    }

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

private struct TranscriptionLabMetadataLine: View {
    let items: [TranscriptionLabMetadataItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                ForEach(items) { item in
                    metadataText(for: item)
                }
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(items) { item in
                    metadataText(for: item)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func metadataText(for item: TranscriptionLabMetadataItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(item.label)
                .fontWeight(.medium)
            Text(item.value)
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

private struct TranscriptionLabStatusPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Image(systemName: systemImage)
                .imageScale(.small)
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
    }
}

private struct TranscriptionLabSettingsNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)

            Text("Changes you make here update app settings and become the defaults for future recordings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
    }
}

private struct TranscriptionLabSourceRecordingSummary: View {
    let entry: TranscriptionLabEntry
    let canPlayRecording: Bool
    let onPlay: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 14) {
                sourceSummary
                Spacer(minLength: 16)
                playButton
            }

            VStack(alignment: .leading, spacing: 12) {
                sourceSummary
                playButton
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.25))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private var sourceSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Source recording")
                .font(.subheadline.weight(.semibold))

            TranscriptionLabMetadataLine(items: [
                TranscriptionLabMetadataItem("Recorded", entry.createdAt.formatted(date: .abbreviated, time: .shortened)),
                TranscriptionLabMetadataItem("Duration", String(format: "%.1fs", entry.audioDuration)),
                TranscriptionLabMetadataItem("Speech", SpeechModelCatalog.model(named: entry.speechModelID)?.statusName ?? entry.speechModelID),
                TranscriptionLabMetadataItem("Cleanup", entry.cleanupModelName),
            ])
        }
    }

    private var playButton: some View {
        Button {
            onPlay()
        } label: {
            Label("Play recording", systemImage: "play.fill")
        }
        .buttonStyle(.bordered)
        .disabled(!canPlayRecording)
        .help(canPlayRecording ? "Play the saved recording" : "Playback is available for newly archived recordings")
    }
}

private struct TranscriptionLabStageDisclosure<SummaryContent: View, Content: View>: View {
    let title: String
    let summaryContent: SummaryContent
    let content: Content
    @Binding var isExpanded: Bool

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder summary: () -> SummaryContent,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        _isExpanded = isExpanded
        summaryContent = summary()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TranscriptionLabStageHeaderButton(
                title: title,
                isExpanded: isExpanded,
                summary: summaryContent
            ) {
                isExpanded.toggle()
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.top, 14)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

private struct TranscriptionLabStageHeaderButton<SummaryContent: View>: View {
    let title: String
    let isExpanded: Bool
    let summary: SummaryContent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    summary
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TranscriptionLabOutputComparison<
    OriginalContent: View,
    OptionsContent: View,
    ActionContent: View,
    NewOutputContent: View
>: View {
    let originalTitle: String
    let newTitle: String
    let hasNewOutput: Bool
    let placeholder: String
    let originalContent: OriginalContent
    let optionsContent: OptionsContent
    let actionContent: ActionContent
    let newOutputContent: NewOutputContent

    init(
        originalTitle: String,
        newTitle: String,
        hasNewOutput: Bool,
        placeholder: String,
        @ViewBuilder original: () -> OriginalContent,
        @ViewBuilder options: () -> OptionsContent,
        @ViewBuilder action: () -> ActionContent,
        @ViewBuilder newOutput: () -> NewOutputContent
    ) {
        self.originalTitle = originalTitle
        self.newTitle = newTitle
        self.hasNewOutput = hasNewOutput
        self.placeholder = placeholder
        originalContent = original()
        optionsContent = options()
        actionContent = action()
        newOutputContent = newOutput()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(originalTitle)
                    .font(.subheadline.weight(.medium))
                originalContent
            }

            optionsContent

            actionContent

            VStack(alignment: .leading, spacing: 8) {
                Text(newTitle)
                    .font(.subheadline.weight(.medium))

                if hasNewOutput {
                    newOutputContent
                } else {
                    Text(placeholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct TranscriptionLabResultStack<SupplementaryContent: View>: View {
    let rawTitle: String
    let rawText: String
    let correctedTitle: String
    let correctedText: String
    let supplementaryContent: SupplementaryContent?

    init(
        rawTitle: String,
        rawText: String,
        correctedTitle: String,
        correctedText: String,
        @ViewBuilder supplementaryContent: () -> SupplementaryContent
    ) {
        self.rawTitle = rawTitle
        self.rawText = rawText
        self.correctedTitle = correctedTitle
        self.correctedText = correctedText
        self.supplementaryContent = supplementaryContent()
    }

    init(
        rawTitle: String,
        rawText: String,
        correctedTitle: String,
        correctedText: String
    ) where SupplementaryContent == EmptyView {
        self.rawTitle = rawTitle
        self.rawText = rawText
        self.correctedTitle = correctedTitle
        self.correctedText = correctedText
        self.supplementaryContent = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let supplementaryContent {
                supplementaryContent
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(rawTitle)
                    .font(.subheadline.weight(.medium))
                ReadOnlyTextPane(text: rawText, minimumHeight: 72, maximumHeight: 180, monospaced: false)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(correctedTitle)
                    .font(.subheadline.weight(.medium))
                ReadOnlyTextPane(text: correctedText, minimumHeight: 72, maximumHeight: 180, monospaced: false)
            }
        }
    }
}

private struct TranscriptionLabMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.callout)
        }
    }
}

private struct TranscriptionLabMetadataSummary: View {
    let entry: TranscriptionLabEntry

    var body: some View {
        HStack(spacing: 18) {
            Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
            Text(String(format: "%.1fs", entry.audioDuration))
            Text(SpeechModelCatalog.model(named: entry.speechModelID)?.statusName ?? entry.speechModelID)
            Text(entry.cleanupModelName)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TranscriptionLabDiarizationSummaryView: View {
    private static let speakerPalette: [NSColor] = [
        .systemBlue,
        .systemGreen,
        .systemOrange,
        .systemPink,
        .systemTeal,
        .systemRed,
        .systemIndigo,
        .systemBrown,
    ]

    let visualization: TranscriptionLabController.DiarizationVisualization

    private var totalDuration: TimeInterval {
        max(
            visualization.audioDuration,
            visualization.spans.map(\.endTime).max() ?? 0
        )
    }

    private var summaryText: String {
        let speakerText = visualization.speakerIDsInDisplayOrder.isEmpty
            ? "Speaker tagging ran"
            : "Tagged \(formattedSpeakerCount(visualization.speakerIDsInDisplayOrder.count))"

        if visualization.usedFallback {
            if let fallbackReason = visualization.fallbackReason {
                return "\(speakerText), but transcription fell back to the full recording (\(fallbackReasonText(for: fallbackReason)))."
            }

            return "\(speakerText), but transcription fell back to the full recording."
        }

        if let targetSpeakerID = visualization.targetSpeakerID {
            if visualization.includedSpeakerIDsInDisplayOrder.count > 1 {
                return "\(speakerText) and transcribed \(formattedDuration(visualization.includedTranscriptDuration)) from \(includedSpeakerSummaryText(targetSpeakerID: targetSpeakerID))."
            }

            return "\(speakerText) and kept \(formattedDuration(visualization.keptAudioDuration)) from \(visualization.displayName(for: targetSpeakerID))."
        }

        return "\(speakerText)."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("Speaker tagging")
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(visualization.spans.enumerated()), id: \.offset) { _, span in
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(speakerColor(for: span.speakerID))
                            .opacity(span.isIncludedInTranscript ? 1 : 0.32)
                            .frame(width: segmentWidth(for: span, totalWidth: geometry.size.width))
                            .overlay {
                                Text(span.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(span.isIncludedInTranscript ? Color.white : Color.primary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.65)
                                    .padding(.horizontal, 6)
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            if visualization.speakerIDsInDisplayOrder.isEmpty == false {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 8) {
                        ForEach(visualization.speakerIDsInDisplayOrder, id: \.self) { speakerID in
                            HStack(alignment: .center, spacing: 6) {
                                Circle()
                                    .fill(speakerColor(for: speakerID))
                                    .frame(width: 8, height: 8)

                                Text(visualization.displayName(for: speakerID))

                                if let speakerStatus = speakerStatusText(for: speakerID) {
                                    Text(speakerStatus)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 999, style: .continuous)
                                    .fill(Color(nsColor: .textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 999, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            )
                        }
                    }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                if let targetSpeakerID = visualization.targetSpeakerID {
                    Text(
                        visualization.usedFallback
                            ? "Target: \(visualization.displayName(for: targetSpeakerID))"
                            : "Kept: \(visualization.displayName(for: targetSpeakerID))"
                    )
                }

                Text("Kept \(formattedDuration(visualization.keptAudioDuration))")

                if visualization.includedTranscriptDuration != visualization.keptAudioDuration {
                    Text("Transcript \(formattedDuration(visualization.includedTranscriptDuration))")
                }

                if visualization.usedFallback {
                    Text("Used full recording")
                }

                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func segmentWidth(
        for span: TranscriptionLabController.DiarizationVisualization.Span,
        totalWidth: CGFloat
    ) -> CGFloat {
        guard totalDuration > 0 else {
            return totalWidth / CGFloat(max(visualization.spans.count, 1))
        }

        return max(totalWidth * spanDurationFraction(for: span), 3)
    }

    private func spanDurationFraction(
        for span: TranscriptionLabController.DiarizationVisualization.Span
    ) -> CGFloat {
        CGFloat(max(0, span.endTime - span.startTime) / totalDuration)
    }

    private func speakerColor(for speakerID: String) -> Color {
        let speakerIDs = visualization.speakerIDsInDisplayOrder
        guard let speakerIndex = speakerIDs.firstIndex(of: speakerID) else {
            return Color.accentColor
        }

        let paletteIndex = speakerIndex % Self.speakerPalette.count
        return Color(nsColor: Self.speakerPalette[paletteIndex])
    }

    private func formattedSpeakerCount(_ count: Int) -> String {
        count == 1 ? "1 speaker" : "\(count) speakers"
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }

    private func includedSpeakerSummaryText(targetSpeakerID: String) -> String {
        let extraSpeakerCount = max(0, visualization.includedSpeakerIDsInDisplayOrder.count - 1)
        guard extraSpeakerCount > 0 else {
            return visualization.displayName(for: targetSpeakerID)
        }

        let extraText = extraSpeakerCount == 1
            ? "1 matching speaker"
            : "\(extraSpeakerCount) matching speakers"
        return "\(visualization.displayName(for: targetSpeakerID)) + \(extraText)"
    }

    private func speakerStatusText(for speakerID: String) -> String? {
        if visualization.usedFallback {
            return speakerID == visualization.targetSpeakerID ? "Target" : nil
        }

        if speakerID == visualization.targetSpeakerID {
            return "Kept"
        }

        return visualization.includedSpeakerIDsInDisplayOrder.contains(speakerID) ? "Included" : nil
    }

    private func fallbackReasonText(for reason: DiarizationSummary.FallbackReason) -> String {
        switch reason {
        case .noUsableSpeakerSpans:
            return "no usable speaker spans"
        case .noSpeakerReachedThreshold:
            return "no speaker reached the selection threshold"
        case .ambiguousDominantSpeaker:
            return "speaker split was too close to call"
        case .singleDetectedSpeaker:
            return "only one speaker was detected"
        case .insufficientKeptAudio:
            return "kept audio was too short"
        case .filteredAudioExtractionFailed:
            return "filtered audio extraction failed"
        case .emptyFilteredTranscription:
            return "filtered transcription came back empty"
        }
    }
}

private struct ReadOnlyTextPane: View {
    let text: String
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let monospaced: Bool

    var body: some View {
        ScrollView {
            Text(text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(height: textPaneHeight(for: text, minimumHeight: minimumHeight, maximumHeight: maximumHeight))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

struct TranscriptionLabTextDiffSegment: Equatable {
    enum Kind: Equatable {
        case unchanged
        case inserted
        case removed
    }

    let kind: Kind
    let text: String

    fileprivate let needsLeadingSpace: Bool

    init(kind: Kind, text: String, needsLeadingSpace: Bool = false) {
        self.kind = kind
        self.text = text
        self.needsLeadingSpace = needsLeadingSpace
    }

    static func == (lhs: TranscriptionLabTextDiffSegment, rhs: TranscriptionLabTextDiffSegment) -> Bool {
        lhs.kind == rhs.kind && lhs.text == rhs.text
    }
}

enum TranscriptionLabTextDiff {
    static func segments(from originalText: String, to newText: String) -> [TranscriptionLabTextDiffSegment] {
        let wordSegments = baseSegments(
            fromTokens: tokenize(originalText),
            toTokens: tokenize(newText),
            separator: " "
        )

        return refineSingleTokenReplacements(in: wordSegments)
    }

    static func renderedText(from segments: [TranscriptionLabTextDiffSegment]) -> String {
        segments.enumerated().reduce(into: "") { result, item in
            let (index, segment) = item
            if index > 0 && segment.needsLeadingSpace {
                result.append(" ")
            }
            result.append(segment.text)
        }
    }

    private static func baseSegments(
        fromTokens originalTokens: [String],
        toTokens newTokens: [String],
        separator: String,
        firstSegmentNeedsLeadingSpace: Bool = false
    ) -> [TranscriptionLabTextDiffSegment] {
        guard !originalTokens.isEmpty || !newTokens.isEmpty else {
            return []
        }

        var longestCommonSubsequence = Array(
            repeating: Array(repeating: 0, count: newTokens.count + 1),
            count: originalTokens.count + 1
        )

        for originalIndex in stride(from: originalTokens.count - 1, through: 0, by: -1) {
            for newIndex in stride(from: newTokens.count - 1, through: 0, by: -1) {
                if originalTokens[originalIndex] == newTokens[newIndex] {
                    longestCommonSubsequence[originalIndex][newIndex] =
                        longestCommonSubsequence[originalIndex + 1][newIndex + 1] + 1
                } else {
                    longestCommonSubsequence[originalIndex][newIndex] = max(
                        longestCommonSubsequence[originalIndex + 1][newIndex],
                        longestCommonSubsequence[originalIndex][newIndex + 1]
                    )
                }
            }
        }

        var segments: [TranscriptionLabTextDiffSegment] = []
        var originalIndex = 0
        var newIndex = 0

        while originalIndex < originalTokens.count && newIndex < newTokens.count {
            if originalTokens[originalIndex] == newTokens[newIndex] {
                appendSegment(
                    kind: .unchanged,
                    token: originalTokens[originalIndex],
                    separator: separator,
                    firstSegmentNeedsLeadingSpace: firstSegmentNeedsLeadingSpace,
                    to: &segments
                )
                originalIndex += 1
                newIndex += 1
            } else if longestCommonSubsequence[originalIndex + 1][newIndex] >= longestCommonSubsequence[originalIndex][newIndex + 1] {
                appendSegment(
                    kind: .removed,
                    token: originalTokens[originalIndex],
                    separator: separator,
                    firstSegmentNeedsLeadingSpace: firstSegmentNeedsLeadingSpace,
                    to: &segments
                )
                originalIndex += 1
            } else {
                appendSegment(
                    kind: .inserted,
                    token: newTokens[newIndex],
                    separator: separator,
                    firstSegmentNeedsLeadingSpace: firstSegmentNeedsLeadingSpace,
                    to: &segments
                )
                newIndex += 1
            }
        }

        while originalIndex < originalTokens.count {
            appendSegment(
                kind: .removed,
                token: originalTokens[originalIndex],
                separator: separator,
                firstSegmentNeedsLeadingSpace: firstSegmentNeedsLeadingSpace,
                to: &segments
            )
            originalIndex += 1
        }

        while newIndex < newTokens.count {
            appendSegment(
                kind: .inserted,
                token: newTokens[newIndex],
                separator: separator,
                firstSegmentNeedsLeadingSpace: firstSegmentNeedsLeadingSpace,
                to: &segments
            )
            newIndex += 1
        }

        return segments
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func refineSingleTokenReplacements(
        in segments: [TranscriptionLabTextDiffSegment]
    ) -> [TranscriptionLabTextDiffSegment] {
        var refined: [TranscriptionLabTextDiffSegment] = []
        var index = 0

        while index < segments.count {
            if index + 1 < segments.count,
               segments[index].kind == .removed,
               segments[index + 1].kind == .inserted,
               !containsWhitespace(segments[index].text),
               !containsWhitespace(segments[index + 1].text) {
                let characterSegments = baseSegments(
                    fromTokens: segments[index].text.map { String($0) },
                    toTokens: segments[index + 1].text.map { String($0) },
                    separator: "",
                    firstSegmentNeedsLeadingSpace: segments[index].needsLeadingSpace
                )

                if characterSegments.contains(where: { $0.kind == .unchanged }) {
                    refined.append(contentsOf: characterSegments)
                    index += 2
                    continue
                }
            }

            refined.append(segments[index])
            index += 1
        }

        return refined
    }

    private static func containsWhitespace(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func appendSegment(
        kind: TranscriptionLabTextDiffSegment.Kind,
        token: String,
        separator: String,
        firstSegmentNeedsLeadingSpace: Bool,
        to segments: inout [TranscriptionLabTextDiffSegment]
    ) {
        guard !token.isEmpty else {
            return
        }

        if let lastSegment = segments.last, lastSegment.kind == kind {
            segments[segments.count - 1] = TranscriptionLabTextDiffSegment(
                kind: kind,
                text: lastSegment.text + separator + token,
                needsLeadingSpace: lastSegment.needsLeadingSpace
            )
        } else {
            segments.append(
                .init(
                    kind: kind,
                    text: token,
                    needsLeadingSpace: segments.isEmpty ? firstSegmentNeedsLeadingSpace : !separator.isEmpty
                )
            )
        }
    }
}
