import SwiftUI

enum AppStatus: String {
    case ready = "Ready"
    case loading = "Loading model..."
    case recording = "Recording..."
    case transcribing = "Transcribing..."
    case error = "Error"
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .loading
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?

    let modelManager = ModelManager()
    let audioRecorder = AudioRecorder()
    let transcriber: WhisperTranscriber
    let textPaster = TextPaster()
    let soundEffects = SoundEffects()
    let hotkeyMonitor = HotkeyMonitor()
    let overlay = RecordingOverlayController()

    var isReady: Bool {
        status == .ready
    }

    init() {
        self.transcriber = WhisperTranscriber(modelManager: modelManager)
    }

    func initialize() async {
        // Check microphone permission
        let hasMic = await PermissionChecker.checkMicrophone()
        if !hasMic {
            errorMessage = "Microphone access required"
            status = .error
            return
        }

        // Check accessibility permission
        if !PermissionChecker.checkAccessibility() {
            PermissionChecker.promptAccessibility()
            errorMessage = "Accessibility access required — grant permission and relaunch"
            status = .error
            return
        }

        // Load WhisperKit model (downloads on first run)
        status = .loading
        await modelManager.loadModel()

        guard modelManager.isReady else {
            errorMessage = "Failed to load whisper model: \(modelManager.error?.localizedDescription ?? "unknown error")"
            status = .error
            return
        }

        // Set up hotkey callbacks
        hotkeyMonitor.onRecordingStart = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotkeyMonitor.onRecordingStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }

        guard hotkeyMonitor.start() else {
            errorMessage = "Failed to start hotkey monitor — check Accessibility permission"
            status = .error
            return
        }

        status = .ready
        errorMessage = nil
    }

    private func startRecording() {
        guard status == .ready else { return }

        do {
            try audioRecorder.startRecording()
            soundEffects.playStart()
            overlay.show()
            isRecording = true
            status = .recording
        } catch {
            errorMessage = "Failed to start recording: \(error.localizedDescription)"
            status = .error
        }
    }

    private func stopRecordingAndTranscribe() async {
        guard status == .recording else { return }

        let buffer = audioRecorder.stopRecording()
        soundEffects.playStop()
        overlay.dismiss()
        isRecording = false
        status = .transcribing

        if let text = await transcriber.transcribe(audioBuffer: buffer) {
            textPaster.paste(text: text)
        }

        status = .ready
    }
}
