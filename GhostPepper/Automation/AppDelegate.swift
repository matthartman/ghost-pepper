import AppKit

/// Handles `ghostpepper://` URLs. `.onOpenURL` is unreliable in a `MenuBarExtra`-only
/// app, so we register a delegate via `@NSApplicationDelegateAdaptor` and implement
/// `application(_:open:)`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let processor = AutomationURLProcessor()

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == URLActionHandler.scheme {
            processor.enqueue(url)
        }
    }
}

/// Runs inbound automation URLs one at a time so a slow `summarize-meeting` can't race
/// a later URL, and waits for AppState before dispatching (cold-launch buffering).
@MainActor
private final class AutomationURLProcessor {
    private var tail: Task<Void, Never>?

    func enqueue(_ url: URL) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await Self.handle(url)
        }
    }

    private static func handle(_ url: URL) async {
        guard let request = URLActionHandler.parse(url) else {
            NSLog("GhostPepper automation: ignoring malformed URL %@", url.absoluteString)
            return
        }

        let appState = await AppState.ready()
        let result: Result<GhostPepperActionResult, GhostPepperActionError>
        if let appState {
            switch URLActionHandler.action(for: request) {
            case .success(let action):
                result = await appState.perform(action)
            case .failure(let error):
                result = .failure(error)
            }
        } else {
            result = .failure(.notReady("Ghost Pepper is still launching."))
        }

        if let callback = URLActionHandler.callbackURL(for: request, result: result) {
            NSWorkspace.shared.open(callback)
        } else if case .failure(let error) = result {
            let message = "automation \(request.action) failed (\(error.code.rawValue)) — \(error.message)"
            if let appState {
                appState.debugLogStore.record(category: .model, message: message)
            } else {
                NSLog("GhostPepper %@", message)
            }
        }
    }
}
