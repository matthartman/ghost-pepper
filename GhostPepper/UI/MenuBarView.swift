import SwiftUI
import CoreAudio
import ServiceManagement

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var updaterController: UpdaterController

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button("Settings...") {
                appState.showSettings()
            }

            if appState.pepperChatEnabled {
                Button("Context Bundler...") {
                    appState.showPepperChat()
                }
            }

            Button("Debug Log...") {
                appState.showDebugLog()
            }

            if appState.meetingTranscriptEnabled {
                Divider()

                Button("Meetings...") {
                    appState.showOrCreateMeetingWindow()
                }

                if appState.activeMeetingSession != nil {
                    Button("Stop Meeting") {
                        appState.stopMeetingTranscription()
                    }
                }
            }

            Text("Ghost Pepper v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 2)

            if let statusText = statusLine {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
            }

            if case .downloading(_, let progress) = appState.textCleanupManager.state {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 14)
            }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)

                if appState.canReloadAudioInput {
                    Button("Reload Audio Input") {
                        appState.resetAudioEngine()
                    }
                }
                if error.contains("Input Monitoring") {
                    Button("Open Input Monitoring Settings") {
                        PermissionChecker.openInputMonitoringSettings()
                    }
                    Button("Retry") {
                        Task { await appState.startHotkeyMonitor() }
                    }
                }
                if error.contains("Accessibility") {
                    Button("Open Accessibility Settings") {
                        PermissionChecker.openAccessibilitySettings()
                    }
                    Button("Retry") {
                        Task { await appState.startHotkeyMonitor() }
                    }
                }
                if error.contains("Microphone") {
                    Button("Open Microphone Settings") {
                        PermissionChecker.openMicrophoneSettings()
                    }
                }
            }

            Divider()

            Button(updaterController.updateAvailable ? "Update Available — Install Now" : "Check for Updates") {
                updaterController.checkForUpdates()
            }
            .foregroundColor(updaterController.updateAvailable ? .orange : nil)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String? {
        switch appState.status {
        case .ready:
            return nil
        case .loading:
            return "Loading..."
        case .recording:
            return "Recording..."
        case .transcribing:
            return "Transcribing..."
        case .cleaningUp:
            return "Cleaning up..."
        case .error:
            return nil
        }
    }
}
