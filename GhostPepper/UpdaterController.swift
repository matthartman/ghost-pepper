import Sparkle

final class UpdaterController {
    let updater: SPUUpdater

    init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updater = controller.updater
        updater.automaticallyChecksForUpdates = true
        updater.updateCheckInterval = 86400
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
