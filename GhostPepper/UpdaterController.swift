import Sparkle

final class UpdaterController: ObservableObject {
    let updater: SPUUpdater
    @Published var updateAvailable = false

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater = controller.updater
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
}
