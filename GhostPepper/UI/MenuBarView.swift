import SwiftUI
import CoreAudio

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    let updaterController: UpdaterController
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var selectedDeviceID: AudioDeviceID = 0
    @State private var showingPromptEditor = false
    private let promptEditor = PromptEditorController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.status.rawValue)
                .font(.headline)

            if let error = appState.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)

                if error.contains("Accessibility") {
                    Button("Open Accessibility Settings") {
                        PermissionChecker.openAccessibilitySettings()
                    }
                    Button("Retry") {
                        Task {
                            await appState.startHotkeyMonitor()
                        }
                    }
                }
                if error.contains("Microphone") {
                    Button("Open Microphone Settings") {
                        PermissionChecker.openMicrophoneSettings()
                    }
                }
            }

            Divider()

            Picker("Input Device", selection: $selectedDeviceID) {
                ForEach(inputDevices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .onChange(of: selectedDeviceID) { _, newValue in
                AudioDeviceManager.setDefaultInputDevice(newValue)
            }

            Divider()

            Toggle("Cleanup", isOn: $appState.cleanupEnabled)
                .onChange(of: appState.cleanupEnabled) { _, enabled in
                    Task {
                        if enabled {
                            await appState.textCleanupManager.loadModel()
                        } else {
                            appState.textCleanupManager.unloadModel()
                        }
                    }
                }

            if appState.cleanupEnabled {
                let statusText = appState.textCleanupManager.statusText
                if !statusText.isEmpty {
                    if case .downloading(let progress) = appState.textCleanupManager.state {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        }
                    } else if appState.textCleanupManager.state == .error {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button("Edit Cleanup Prompt...") {
                    promptEditor.show(appState: appState)
                }
            }

            Divider()

            Button("Check for Updates...") {
                updaterController.checkForUpdates()
            }

            Button("Restart Ghost Pepper") {
                restartApp()
            }

            Button("Quit Ghost Pepper") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .onAppear {
            refreshDevices()
        }
    }

    private func refreshDevices() {
        inputDevices = AudioDeviceManager.listInputDevices()
        selectedDeviceID = AudioDeviceManager.defaultInputDeviceID() ?? 0
    }

    private func selectDevice(_ device: AudioInputDevice) {
        if AudioDeviceManager.setDefaultInputDevice(device.id) {
            selectedDeviceID = device.id
        }
    }

    private func restartApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }
}
