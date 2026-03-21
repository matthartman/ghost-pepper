import SwiftUI
import Combine

@main
struct GhostPepperApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @State private var hasInitialized = false
    @State private var pulseBright = true
    private let onboardingController = OnboardingWindowController()
    private let updaterController = UpdaterController()

    private let pulseTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

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
            .onReceive(pulseTimer) { _ in
                if appState.status == .recording {
                    pulseBright.toggle()
                } else {
                    pulseBright = true
                }
            }
            .onAppear {
                guard !hasInitialized else { return }
                hasInitialized = true
                if onboardingCompleted {
                    Task { await appState.initialize() }
                } else {
                    onboardingController.show(appState: appState) {
                        Task { await appState.initialize() }
                    }
                }
            }
        }
    }
}
