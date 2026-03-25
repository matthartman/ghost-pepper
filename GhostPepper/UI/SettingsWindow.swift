import SwiftUI
import AppKit
import CoreAudio
import ServiceManagement
import AVFoundation

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

// MARK: - Mic Level Monitor for Settings

protocol MicLevelMonitoring: AnyObject {
    func start()
    func stop()
    func restart()
}

@MainActor
class SettingsMicMonitor: ObservableObject, MicLevelMonitoring {
    @Published var level: Float = 0
    private var engine: AVAudioEngine?
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        guard PermissionChecker.microphoneStatus() == .authorized else { return }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frames {
                let sample = channelData[0][i]
                sum += sample * sample
            }
            let rms = sqrtf(sum / Float(max(frames, 1)))
            let normalized = min(rms * 10, 1.0)
            Task { @MainActor [weak self] in
                self?.level = normalized
            }
        }

        do {
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {}
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }

    func restart() {
        stop()
        start()
    }
}

@MainActor
final class MicPreviewController: ObservableObject {
    @Published private(set) var isPreviewing = false

    private let monitor: MicLevelMonitoring

    init(monitor: MicLevelMonitoring) {
        self.monitor = monitor
    }

    func setPreviewing(_ previewing: Bool) {
        guard previewing != isPreviewing else { return }

        isPreviewing = previewing
        if previewing {
            monitor.start()
        } else {
            monitor.stop()
        }
    }

    func restartIfNeeded() {
        guard isPreviewing else { return }
        monitor.restart()
    }
}

// MARK: - Settings View

private enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case cleanup
    case corrections
    case models
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording: "Recording"
        case .cleanup: "Cleanup"
        case .corrections: "Corrections"
        case .models: "Models"
        case .general: "General"
        }
    }

    var subtitle: String {
        switch self {
        case .recording: "Shortcuts, microphone input, live preview, and sound feedback."
        case .cleanup: "Prompt cleanup, OCR context, and learning behavior."
        case .corrections: "Words and replacements Ghost Pepper should preserve."
        case .models: "Speech and cleanup model downloads and runtime status."
        case .general: "Startup behavior and app-wide preferences."
        }
    }

    var systemImageName: String {
        switch self {
        case .recording: "waveform.and.mic"
        case .cleanup: "sparkles"
        case .corrections: "text.badge.checkmark"
        case .models: "brain"
        case .general: "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    @State private var selectedSection: SettingsSection? = .recording
    @StateObject private var micMonitor: SettingsMicMonitor
    @StateObject private var micPreviewController: MicPreviewController

    init(appState: AppState) {
        self.appState = appState
        let micMonitor = SettingsMicMonitor()
        _micMonitor = StateObject(wrappedValue: micMonitor)
        _micPreviewController = StateObject(wrappedValue: MicPreviewController(monitor: micMonitor))
    }

    private var modelRows: [RuntimeModelRow] {
        RuntimeModelInventory.rows(
            selectedSpeechModelName: appState.speechModel,
            activeSpeechModelName: appState.modelManager.modelName,
            speechModelState: appState.modelManager.state,
            cachedSpeechModelNames: appState.modelManager.cachedModelNames,
            cleanupState: appState.textCleanupManager.state,
            loadedCleanupKinds: appState.textCleanupManager.loadedModelKinds
        )
    }

    private var hasMissingModels: Bool {
        RuntimeModelInventory.hasMissingModels(rows: modelRows)
    }

    private var modelsAreDownloading: Bool {
        RuntimeModelInventory.activeDownloadText(rows: modelRows) != nil
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImageName)
                    .tag(Optional(section))
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
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
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshScreenRecordingPermission()
        }
        .onDisappear {
            micPreviewController.setPreviewing(false)
        }
    }

    private func refreshScreenRecordingPermission() {
        hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    }

    private func downloadMissingModels() async {
        let selectedSpeechModelName = appState.speechModel
        let missingSpeechModels = ModelManager.availableModels
            .map(\.name)
            .filter { !appState.modelManager.cachedModelNames.contains($0) }

        for modelName in missingSpeechModels {
            await appState.modelManager.loadModel(name: modelName)
        }

        if appState.modelManager.modelName != selectedSpeechModelName || !appState.modelManager.isReady {
            await appState.modelManager.loadModel(name: selectedSpeechModelName)
        }

        if appState.textCleanupManager.loadedModelKinds.count < TextCleanupManager.cleanupModels.count {
            await appState.textCleanupManager.loadModel()
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selectedSection {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedSection.title)
                        .font(.system(size: 28, weight: .semibold))
                    Text(selectedSection.subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                case .general:
                    generalSection
                }

                Spacer(minLength: 0)
            }
        } else {
            EmptyView()
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 24) {
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
                            AudioDeviceManager.setDefaultInputDevice(newValue)
                            micPreviewController.restartIfNeeded()
                        }
                    }

                    SettingsField("Speech Model") {
                        Picker("Speech Model", selection: $appState.speechModel) {
                            ForEach(ModelManager.availableModels) { model in
                                Text(model.pickerLabel).tag(model.name)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 320, alignment: .leading)
                        .onChange(of: appState.speechModel) { _, newModel in
                            Task {
                                await appState.modelManager.loadModel(name: newModel)
                            }
                        }
                    }

                    Toggle(
                        "Live mic level preview",
                        isOn: Binding(
                            get: { micPreviewController.isPreviewing },
                            set: { micPreviewController.setPreviewing($0) }
                        )
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "mic.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(micMonitor.level > 0.7 ? .red : micMonitor.level > 0.3 ? .orange : .green)
                                        .frame(width: geo.size.width * CGFloat(micMonitor.level))
                                        .animation(.easeOut(duration: 0.08), value: micMonitor.level)
                                }
                            }
                            .frame(height: 10)

                            Text("Level")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 420)

                        Text("Microphone preview is off by default so Ghost Pepper only keeps the mic active while recording or while you explicitly preview levels here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Toggle(
                        "Play sounds",
                        isOn: Binding(
                            get: { appState.playSounds },
                            set: { appState.playSounds = $0 }
                        )
                    )
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
                        SettingsField("Cleanup model") {
                            Picker(
                                "Cleanup model",
                                selection: Binding(
                                    get: { appState.textCleanupManager.localModelPolicy },
                                    set: { appState.textCleanupManager.localModelPolicy = $0 }
                                )
                            ) {
                                ForEach(LocalCleanupModelPolicy.allCases) { policy in
                                    Text(policy.title).tag(policy)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 320, alignment: .leading)
                        }

                        Button("Edit Cleanup Prompt...") {
                            appState.showPromptEditor()
                        }

                        if appState.textCleanupManager.state == .error {
                            Text(appState.textCleanupManager.errorMessage ?? "Error loading model")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Text("When enabled, Ghost Pepper cleans up your transcriptions with the selected local model policy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        SettingsCard("Runtime models") {
            VStack(alignment: .leading, spacing: 16) {
                ModelInventoryCard(rows: modelRows)

                if let activeDownloadText = RuntimeModelInventory.activeDownloadText(rows: modelRows) {
                    Text(activeDownloadText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if hasMissingModels {
                    Button {
                        Task {
                            await downloadMissingModels()
                        }
                    } label: {
                        HStack {
                            if modelsAreDownloading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                            Text(modelsAreDownloading ? "Downloading Models..." : "Download Missing Models")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(modelsAreDownloading)
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
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3.weight(.semibold))

            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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

private struct CorrectionsEditor: View {
    let title: String
    let text: Binding<String>
    let prompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))

            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72)

            Text(prompt)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
