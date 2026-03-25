import AppKit

protocol AppRelaunching {
    @MainActor
    func relaunch() throws
}

final class AppRelauncher: AppRelaunching {
    private let bundleURL: URL
    private let openApplication: (URL) throws -> Void

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        openApplication: @escaping (URL) throws -> Void = AppRelauncher.openApplication
    ) {
        self.bundleURL = bundleURL
        self.openApplication = openApplication
    }

    @MainActor
    func relaunch() throws {
        try openApplication(bundleURL)
        NSApplication.shared.terminate(nil)
    }

    private static func openApplication(bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]
        try process.run()
    }
}
