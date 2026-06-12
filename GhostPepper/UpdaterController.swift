import AppKit
import Combine
import Sparkle

struct UpdateSurveyPromptPolicy {
    static let lastLaunchedVersionKey = "updateSurveyLastLaunchedVersion"
    static let lastPromptedVersionKey = "updateSurveyLastPromptedVersion"
    static let pendingUpdatedVersionKey = "updateSurveyPendingVersion"

    let defaults: UserDefaults

    func shouldPromptAfterLaunch(currentVersion rawCurrentVersion: String?) -> Bool {
        guard let currentVersion = rawCurrentVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !currentVersion.isEmpty else {
            return false
        }

        let lastLaunchedVersion = defaults.string(forKey: Self.lastLaunchedVersionKey)
        let lastPromptedVersion = defaults.string(forKey: Self.lastPromptedVersionKey)
        let pendingUpdatedVersion = defaults.string(forKey: Self.pendingUpdatedVersionKey)
        let launchedAfterKnownUpdate = pendingUpdatedVersion == currentVersion
        let launchedAfterVersionChange = lastLaunchedVersion != nil && lastLaunchedVersion != currentVersion

        defaults.set(currentVersion, forKey: Self.lastLaunchedVersionKey)

        guard (launchedAfterKnownUpdate || launchedAfterVersionChange),
              lastPromptedVersion != currentVersion else {
            return false
        }

        defaults.set(currentVersion, forKey: Self.lastPromptedVersionKey)
        if pendingUpdatedVersion == currentVersion {
            defaults.removeObject(forKey: Self.pendingUpdatedVersionKey)
        }
        return true
    }

    func markPendingSurveyPrompt(forVersion rawVersion: String?) {
        guard let version = rawVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return
        }

        defaults.set(version, forKey: Self.pendingUpdatedVersionKey)
    }
}

final class UpdaterController: NSObject, ObservableObject, SPUUpdaterDelegate {
    private static let surveyURL = URL(string: "https://forms.gle/WEGksMfvAgQojdG49")!

    private lazy var standardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    var updater: SPUUpdater {
        standardUpdaterController.updater
    }

    @Published var updateAvailable = false

    private let defaults: UserDefaults
    private let currentVersionProvider: () -> String?

    init(
        defaults: UserDefaults = .standard,
        currentVersionProvider: @escaping () -> String? = {
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        }
    ) {
        self.defaults = defaults
        self.currentVersionProvider = currentVersionProvider
        super.init()

        let updater = self.updater
        updater.automaticallyChecksForUpdates = true
        updater.updateCheckInterval = 86400

        // Check appcast for updates after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            self?.checkAppcastForUpdate()
        }
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }

    func askForSurveyAfterUpdateIfNeeded() {
        let policy = UpdateSurveyPromptPolicy(defaults: defaults)
        guard policy.shouldPromptAfterLaunch(currentVersion: currentVersionProvider()) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.showUpdateSurveyPrompt()
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        markPendingSurveyPrompt(for: item)
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        markPendingSurveyPrompt(for: item)
        return false
    }

    /// Check the appcast XML to see if a newer version exists.
    private func checkAppcastForUpdate() {
        guard let feedURL = updater.feedURL else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: feedURL),
                  let xml = String(data: data, encoding: .utf8) else { return }

            // Parse version from appcast: <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
            guard let range = xml.range(of: "(?<=<sparkle:shortVersionString>)[^<]+", options: .regularExpression),
                  let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }

            let latestVersion = String(xml[range])
            let isNewer = latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending

            await MainActor.run {
                self.updateAvailable = isNewer
            }
        }
    }

    private func markPendingSurveyPrompt(for item: SUAppcastItem) {
        UpdateSurveyPromptPolicy(defaults: defaults)
            .markPendingSurveyPrompt(forVersion: item.displayVersionString)
    }

    private func showUpdateSurveyPrompt() {
        let alert = NSAlert()
        alert.messageText = "Thanks for updating Ghost Pepper"
        alert.informativeText = "Would you be willing to complete a quick survey? It helps shape what gets better next."
        alert.alertStyle = .informational
        alert.icon = NSImage(named: "AppIcon")
        alert.addButton(withTitle: "Take Survey")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.surveyURL)
        }
    }
}
