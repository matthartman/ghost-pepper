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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ghost Pepper Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false
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
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
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

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var hasScreenRecordingPermission = PermissionChecker.hasScreenRecordingPermission()
    @StateObject private var micMonitor: SettingsMicMonitor
    @StateObject private var micPreviewController: MicPreviewController

    init(appState: AppState) {
        self.appState = appState
        let micMonitor = SettingsMicMonitor()
        _micMonitor = StateObject(wrappedValue: micMonitor)
        _micPreviewController = StateObject(wrappedValue: MicPreviewController(monitor: micMonitor))
    }

    var body: some View {
        Form {
            Section {
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
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Push to talk records while the hold chord stays down. Toggle recording starts and stops when you press the full toggle chord.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input") {
                Picker("Microphone", selection: $selectedDeviceID) {
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .onChange(of: selectedDeviceID) { _, newValue in
                    AudioDeviceManager.setDefaultInputDevice(newValue)
                    micPreviewController.restartIfNeeded()
                }

                Toggle(
                    "Live mic level preview",
                    isOn: Binding(
                        get: { micPreviewController.isPreviewing },
                        set: { micPreviewController.setPreviewing($0) }
                    )
                )

                // Mic level meter
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(nsColor: .controlBackgroundColor))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(micMonitor.level > 0.7 ? .red : micMonitor.level > 0.3 ? .orange : .green)
                                .frame(width: geo.size.width * CGFloat(micMonitor.level))
                                .animation(.easeOut(duration: 0.08), value: micMonitor.level)
                        }
                    }
                    .frame(height: 8)

                    Text("Level")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("Microphone preview is off by default so Ghost Pepper only keeps the mic active while recording or while you explicitly preview levels here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Enable cleanup",
                    isOn: Binding(
                        get: { appState.cleanupEnabled },
                        set: { appState.setCleanupEnabled($0) }
                    )
                )

                if appState.cleanupEnabled {
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

                    Button("Edit Cleanup Prompt...") {
                        appState.showPromptEditor()
                    }

                    if appState.textCleanupManager.state == .error {
                        Text(appState.textCleanupManager.errorMessage ?? "Error loading model")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Cleanup")
            } footer: {
                Text("When enabled, Ghost Pepper cleans up your transcriptions with the selected local model policy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
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
            } header: {
                Text("Context")
            } footer: {
                Text("Ghost Pepper uses high-quality OCR on the frontmost window and adds the result to the cleanup prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
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

                CorrectionsEditor(
                    title: "Preferred transcriptions",
                    text: Binding(
                        get: { appState.correctionStore.preferredTranscriptionsText },
                        set: { appState.correctionStore.preferredTranscriptionsText = $0 }
                    ),
                    prompt: "One preferred word or phrase per line"
                )

                CorrectionsEditor(
                    title: "Commonly misheard",
                    text: Binding(
                        get: { appState.correctionStore.commonlyMisheardText },
                        set: { appState.correctionStore.commonlyMisheardText = $0 }
                    ),
                    prompt: "One replacement per line using probably wrong -> probably right"
                )
            } header: {
                Text("Corrections")
            } footer: {
                Text("Preferred transcriptions are preserved in cleanup and forwarded into OCR custom words. Commonly misheard replacements run deterministically before cleanup. When learning is enabled, Ghost Pepper does a high-quality OCR check about 15 seconds after paste and only keeps narrow, high-confidence corrections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
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
            Section {
                ModelStatusRow(
                    name: "WhisperKit (speech-to-text)",
                    isLoaded: appState.modelManager.isReady
                )
                ModelStatusRow(
                    name: "Qwen 2.5 1.5B (fast cleanup)",
                    isLoaded: appState.textCleanupManager.fastLLM != nil
                )
                ModelStatusRow(
                    name: "Qwen 2.5 3B (full cleanup)",
                    isLoaded: appState.textCleanupManager.fullLLM != nil
                )

                if !appState.modelManager.isReady || appState.textCleanupManager.fastLLM == nil || appState.textCleanupManager.fullLLM == nil {
                    Button {
                        Task {
                            if !appState.modelManager.isReady {
                                await appState.modelManager.loadModel()
                            }
                            if appState.textCleanupManager.fastLLM == nil || appState.textCleanupManager.fullLLM == nil {
                                await appState.textCleanupManager.loadModel()
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("Download Missing Models")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
            } header: {
                Text("Models")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 700)
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

struct ModelStatusRow: View {
    let name: String
    let isLoaded: Bool

    var body: some View {
        HStack {
            Text(name)
                .font(.callout)
            Spacer()
            if isLoaded {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text("Not loaded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
