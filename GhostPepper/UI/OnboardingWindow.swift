// GhostPepper/UI/OnboardingWindow.swift
import SwiftUI
import AppKit
import AVFoundation
import CoreAudio

// MARK: - Mic Level Monitor

@MainActor
class MicLevelMonitor: ObservableObject {
    @Published var level: Float = 0
    private var engine: AVAudioEngine?
    private var isRunning = false

    func start(deviceID: AudioDeviceID? = nil) {
        guard !isRunning else { return }
        // Only start if mic permission is already granted
        guard PermissionChecker.microphoneStatus() == .authorized else { return }
        let engine = AVAudioEngine()

        if let deviceID {
            let audioUnit = engine.inputNode.audioUnit!
            var targetDeviceID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &targetDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { return }
        }

        let inputNode = engine.inputNode
        let format = inputNode.inputFormat(forBus: 0)
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
            // Normalize to 0-1 range (RMS of speech is typically 0.01-0.1)
            let normalized = min(rms * 10, 1.0)
            Task { @MainActor [weak self] in
                self?.level = normalized
            }
        }

        do {
            try engine.start()
            self.engine = engine
            isRunning = true
        } catch {
            // Silently fail — mic level is not critical
        }
    }

    func stop() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
        level = 0
    }
}

// MARK: - Window Controller

class OnboardingWindowController {
    private var window: NSWindow?

    func show(appState: AppState, onComplete: @escaping () -> Void) {
        dismiss()

        // Show in dock/Cmd+Tab during onboarding
        NSApp.setActivationPolicy(.regular)

        // Delay slightly to let activation policy take effect
        DispatchQueue.main.async {
            let onboardingView = OnboardingView(appState: appState, onComplete: { [weak self] in
                self?.dismiss()
                onComplete()
            })

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 620),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Ghost Pepper"
            window.contentView = NSHostingView(rootView: onboardingView)
            window.center()
            window.level = .normal
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            self.window = window
        }
    }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}

// MARK: - Main Onboarding View

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onComplete: () -> Void
    @State private var currentStep = 1

    private var completionStep: Int {
        GranolaImporter.isInstalled ? 5 : 4
    }

    var body: some View {
        VStack {
            switch currentStep {
            case 1:
                WelcomeStep(onContinue: { currentStep = 2 })
            case 2:
                SetupStep(appState: appState, modelManager: appState.modelManager, onContinue: { currentStep = 3 })
            case 3:
                TryItStep(appState: appState, onContinue: {
                    currentStep = GranolaImporter.isInstalled ? 4 : completionStep
                })
            case 4:
                if GranolaImporter.isInstalled {
                    GranolaOnboardingStep(onContinue: { currentStep = completionStep })
                } else {
                    DoneStep(onComplete: completeOnboarding)
                }
            case 5:
                DoneStep(onComplete: completeOnboarding)
            default:
                EmptyView()
            }
        }
        .frame(width: 480, height: 620)
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingCompleted")
        onComplete()
    }
}

// MARK: - Step 1: Welcome

