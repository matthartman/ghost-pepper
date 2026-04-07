import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement

final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(appState: appState)

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
    case recording
    case cleanup
    case corrections
    case models
    case transcriptionLab
    case pepperChat
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .cleanup: "Cleanup"
        case .corrections: "Corrections"
        case .models: "Models"
        case .transcriptionLab: "History"
        case .pepperChat: "Pepper Chat"
        case .general: "General"
        }
    }

    var subtitle: String {
        switch self {
        case .recording: "Shortcuts, microphone input, dictation testing, and sound feedback."
        case .cleanup: "Prompt cleanup, OCR context, and learning behavior."
        case .corrections: "Words and replacements Ghost Pepper should preserve."
        case .models: "Speech and cleanup model downloads and runtime status."
        case .transcriptionLab: "Saved recordings, reruns, and cleanup experiments."
        case .pepperChat: "Voice-to-AI assistant with streaming responses."
        case .general: "Startup behavior and app-wide preferences."
        }
    }

    var systemImageName: String {
        switch self {
        case .recording: "waveform.and.mic"
        case .cleanup: "sparkles"
        case .corrections: "text.badge.checkmark"
        case .models: "brain"
        case .transcriptionLab: "waveform.badge.magnifyingglass"
        case .pepperChat: "bubble.right"
        case .general: "gearshape"
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

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    @State private var hasAccessibilityPermission = PermissionChecker.checkAccessibility()
    @State private var hasInputMonitoringPermission = PermissionChecker.checkInputMonitoring()
    @State private var permissionPollTimer: Timer?
    @State private var selectedSection: SettingsSection = .recording
    @State private var transcriptionLabPreviewSound: NSSound?
    @StateObject private var dictationTestController: SettingsDictationTestController
    @StateObject private var transcriptionLabController: TranscriptionLabController

    init(appState: AppState) {
        self.appState = appState
        _dictationTestController = StateObject(
            wrappedValue: SettingsDictationTestController(transcriber: appState.transcriber)
        )
        _transcriptionLabController = StateObject(
            wrappedValue: TranscriptionLabController(
                defaultSpeechModelID: appState.speechModel,
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
                runTranscription: { entry, speechModelID in
                    try await appState.rerunTranscriptionLabTranscription(
                        entry,
                        speechModelID: speechModelID
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
                syncSelectedSpeechModelID: { speechModelID in
                    appState.speechModel = speechModelID
                    Task {
                        await appState.loadSpeechModel(name: speechModelID)
                    }
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
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedSection == section ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.22) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    selectedSection == section
                                        ? Color(nsColor: .separatorColor)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                Spacer(minLength: 0)
            }
            .frame(minWidth: 250, idealWidth: 270, maxWidth: 270, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }

            ScrollView {
                detailContent
                    .padding(.horizontal, 40)
                    .padding(.vertical, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 900, minHeight: 680)
        .onAppear {
            inputDevices = AudioDeviceManager.listInputDevices()
            selectedDeviceID = AudioDeviceManager.defaultInputDeviceID() ?? 0
            refreshScreenRecordingPermission()
            refreshRequiredPermissions()
            startPermissionPollingIfNeeded()
            syncTranscriptionLabRerunDefaults()
            transcriptionLabController.reloadEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreenRecordingPermission()
            refreshRequiredPermissions()
        }
        .onChange(of: selectedSection) { _, newSection in
            if newSection == .transcriptionLab {
                syncTranscriptionLabRerunDefaults()
                transcriptionLabController.reloadEntries()
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
            cleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind
        )
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

            switch selectedSection {
            case .recording:
                recordingSection
            case .cleanup:
                cleanupSection
            case .corrections:
                correctionsSection
            case .models:
                modelsSection
            case .transcriptionLab:
                transcriptionLabSection
            case .pepperChat:
                pepperChatSection
            case .general:
                generalSection
            }

            Spacer(minLength: 0)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !hasAccessibilityPermission || !hasInputMonitoringPermission {
                SettingsCard("Permissions") {
                    VStack(alignment: .leading, spacing: 12) {
                        PermissionStatusRow(
                            title: "Accessibility",
                            isGranted: hasAccessibilityPermission,
                            action: { PermissionChecker.promptAccessibility() }
                        )
                        PermissionStatusRow(
                            title: "Input Monitoring",
                            isGranted: hasInputMonitoringPermission,
                            action: {
                                PermissionChecker.promptInputMonitoring()
                                PermissionChecker.openInputMonitoringSettings()
                            }
                        )

                        Text("Both permissions are required for hotkeys and pasting to work reliably. If Ghost Pepper doesn't appear in Input Monitoring, click + and select it from Applications.")
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
                        Picker("Microphone", selection: $selectedDeviceID) {
                            ForEach(inputDevices) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                        .onChange(of: selectedDeviceID) { _, newValue in
                            _ = AudioDeviceManager.setDefaultInputDevice(newValue)
                        }
                    }

                    Toggle(
                        "Play sounds",
                        isOn: Binding(
                            get: { appState.playSounds },
                            set: { appState.playSounds = $0 }
                        )
                    )

                    Toggle(
                        "Pause media while recording",
                        isOn: Binding(
                            get: { appState.pauseMediaWhileRecording },
                            set: { appState.pauseMediaWhileRecording = $0 }
                        )
                    )

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

    private var correctionsSection: some View {
        SettingsCard("Corrections") {
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
                    prompt: "One replacement per line using probably wrong -> probably right"
                )

                Text("Preferred transcriptions are preserved in cleanup and forwarded into OCR custom words. Commonly misheard replacements run deterministically before cleanup.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                        ForEach(TextCleanupManager.cleanupModels, id: \.kind) { model in
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

            SettingsCard("Runtime models") {
                VStack(alignment: .leading, spacing: 16) {
                    ModelInventoryCard(rows: modelRows)

                    if let activeDownloadText = RuntimeModelInventory.activeDownloadText(rows: modelRows) {
                        Text(activeDownloadText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                }
            }
        }
    }

    private var transcriptionLabSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let selectedEntry = transcriptionLabController.selectedEntry {
                transcriptionLabDetail(for: selectedEntry)
            } else {
                transcriptionLabBrowser
            }
        }
    }

    private var transcriptionLabBrowser: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent recordings")
                .font(.title3.weight(.semibold))

            if transcriptionLabController.entries.isEmpty {
                ContentUnavailableView(
                    "No Saved Recordings",
                    systemImage: "waveform",
                    description: Text("Make a few dictations in Ghost Pepper and they will appear here.")
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(transcriptionLabController.entries) { entry in
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
                        }
                    }
                }
            }
        }
    }

    private func transcriptionLabDetail(for entry: TranscriptionLabEntry) -> some View {
        let canPlayRecording = transcriptionLabController.audioURL(for: entry).pathExtension.lowercased() == "wav"
        let originalSpeechModelName = SpeechModelCatalog.model(named: entry.speechModelID)?.pickerLabel ?? entry.speechModelID

        return VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    transcriptionLabController.closeDetail()
                } label: {
                    Label("Back to recordings", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("Audio recording")
                    .font(.title3.weight(.semibold))

                TranscriptionLabMetadataSummary(entry: entry)

                if let diarizationVisualization = transcriptionLabController.diarizationVisualization {
                    TranscriptionLabDiarizationSummaryView(visualization: diarizationVisualization)
                }

                HStack(alignment: .center, spacing: 12) {
                    Button {
                        playTranscriptionLabAudio(for: entry)
                    } label: {
                        Label("Play recording", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canPlayRecording)

                    if !canPlayRecording {
                        Text("Playback is available for newly archived recordings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("Transcription")
                    .font(.title3.weight(.semibold))

                HStack(alignment: .center, spacing: 12) {
                    Text("Originally transcribed with \(originalSpeechModelName)")
                        .font(.subheadline.weight(.medium))

                    Spacer()

                    Text(formattedOriginalStageDuration(transcriptionLabController.originalTranscriptionDuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ReadOnlyTextPane(
                    text: entry.rawTranscription ?? "No transcription was captured for this recording.",
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )

                HStack(alignment: .center, spacing: 12) {
                    Text("Use transcription model")
                        .font(.subheadline.weight(.medium))

                    Picker("Speech Model", selection: $transcriptionLabController.selectedSpeechModelID) {
                        ForEach(ModelManager.availableModels) { model in
                            Text(model.pickerLabel).tag(model.name)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300, alignment: .leading)

                    Button {
                        Task {
                            await transcriptionLabController.rerunTranscription()
                        }
                    } label: {
                        HStack {
                            if transcriptionLabController.isRunningTranscription {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.trianglehead.clockwise")
                            }
                            Text(transcriptionLabController.isRunningTranscription ? "Running..." : "Run transcription")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(transcriptionLabController.runningStage != nil)

                    Spacer()

                    if let duration = transcriptionLabController.experimentTranscriptionDuration {
                        Text(formattedStageDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DiffReadOnlyTextPane(
                    originalText: entry.rawTranscription ?? "",
                    text: transcriptionLabController.displayedExperimentRawTranscription,
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("Cleanup")
                    .font(.title3.weight(.semibold))

                HStack(alignment: .center, spacing: 12) {
                    Text("Originally cleaned with \(entry.cleanupModelName)")
                        .font(.subheadline.weight(.medium))

                    Spacer()

                    Text(formattedOriginalStageDuration(transcriptionLabController.originalCleanupDuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ReadOnlyTextPane(
                    text: entry.correctedTranscription ?? "No corrected output was captured for this recording.",
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 12) {
                        Text("Cleanup prompt")
                            .font(.subheadline.weight(.medium))

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

                    Spacer()
                }

                HStack(alignment: .center, spacing: 12) {
                    Text("Clean with")
                        .font(.subheadline.weight(.medium))

                    Picker("Cleanup model", selection: $transcriptionLabController.selectedCleanupModelKind) {
                        ForEach(TextCleanupManager.cleanupModels, id: \.kind) { model in
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

                    Button {
                        Task {
                            await transcriptionLabController.rerunCleanup(prompt: appState.cleanupPrompt)
                        }
                    } label: {
                        HStack {
                            if transcriptionLabController.isRunningCleanup {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.trianglehead.clockwise")
                            }
                            Text(transcriptionLabController.isRunningCleanup ? "Running..." : "Run cleanup")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(transcriptionLabController.runningStage != nil)

                    Spacer()

                    if let duration = transcriptionLabController.experimentCleanupDuration {
                        Text(formattedStageDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                DiffReadOnlyTextPane(
                    originalText: entry.correctedTranscription ?? "",
                    text: transcriptionLabController.displayedExperimentCorrectedTranscription,
                    minimumHeight: 60,
                    maximumHeight: 140,
                    monospaced: false
                )

                if let errorMessage = transcriptionLabController.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @State private var pepperChatTestResult: String?

    private var pepperChatSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsCard("Shortcut") {
                ShortcutRecorderView(
                    title: "Pepper Chat (hold to speak)",
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
        }
    }

    private var generalSection: some View {
        SettingsCard("General") {
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
    let visualization: TranscriptionLabController.DiarizationVisualization

    private var totalDuration: TimeInterval {
        max(
            visualization.audioDuration,
            visualization.spans.map(\.endTime).max() ?? 0
        )
    }

    private var summaryText: String {
        if visualization.usedFallback {
            if let fallbackReason = visualization.fallbackReason {
                return "Speaker filtering fell back to the full recording (\(fallbackReasonText(for: fallbackReason)))."
            }

            return "Speaker filtering fell back to the full recording."
        }

        if let targetSpeakerID = visualization.targetSpeakerID {
            return "Kept \(formattedDuration(visualization.keptAudioDuration)) from \(targetSpeakerID)."
        }

        return "Speaker filtering ran without a target speaker."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Text("Speaker filtering")
                    .font(.subheadline.weight(.medium))

                Spacer()

                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(Array(visualization.spans.enumerated()), id: \.offset) { _, span in
                        Rectangle()
                            .fill(
                                span.isKept
                                ? Color.accentColor
                                : Color(nsColor: .quaternaryLabelColor)
                            )
                            .frame(width: segmentWidth(for: span, totalWidth: geometry.size.width))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(height: 8)
            .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )

            HStack(alignment: .center, spacing: 12) {
                if let targetSpeakerID = visualization.targetSpeakerID {
                    Text("Target: \(targetSpeakerID)")
                }

                Text("Kept \(formattedDuration(visualization.keptAudioDuration))")

                if visualization.usedFallback {
                    Text("Used fallback")
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

    private func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.1fs", duration)
    }

    private func fallbackReasonText(for reason: DiarizationSummary.FallbackReason) -> String {
        switch reason {
        case .noUsableSpeakerSpans:
            return "no usable speaker spans"
        case .noSpeakerReachedThreshold:
            return "no speaker reached the selection threshold"
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
