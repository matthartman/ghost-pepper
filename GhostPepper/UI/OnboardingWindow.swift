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

    func start() {
        guard !isRunning else { return }
        // Only start if mic permission is already granted
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
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
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

    var body: some View {
        VStack {
            switch currentStep {
            case 1:
                WelcomeStep(onContinue: { currentStep = 2 })
            case 2:
                SetupStep(appState: appState, modelManager: appState.modelManager, onContinue: { currentStep = 3 })
            case 3:
                TryItStep(appState: appState, onContinue: { currentStep = 4 })
            case 4:
                DoneStep(onComplete: {
                    UserDefaults.standard.set(true, forKey: "onboardingCompleted")
                    onComplete()
                })
            default:
                EmptyView()
            }
        }
        .frame(width: 480, height: 520)
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

            Text("Hold-to-talk speech-to-text\nfor your Mac")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .foregroundStyle(.green)
                Text("100% Private — Everything runs locally on your Mac.\nNo cloud, no accounts, no data ever leaves your machine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
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
    @State private var modelLoadStarted = false
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @StateObject private var micLevel = MicLevelMonitor()
    @StateObject private var screenRecordingPermission = ScreenRecordingPermissionController()

    private var allComplete: Bool {
        micGranted && accessibilityGranted && screenRecordingPermission.isGranted && modelManager.isReady
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Setup 🌶️")
                .font(.system(size: 24, weight: .bold))
                .padding(.top, 24)

            Text("Grant permissions and download the speech model")
                .font(.callout)
                .foregroundStyle(.secondary)

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
                                    selectedDeviceID = AudioDeviceManager.defaultInputDeviceID() ?? 0
                                    micLevel.start()
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
                                AudioDeviceManager.setDefaultInputDevice(newValue)
                                // Restart level monitor for new device
                                micLevel.stop()
                                micLevel.start()
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
                            PermissionChecker.promptAccessibility()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }

                SetupRow(
                    icon: "rectangle.on.rectangle",
                    title: "Screen Recording",
                    subtitle: "For OCR context & learning",
                    isComplete: screenRecordingPermission.isGranted
                ) {
                    if !screenRecordingPermission.isGranted {
                        Button("Grant") {
                            screenRecordingPermission.requestAccess()
                            PermissionChecker.openScreenRecordingSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                }

                if !screenRecordingPermission.isGranted {
                    Text("Grant Screen Recording access in System Settings, then return here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }

                VStack(spacing: 8) {
                    SetupRow(
                        icon: "brain",
                        title: "AI Models",
                        subtitle: modelManager.state == .error
                            ? "Download failed"
                            : modelManager.isReady
                                ? "Ready"
                                : "Downloading & compiling (may take a few minutes)...",
                        isComplete: modelManager.isReady
                    ) {
                        if modelManager.state == .loading {
                            ProgressView()
                                .controlSize(.small)
                        } else if modelManager.state == .error {
                            Button("Retry") {
                                Task { await modelManager.loadModel() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }
                    }

                    if modelManager.state == .loading {
                        VStack(spacing: 6) {
                            EmojiProgressBar()
                            VStack(alignment: .leading, spacing: 3) {
                                ModelStageRow(name: "WhisperKit (speech-to-text)", size: "~500 MB", isDone: false, isActive: true)
                                ModelStageRow(name: "Qwen 2.5 1.5B (fast cleanup)", size: "~1 GB", isDone: false, isActive: false)
                                ModelStageRow(name: "Qwen 2.5 3B (full cleanup)", size: "~2 GB", isDone: false, isActive: false)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()

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
                    let tweet = "hey @matthartman I'm trying out Ghost Pepper 🌶️ will let you know how I like it!"
                    let encoded = tweet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    if let url = URL(string: "https://twitter.com/intent/tweet?text=\(encoded)") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("📣 Tell Matt you're trying out Ghost Pepper!")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .padding(.bottom, 24)
            }
        }
        .onAppear {
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            micDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            accessibilityGranted = PermissionChecker.checkAccessibility()

            if micGranted {
                inputDevices = AudioDeviceManager.listInputDevices()
                selectedDeviceID = AudioDeviceManager.defaultInputDeviceID() ?? 0
                micLevel.start()
            }

            if !modelLoadStarted && !modelManager.isReady {
                modelLoadStarted = true
                Task { await modelManager.loadModel() }
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

// MARK: - Step 3: Try It

@MainActor
class TryItController: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var transcribedText: String?
    @Published var monitorStartFailed = false

    private var hotkeyMonitor: HotkeyMonitoring?
    private var audioRecorder: AudioRecorder?
    private var hasAdvanced = false
    private var retryCount = 0
    private let maxRetries = 5
    private let transcriber: WhisperTranscriber
    private let hotkeyMonitorFactory: ([ChordAction: KeyChord]) -> HotkeyMonitoring

    init(
        transcriber: WhisperTranscriber,
        hotkeyMonitorFactory: @escaping ([ChordAction: KeyChord]) -> HotkeyMonitoring = { bindings in
            HotkeyMonitor(bindings: bindings)
        }
    ) {
        self.transcriber = transcriber
        self.hotkeyMonitorFactory = hotkeyMonitorFactory
    }

    func start(onAdvance: @escaping () -> Void) {
        let recorder = AudioRecorder()
        recorder.prewarm()
        self.audioRecorder = recorder

        let monitor = hotkeyMonitorFactory([
            .pushToTalk: AppState.defaultPushToTalkChord
        ])
        monitor.onRecordingStart = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
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
                    Text("Waiting for you to hold Right Command + Right Option...")
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

// MARK: - Step 4: Done

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
                BulletPoint("Toggle text cleanup on/off")
                BulletPoint("Edit the cleanup prompt")
                BulletPoint("Check for updates")
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

struct ModelStageRow: View {
    let name: String
    let size: String
    let isDone: Bool
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isDone {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
            } else if isActive {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.quaternary)
                    .font(.caption2)
            }
            Text(name)
                .font(.caption2)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer()
            Text(size)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

struct EmojiProgressBar: View {
    private let emojis = ["🌶️", "👻", "🔥"]
    private let maxSlots = 15
    @State private var filledCount = 0
    @State private var timer: Timer?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .separatorColor).opacity(0.3))

                // Filled portion with emojis
                HStack(spacing: 0) {
                    ForEach(0..<filledCount, id: \.self) { i in
                        Text(emojis[i % emojis.count])
                            .font(.system(size: 13))
                            .frame(width: geo.size.width / CGFloat(maxSlots), height: geo.size.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if filledCount >= maxSlots {
                            filledCount = 0
                        } else {
                            filledCount += 1
                        }
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
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
