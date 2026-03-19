import SwiftUI

@main
struct WhisperCatApp: App {
    @StateObject private var appState = AppState()
    @State private var hasInitialized = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
                .task {
                    guard !hasInitialized else { return }
                    hasInitialized = true
                    await appState.initialize()
                }
        } label: {
            Image(systemName: appState.isRecording ? "waveform.circle.fill" : "waveform")
                .symbolRenderingMode(.palette)
                .foregroundStyle(appState.isRecording ? .red : .primary)
        }
    }
}
