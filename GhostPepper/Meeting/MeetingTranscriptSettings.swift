import Foundation

/// Helpers for persisting meeting transcript settings.
enum MeetingTranscriptSettings {
    private static let saveDirectoryKey = "meetingTranscriptSaveDirectory"
    private static let saveDirectoryPathKey = saveDirectoryKey + "Path"
    private static let securityScopeLock = NSLock()
    private static var accessedSecurityScopedPaths = Set<String>()

    /// Returns the default save directory: Documents/Ghost Pepper Meetings.
    static func defaultSaveDirectory() -> URL {
        let documentsArchive = documentsArchiveURL()
        if isRunningInAppSandbox {
            return documentsArchive
        }

        // Unsigned local builds resolve `.documentDirectory` to the user's
        // normal Documents folder. Prefer the app-container archive only in
        // that unsandboxed case so debug builds can see local app data without
        // making the sandboxed app request access to `~/Library/Containers`.
        if let containerArchive = appContainerArchiveIfPresent() {
            return containerArchive
        }
        return documentsArchive
    }

    /// Load the user-chosen save directory, or nil to use the default.
    static func loadSaveDirectory() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: saveDirectoryKey) else {
            guard let path = UserDefaults.standard.string(forKey: saveDirectoryPathKey), !path.isEmpty else {
                return nil
            }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isOwnSandboxArchiveURL(url) {
                return defaultSaveDirectory()
            }
            return url
        }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            return nil
        }
        if isOwnSandboxArchiveURL(url) {
            if isStale {
                UserDefaults.standard.removeObject(forKey: saveDirectoryKey)
            }
            return defaultSaveDirectory()
        }
        startAccessingIfNeeded(url)
        if isStale {
            // Re-save fresh bookmark
            saveSaveDirectory(url)
        }
        return url
    }

    /// Persist the user-chosen save directory as a security-scoped bookmark.
    static func saveSaveDirectory(_ url: URL) {
        guard let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            // Fallback: just save the path if bookmark fails (non-sandboxed app)
            UserDefaults.standard.set(url.path, forKey: saveDirectoryPathKey)
            return
        }
        UserDefaults.standard.set(bookmarkData, forKey: saveDirectoryKey)
        UserDefaults.standard.removeObject(forKey: saveDirectoryPathKey)
        startAccessingIfNeeded(url)
    }

    /// Returns the effective save directory (user-chosen or default).
    static func effectiveSaveDirectory() -> URL {
        return loadSaveDirectory() ?? defaultSaveDirectory()
    }

    private static func startAccessingIfNeeded(_ url: URL) {
        let path = url.standardizedFileURL.path
        securityScopeLock.lock()
        defer { securityScopeLock.unlock() }
        guard !accessedSecurityScopedPaths.contains(path) else { return }
        if url.startAccessingSecurityScopedResource() {
            accessedSecurityScopedPaths.insert(path)
        }
    }

    static func appContainerArchiveIfPresent() -> URL? {
        guard !isRunningInAppSandbox else { return nil }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.github.matthartman.ghostpepper"
        let archive = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("Data/Documents/Ghost Pepper Meetings", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: archive.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return archive
    }

    private static var isRunningInAppSandbox: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ||
            NSHomeDirectory().contains("/Library/Containers/")
    }

    private static func documentsArchiveURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("Ghost Pepper Meetings", isDirectory: true)
    }

    private static func isOwnSandboxArchiveURL(_ url: URL) -> Bool {
        guard isRunningInAppSandbox else { return false }
        return url.standardizedFileURL.path == documentsArchiveURL().standardizedFileURL.path
    }
}
