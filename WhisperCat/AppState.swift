import SwiftUI

enum AppStatus: String {
    case ready = "Ready"
    case recording = "Recording..."
    case transcribing = "Transcribing..."
    case error = "Error"
}

@MainActor
class AppState: ObservableObject {
    @Published var status: AppStatus = .ready
    @Published var isRecording: Bool = false
    @Published var errorMessage: String?

    var isReady: Bool {
        status == .ready
    }
}