struct WelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .cornerRadius(24)

            Text("Ghost Pepper")
                .font(.system(size: 28, weight: .bold))

            Text("Sovereign personal intelligence\nfor your Mac")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("All open-source models. Voice-to-text, meeting transcription, your second brain, and Q&A run under your control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.orange)
                    Text("No accounts required. Your notes, transcripts, and wiki stay on this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green.opacity(0.08))
                    .strokeBorder(Color.green.opacity(0.2))
            )
            .padding(.horizontal, 24)

            Spacer()

            Button(action: onContinue) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Step 2: Setup

struct SetupStep: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelManager: ModelManager
    let onContinue: () -> Void

    @State private var micGranted = false
    @State private var micDenied = false
    @State private var accessibilityGranted = false
    @State private var permissionTimer: Timer?
    @State private var localIntelligenceLoadStarted = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @StateObject private var micLevel = MicLevelMonitor()
    @StateObject private var screenRecordingPermission = ScreenRecordingPermissionController()

    private var allComplete: Bool {
        micGranted && accessibilityGranted && localIntelligenceReady
    }

    private var secondBrainModelReady: Bool {
        appState.textCleanupManager.cachedModelKinds.contains(appState.selectedWikiModelKind)
    }

    private var localIntelligenceReady: Bool {
        modelManager.isReady && secondBrainModelReady
    }

    private var localIntelligenceStatus: String {
        if modelManager.state == .error || appState.textCleanupManager.state == .error {
            return "Download failed"
        }

        if let activeDownload = RuntimeModelInventory.activeDownloadText(rows: modelRows) {
            return activeDownload
        }

        if modelManager.isReady && secondBrainModelReady {
            return "Ready for dictation, meetings, wiki, and Q&A"
        }

        return "Downloading the local models Ghost Pepper needs"
    }

    private var modelRows: [RuntimeModelRow] {
        RuntimeModelInventory.rows(
            selectedSpeechModelName: appState.speechModel,
            activeSpeechModelName: modelManager.modelName,
            speechModelState: modelManager.state,
            speechDownloadProgress: modelManager.downloadProgress,
            cachedSpeechModelNames: modelManager.cachedModelNames,
            cleanupState: appState.textCleanupManager.state,
            selectedCleanupModelKind: appState.textCleanupManager.selectedCleanupModelKind,
            selectedWikiModelKind: appState.selectedWikiModelKind,
            cachedCleanupKinds: appState.textCleanupManager.cachedModelKinds
        )
    }

    private var secondBrainModelRow: RuntimeModelRow? {
        guard let descriptor = TextCleanupManager.cleanupModels.first(where: { $0.kind == appState.selectedWikiModelKind }) else {
            return nil
        }
        return modelRows.first(where: { $0.id == "cleanup-\(descriptor.fileName)" })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Setup 🌶️")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)
                .padding(.bottom, 8)

            Text("Grant permissions. Ghost Pepper chooses the local models.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)

            ScrollView {
            VStack(spacing: 10) {
                SetupRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    subtitle: "To hear your voice",
                    isComplete: micGranted
                ) {
                    if micDenied {
                        Button("Open Settings") {
                            PermissionChecker.openMicrophoneSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    } else if !micGranted {
                        Button("Grant") {
                            Task {
                                let granted = await PermissionChecker.checkMicrophone()
                                micGranted = granted
                                if granted {
                                    inputDevices = AudioDeviceManager.listInputDevices()
                                    selectedDeviceID = AudioDeviceManager.selectedInputDeviceID() ?? AudioDeviceManager.defaultInputDeviceID() ?? 0
                                    micLevel.start(deviceID: selectedDeviceID == 0 ? nil : selectedDeviceID)
                                } else {
                                    micDenied = true
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }

                if micGranted {
                    VStack(spacing: 8) {
                        if inputDevices.count > 1 {
                            Picker("Input Device", selection: $selectedDeviceID) {
                                ForEach(inputDevices) { device in
                                    Text(device.name).tag(device.id)
                                }
                            }
                            .onChange(of: selectedDeviceID) { _, newValue in
                                AudioDeviceManager.setSelectedInputDevice(newValue)
                                // Restart level monitor for new device
                                micLevel.stop()
                                micLevel.start(deviceID: newValue == 0 ? nil : newValue)
                            }
                        }

                        // Sound level meter
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(micLevel.level > 0.7 ? .red : micLevel.level > 0.3 ? .orange : .green)
                                        .frame(width: geo.size.width * CGFloat(micLevel.level))
                                        .animation(.easeOut(duration: 0.08), value: micLevel.level)
                                }
                            }
                            .frame(height: 8)

                            Text("Sound check")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 4)
                }

                SetupRow(
                    icon: "keyboard.fill",
                    title: "Accessibility",
                    subtitle: "For keyboard shortcuts & pasting",
                    isComplete: accessibilityGranted
                ) {
                    if !accessibilityGranted {
                        Button("Grant") {
                            PermissionChecker.openAccessibilitySettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }

                SetupRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording (optional)",
                    subtitle: "Enhances cleanup by reading on-screen text (never leaves your computer)",
                    isComplete: screenRecordingPermission.isGranted
                ) {
                    if !screenRecordingPermission.isGranted {
                        Button("Enable") {
                            screenRecordingPermission.requestAccess()
                            PermissionChecker.openScreenRecordingSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if !screenRecordingPermission.isGranted {
                    Text("You can enable this later in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                VStack(spacing: 8) {
                    SetupRow(
                        icon: "brain",
                        title: "Local Intelligence",
                        subtitle: localIntelligenceStatus,
                        isComplete: localIntelligenceReady
                    ) {
                        if modelManager.state == .loading || appState.textCleanupManager.state.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else if modelManager.state == .error || appState.textCleanupManager.state == .error {
                            Button("Retry") {
                                Task { await loadRequiredLocalModels() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                    }

                    OnboardingModelSummary(
                        speechModelRow: modelRows.first(where: { $0.isSelected }),
                        secondBrainModelRow: secondBrainModelRow
                    )
                }
            }
            .padding(.horizontal, 24)
            }

            Spacer(minLength: 8)

            if allComplete {
                Button(action: {
                    stopPermissionPolling()
                    onContinue()
                }) {
                    Text("Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            } else {
                Button(action: {
                    let tweet = "Trying out Ghost Pepper 🌶️ and liking it so far."
                    let encoded = tweet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "https://twitter.com/intent/tweet?text=\(encoded)") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("📣 Share Ghost Pepper")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            let microphoneStatus = PermissionChecker.microphoneStatus()
            micGranted = microphoneStatus == .authorized
            micDenied = microphoneStatus == .denied
            accessibilityGranted = PermissionChecker.checkAccessibility()

            if micGranted {
                inputDevices = AudioDeviceManager.listInputDevices()
                selectedDeviceID = AudioDeviceManager.selectedInputDeviceID() ?? AudioDeviceManager.defaultInputDeviceID() ?? 0
                micLevel.start(deviceID: selectedDeviceID == 0 ? nil : selectedDeviceID)
            }

            if !localIntelligenceLoadStarted && !localIntelligenceReady {
                localIntelligenceLoadStarted = true
                Task { await loadRequiredLocalModels() }
            }

            startPermissionPolling()
        }
        .onDisappear {
            stopPermissionPolling()
            micLevel.stop()
        }
    }

    private func startPermissionPolling() {
        guard permissionTimer == nil else { return }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            let accessibilityGrantedNow = PermissionChecker.checkAccessibility()
            if accessibilityGrantedNow {
                accessibilityGranted = true
            }

            screenRecordingPermission.refresh()

            if accessibilityGrantedNow && screenRecordingPermission.isGranted {
                stopPermissionPolling()
            }
        }
    }

    private func stopPermissionPolling() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    private func loadRequiredLocalModels() async {
        await modelManager.loadModel()
        await appState.textCleanupManager.loadModel(kind: appState.selectedWikiModelKind)
    }
}

private extension CleanupModelState {
    var isLoading: Bool {
        switch self {
        case .downloading, .loadingModel:
            return true
        case .idle, .ready, .error:
            return false
        }
    }
}

struct SetupRow<Actions: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let isComplete: Bool
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 32)
                .foregroundStyle(isComplete ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                actions()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct OnboardingModelSummary: View {
    let speechModelRow: RuntimeModelRow?
    let secondBrainModelRow: RuntimeModelRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let row = speechModelRow {
                OnboardingModelRow(label: "Voice", name: row.name, size: row.sizeDescription, status: row.status)
            }
            if let row = secondBrainModelRow {
                OnboardingModelRow(label: "Brain", name: row.name, size: row.sizeDescription, status: row.status)
            }

            Text("Ghost Pepper picks these during onboarding. Advanced model controls live in Settings.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private struct OnboardingModelRow: View {
    let label: String
    let name: String
    let size: String
    let status: RuntimeModelStatus

    var body: some View {
        HStack(spacing: 8) {
            statusIndicator
                .frame(width: 14, height: 14)

            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)

            Text(name)
                .font(.caption)
                .lineLimit(1)

            Spacer()

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch status {
        case .loaded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .loading:
            ProgressView()
                .controlSize(.mini)
        case .downloading(let progress):
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        case .notLoaded:
            Image(systemName: "circle")
                .foregroundStyle(.quaternary)
                .font(.caption)
        case .systemManaged:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }

    private var statusText: String {
        switch status {
        case .loaded: "Ready"
        case .loading: "Loading..."
        case .downloading(let progress?): "Downloading \(Int(progress * 100))%"
        case .downloading(nil): "Preparing..."
        case .notLoaded: size
        case .systemManaged: "Managed by macOS"
        }
    }
}

// MARK: - Step 3: Try It

@MainActor
class TryItController: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcribedText: String?
    @Published var statusMessage = "Waiting for you to hold Right Command + Right Option..."
    @Published var monitorStartFailed = false

    private var hotkeyMonitor: HotkeyMonitoring?
    private var audioRecorder: AudioRecorder?
    private var hasAdvanced = false
    private var retryCount = 0
    private let maxRetries = 5
    private let transcriber: SpeechTranscriber
    private let hotkeyMonitorFactory: ([ChordAction: KeyChord]) -> HotkeyMonitoring

    init(
        transcriber: SpeechTranscriber,
        hotkeyMonitorFactory: @escaping ([ChordAction: KeyChord]) -> HotkeyMonitoring = { bindings in
            HotkeyMonitor(bindings: bindings)
        }
    ) {
        self.transcriber = transcriber
        self.hotkeyMonitorFactory = hotkeyMonitorFactory
    }

    func start(onAdvance: @escaping () -> Void) {
        let recorder = AudioRecorder()
        recorder.targetDeviceID = AudioDeviceManager.selectedInputDeviceID()
        recorder.prewarm()
        self.audioRecorder = recorder

        let monitor = hotkeyMonitorFactory([
            .pushToTalk: AppState.defaultPushToTalkChord
        ])
        monitor.onRecordingStart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.statusMessage = ""
                self.isRecording = true
                try? recorder.startRecording()
            }
        }
        monitor.onRecordingStop = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.isTranscribing = true
                let buffer = await recorder.stopRecording()
                let text = await self.transcriber.transcribe(audioBuffer: buffer)
                self.isTranscribing = false
                if let text {
                    self.transcribedText = text
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        self?.advance(onAdvance: onAdvance)
                    }
                } else {
                    self.statusMessage = "No speech detected. Check the selected microphone and try again."
                }
            }
        }

        if monitor.start() {
            self.hotkeyMonitor = monitor
        } else {
            retryStartMonitor(monitor: monitor)
        }
    }

    func advance(onAdvance: () -> Void) {
        guard !hasAdvanced else { return }
        hasAdvanced = true
        cleanup()
        onAdvance()
    }

    func cleanup() {
        hotkeyMonitor?.stop()
        hotkeyMonitor = nil
        audioRecorder = nil
    }

    private func retryStartMonitor(monitor: HotkeyMonitoring) {
        guard retryCount < maxRetries else {
            monitorStartFailed = true
            return
        }
        retryCount += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if monitor.start() {
                self?.hotkeyMonitor = monitor
            } else {
                self?.retryStartMonitor(monitor: monitor)
            }
        }
    }
}

struct TryItStep: View {
    @ObservedObject var appState: AppState
    let onContinue: () -> Void
    @StateObject private var controller: TryItController

    init(appState: AppState, onContinue: @escaping () -> Void) {
        self.appState = appState
        self.onContinue = onContinue
        self._controller = StateObject(wrappedValue: TryItController(transcriber: appState.transcriber))
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Try It")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)

            Text("Hold **Right Command + Right Option** and say something")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                KeyCap(label: "⌘ right", highlighted: true, isActive: controller.isRecording)
                KeyCap(label: "⌥ right", highlighted: true, isActive: controller.isRecording)
            }
            .padding(.vertical, 8)

            VStack(spacing: 12) {
                if controller.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                        Text("Recording...")
                            .foregroundStyle(.secondary)
                    }
                } else if controller.isTranscribing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Transcribing...")
                            .foregroundStyle(.secondary)
                    }
                } else if let text = controller.transcribedText {
                    VStack(spacing: 8) {
                        Text("\"\(text)\"")
                            .font(.body)
                            .italic()
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                            )
                            .padding(.horizontal, 24)

                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("It works! Your words will be pasted wherever your cursor is.")
                                .font(.callout)
                                .foregroundStyle(.green)
                        }
                    }
                } else if controller.monitorStartFailed {
                    Text("Could not start hotkey monitor.\nPlease verify Accessibility is enabled in System Settings.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                } else {
                    Text(controller.statusMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 100)

            Spacer()

            HStack {
                Button("Skip") {
                    controller.advance(onAdvance: onContinue)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(action: {
                    controller.advance(onAdvance: onContinue)
                }) {
                    Text("Continue")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .onAppear { controller.start(onAdvance: onContinue) }
        .onDisappear { controller.cleanup() }
    }
}

struct KeyCap: View {
    let label: String
    let highlighted: Bool
    var isActive: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: highlighted ? .semibold : .regular))
            .foregroundStyle(highlighted ? .white : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(highlighted
                        ? (isActive ? Color.red : Color.orange)
                        : Color(nsColor: .controlBackgroundColor))
            )
            .animation(.easeInOut(duration: 0.2), value: isActive)
    }
}

// MARK: - Step 4: Granola Import

struct GranolaOnboardingStep: View {
    let onContinue: () -> Void
    @StateObject private var importer = GranolaImporter()
    @StateObject private var meetingState = MeetingWindowState()
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 46))
                .foregroundStyle(.orange)

            Text("Bring in Granola")
                .font(.system(size: 28, weight: .bold))

            Text("Ghost Pepper found Granola on this Mac. Import your past meetings to seed the second brain you control.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 42)

            VStack(alignment: .leading, spacing: 8) {
                BulletPoint("Turn existing meeting notes into local markdown")
                BulletPoint("Use them for wiki generation and private Q&A")
                BulletPoint("Keep the archive on your machine")
            }
            .padding(.horizontal, 48)

            Spacer()

            Button(action: { showImporter = true }) {
                Text("Import Granola Meetings")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal, 40)

            Button("Skip for Now") {
                onContinue()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.bottom, 24)
        }
        .sheet(isPresented: $showImporter, onDismiss: onContinue) {
            GranolaImportView(importer: importer, state: meetingState)
        }
    }
}

// MARK: - Step 5: Done

struct DoneStep: View {
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're All Set!")
                .font(.system(size: 28, weight: .bold))

            Text("Ghost Pepper lives in your menu bar")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Menu bar mockup
            HStack(spacing: 10) {
                Spacer()
                Image(systemName: "moon.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: "display")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .foregroundStyle(.orange)
                Image(systemName: "wifi")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: "battery.75percent")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 8) {
                Text("From the menu bar you can:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                BulletPoint("Switch your microphone")
                BulletPoint("Change your recording shortcuts")
                BulletPoint("Record and transcribe meetings")
                BulletPoint("Import meetings and build your second brain")
                BulletPoint("Ask local questions over your archive")
            }
            .padding(.horizontal, 40)

            Spacer()

            Button(action: onComplete) {
                Text("Start Using Ghost Pepper")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
    }
}

struct BulletPoint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
