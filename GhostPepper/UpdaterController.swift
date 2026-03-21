import Sparkle

final class UpdaterController {
    let updater: SPUUpdater

    init() {
        updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        ).updater
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}
