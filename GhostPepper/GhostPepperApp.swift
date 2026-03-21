import SwiftUI
import Combine

@main
struct GhostPepperApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var hasInitialized = false
    private let onboardingController = OnboardingWindowController()
    private let updaterController = UpdaterController()

    init() {
        // Set activation policy immediately at launch
        let completed = UserDefaults.standard.bool(forKey: "onboardingCompleted")
        if completed {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updaterController: updaterController)
        } label: {
            Group {
                switch appState.status {
                case .recording:
                    Image("MenuBarIconRedDim")
                        .renderingMode(.original)
                case .loading:
                    Image(systemName: "ellipsis.circle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange)
                case .error:
                    Image(systemName: "exclamationmark.triangle")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.yellow)
                default:
                    Image("MenuBarIcon")
                        .renderingMode(.template)
                }
            }
            .onAppear {
                guard !hasInitialized else { return }
                hasInitialized = true
                if onboardingCompleted {
                    Task { await appState.initialize() }
                } else {
                    onboardingController.show(appState: appState) {
                        NSApp.setActivationPolicy(.accessory)
                        Task { await appState.initialize() }
                    }
                }
            }
        }
    }
}
