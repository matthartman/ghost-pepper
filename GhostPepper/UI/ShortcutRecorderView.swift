import SwiftUI
import AppKit
import CoreGraphics

struct ShortcutRecorderView: View {
    let title: String
    let chord: KeyChord?
    let onRecordingStateChange: (Bool) -> Void
    let onChange: (KeyChord?) -> Void

    @State private var isRecording = false
    @State private var captureState = ShortcutCaptureState()
    @State private var localMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if isRecording {
                    Button(action: toggleRecording) {
                        Text(buttonLabel)
                            .monospaced()
                    }
                    .buttonStyle(BorderedProminentButtonStyle())
                    .tint(.orange)
                } else {
                    Button(action: toggleRecording) {
                        Text(buttonLabel)
                            .monospaced()
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .tint(.orange)

                    if chord != nil {
                        Button(action: clearChord) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Clear shortcut")
                        .accessibilityLabel("Clear shortcut")
                    }
                }
            }

            if isRecording {
                Text("Press the full chord, then release. Press Delete to clear, or Escape to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            stopRecording(commit: false)
        }
    }

    private var buttonLabel: String {
        if isRecording {
            if let preview = KeyChord(keys: captureState.capturedKeys) {
                return preview.shortcutRecorderDisplayString
            }

            return "Press Shortcut"
        }

        if let chord {
            return chord.shortcutRecorderDisplayString
        }

        return "None"
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording(commit: false)
        } else {
            startRecording()
        }
    }

    private func clearChord() {
        stopRecording(commit: false)
        onChange(nil)
    }

    private func startRecording() {
        stopRecording(commit: false)
        onRecordingStateChange(true)
        isRecording = true
        captureState.reset()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp]) { event in
            handle(event)
        }
    }

    private func stopRecording(commit: Bool) {
        stopRecording(commit: commit, capturedChord: nil)
    }

    private func stopRecording(commit: Bool, capturedChord: KeyChord?) {
        let wasRecording = isRecording || localMonitor != nil

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        let committedChord = capturedChord ?? KeyChord(keys: captureState.capturedKeys)
        isRecording = false
        captureState.reset()
        if wasRecording {
            onRecordingStateChange(false)
        }

        if commit, let committedChord {
            onChange(committedChord)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            let key = PhysicalKey(keyCode: UInt16(event.keyCode))
            if let chord = captureState.handle(.flagsChanged(key)) {
                stopRecording(commit: true, capturedChord: chord)
            }
            return nil

        case .keyDown:
            let key = PhysicalKey(keyCode: UInt16(event.keyCode))
            if key.keyCode == 53, captureState.capturedKeys.isEmpty {
                // Escape with nothing captured = cancel recording.
                stopRecording(commit: false)
                return nil
            }

            if key.keyCode == 51, captureState.capturedKeys.isEmpty {
                // Delete/Backspace with nothing captured = clear the binding.
                stopRecording(commit: false)
                onChange(nil)
                return nil
            }

            _ = captureState.handle(.keyDown(key))
            return nil

        case .keyUp:
            let key = PhysicalKey(keyCode: UInt16(event.keyCode))
            if let chord = captureState.handle(.keyUp(key)) {
                stopRecording(commit: true, capturedChord: chord)
            }
            return nil

        default:
            return event
        }
    }
}
