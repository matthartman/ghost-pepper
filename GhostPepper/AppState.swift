import SwiftUI
import Combine

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
    @AppStorage("cleanupEnabled") var cleanupEnabled: Bool = true
    @AppStorage("cleanupPrompt") var cleanupPrompt: String = TextCleaner.defaultPrompt

    let modelManager = ModelManager()
    let audioRecorder = AudioRecorder()
    let transcriber: WhisperTranscriber
    let textPaster = TextPaster()
    let soundEffects = SoundEffects()
    let hotkeyMonitor = HotkeyMonitor()
    let overlay = RecordingOverlayController()
    let textCleanupManager = TextCleanupManager()
    let textCleaner: TextCleaner

    var isReady: Bool {
        status == .ready
    }

    private var cleanupStateObserver: Any?

    init() {
        self.transcriber = WhisperTranscriber(modelManager: modelManager)
        self.textCleaner = TextCleaner(cleanupManager: textCleanupManager)

        // Forward cleanup manager state changes to trigger menu bar icon refresh
        cleanupStateObserver = textCleanupManager.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
            }
        }
    }

    func initialize() async {
        let hasMic = await PermissionChecker.checkMicrophone()
        if !hasMic {
            errorMessage = "Microphone access required"
            status = .error
            return
        }

        // Pre-warm audio engine so first recording starts faster
        audioRecorder.prewarm()

        status = .loading
        overlay.show(message: .modelLoading)
        await modelManager.loadModel()
        overlay.dismiss()

        guard modelManager.isReady else {
            errorMessage = "Failed to load whisper model: \(modelManager.error?.localizedDescription ?? "unknown error")"
            status = .error
            return
        }

        await startHotkeyMonitor()

        if cleanupEnabled {
            Task {
                await textCleanupManager.loadModel()
                // Force menu bar icon refresh
                objectWillChange.send()
            }
        }
    }

    func startHotkeyMonitor() async {
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

        if hotkeyMonitor.start() {
            status = .ready
            errorMessage = nil
        } else {
            PermissionChecker.promptAccessibility()
            errorMessage = "Accessibility access required — grant permission then click Retry"
            status = .error
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

        let buffer = await audioRecorder.stopRecording()
        soundEffects.playStop()
        isRecording = false
        status = .transcribing
        overlay.show(message: .transcribing)

        if let text = await transcriber.transcribe(audioBuffer: buffer) {
            let finalText: String
            let wordCount = text.split(separator: " ").count
            if cleanupEnabled && textCleanupManager.isReady && wordCount > 5 {
                status = .cleaningUp
                overlay.show(message: .cleaningUp)
                finalText = await textCleaner.clean(text: text, prompt: cleanupPrompt)
            } else {
                finalText = text
            }

            // Append to log for debugging
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let logEntry = """
            [\(timestamp)]
            --- RAW TRANSCRIPTION ---
            \(text)
            --- CLEANUP: enabled=\(cleanupEnabled), ready=\(textCleanupManager.isReady) ---
            --- PROMPT ---
            \(cleanupPrompt)
            --- CLEANED OUTPUT ---
            \(finalText)
            --- END ---\n\n
            """
            let logDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ghostpepper/logs")
            let logFile = logDir.appendingPathComponent("transcript.log")
            try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(logEntry.data(using: .utf8)!)
                handle.closeFile()
            } else {
                try? logEntry.write(to: logFile, atomically: true, encoding: .utf8)
            }

            overlay.dismiss()
            textPaster.paste(text: finalText)
        } else {
            overlay.dismiss()
        }

        status = .ready
    }
}
