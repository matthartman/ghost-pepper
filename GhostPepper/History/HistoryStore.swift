import Combine
import Foundation

extension HistoryEntry: Sendable {}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]

    var maxEntries: Int {
        didSet {
            let clampedMaxEntries = max(0, maxEntries)
            if clampedMaxEntries != maxEntries {
                maxEntries = clampedMaxEntries
                return
            }

            guard clampedMaxEntries != oldValue else {
                return
            }

            let removedEntries = trimToCapacity()
            guard !removedEntries.isEmpty else {
                return
            }

            persistEntries(removingAudioFor: removedEntries)
        }
    }

    @Published private(set) var diskUsageBytes: Int64 = 0

    private let storageURL: URL
    private let audioDirectoryURL: URL
    private let persistenceCoordinator: HistoryPersistenceCoordinator
    private var pendingPersistenceTask: Task<Void, Never>?

    init(
        maxEntries: Int = 500,
        storageURL: URL? = nil,
        audioDirectoryURL: URL? = nil
    ) {
        let resolvedStorageURL = storageURL ?? Self.defaultStorageURL
        let resolvedAudioDirectoryURL = audioDirectoryURL ?? Self.defaultAudioDirectoryURL
        let resolvedMaxEntries = max(0, maxEntries)
        let loadedEntries = Self.loadEntries(from: resolvedStorageURL)
        let (trimmedEntries, removedEntries) = Self.prunedEntries(
            from: loadedEntries,
            maxEntries: resolvedMaxEntries
        )

        self.entries = trimmedEntries
        self.maxEntries = resolvedMaxEntries
        self.storageURL = resolvedStorageURL
        self.audioDirectoryURL = resolvedAudioDirectoryURL
        self.persistenceCoordinator = HistoryPersistenceCoordinator(
            storageURL: resolvedStorageURL,
            audioDirectoryURL: resolvedAudioDirectoryURL
        )

        if !removedEntries.isEmpty {
            persistEntries(removingAudioFor: removedEntries)
        }

        refreshDiskUsage()
    }

    func addEntry(
        _ entry: HistoryEntry,
        audioSamples: [Float]? = nil,
        sampleRate: Int = 16_000
    ) {
        entries.insert(entry, at: 0)
        let removedEntries = trimToCapacity()
        let audioWrite: PendingAudioWrite?
        if let audioSamples, let relativePath = entry.audioFileURL {
            audioWrite = PendingAudioWrite(
                relativePath: relativePath,
                samples: audioSamples,
                sampleRate: sampleRate
            )
        } else {
            audioWrite = nil
        }

        persistEntries(removingAudioFor: removedEntries, audioWrite: audioWrite)
    }

    func deleteEntry(id: UUID) {
        guard let entryIndex = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        let removedEntry = entries.remove(at: entryIndex)
        persistEntries(removingAudioFor: [removedEntry])
    }

    func deleteAllEntries() {
        entries.removeAll()
        persistEntries(deleteAllAudioFiles: true)
    }

    func audioFileURL(for entry: HistoryEntry) -> URL? {
        guard let relativePath = entry.audioFileURL else {
            return nil
        }

        return resolvedHistoryAudioURL(
            audioDirectoryURL: audioDirectoryURL,
            relativePath: relativePath
        )
    }

    func flushPendingWrites() async {
        await pendingPersistenceTask?.value
    }

    func waitForPendingWrites(timeout: TimeInterval = 2.0) {
        guard let pendingPersistenceTask else {
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .utility) {
            await pendingPersistenceTask.value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func persistEntries(
        removingAudioFor removedEntries: [HistoryEntry] = [],
        deleteAllAudioFiles: Bool = false,
        audioWrite: PendingAudioWrite? = nil
    ) {
        let snapshot = entries
        let audioRelativePaths = removedEntries.compactMap(\.audioFileURL)
        let previousTask = pendingPersistenceTask
        let persistenceCoordinator = self.persistenceCoordinator

        pendingPersistenceTask = Task.detached(priority: .utility) {
            await previousTask?.value
            await persistenceCoordinator.persist(
                entries: snapshot,
                deletingAudioRelativePaths: audioRelativePaths,
                deleteAllAudioFiles: deleteAllAudioFiles,
                audioWrite: audioWrite
            )
        }

        refreshDiskUsage()
    }

    private func refreshDiskUsage() {
        let storageURL = self.storageURL
        let audioDirectoryURL = self.audioDirectoryURL
        let previousTask = pendingPersistenceTask

        Task.detached(priority: .utility) {
            await previousTask?.value
            let jsonSize = Self.fileSize(at: storageURL)
            let audioSize = Self.directorySize(at: audioDirectoryURL)
            let total = jsonSize + audioSize
            await MainActor.run { [weak self] in
                self?.diskUsageBytes = total
            }
        }
    }

    @discardableResult
    private func trimToCapacity() -> [HistoryEntry] {
        let (trimmedEntries, removedEntries) = Self.prunedEntries(from: entries, maxEntries: maxEntries)
        entries = trimmedEntries
        return removedEntries
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }

        return size.int64Value
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return 0
        }

        var totalSize: Int64 = 0

        for case let fileURL as URL in enumerator {
            guard
                let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                resourceValues.isRegularFile == true
            else {
                continue
            }

            totalSize += Int64(resourceValues.fileSize ?? 0)
        }

        return totalSize
    }

    private static func loadEntries(from storageURL: URL) -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: storageURL) else {
            return []
        }

        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private static func prunedEntries(
        from entries: [HistoryEntry],
        maxEntries: Int
    ) -> ([HistoryEntry], [HistoryEntry]) {
        guard entries.count > maxEntries else {
            return (entries, [])
        }

        let retainedEntries = Array(entries.prefix(maxEntries))
        let removedEntries = Array(entries.dropFirst(maxEntries))
        return (retainedEntries, removedEntries)
    }

    private static var defaultStorageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    private static var defaultAudioDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("GhostPepper", isDirectory: true)
            .appendingPathComponent("history-audio", isDirectory: true)
    }
}

private actor HistoryPersistenceCoordinator {
    private let storageURL: URL
    private let audioDirectoryURL: URL

    init(storageURL: URL, audioDirectoryURL: URL) {
        self.storageURL = storageURL
        self.audioDirectoryURL = audioDirectoryURL
    }

    func persist(
        entries: [HistoryEntry],
        deletingAudioRelativePaths: [String],
        deleteAllAudioFiles: Bool,
        audioWrite: PendingAudioWrite?
    ) {
        if deleteAllAudioFiles {
            try? FileManager.default.removeItem(at: audioDirectoryURL)
        } else {
            deletingAudioRelativePaths.forEach(deleteAudioFile)
        }

        if let audioWrite {
            writeAudioFile(audioWrite)
        }

        let storageDirectoryURL = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: storageDirectoryURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(entries) else {
            return
        }

        try? data.write(to: storageURL, options: .atomic)
    }

    private func deleteAudioFile(relativePath: String) {
        guard let audioFileURL = resolvedAudioURL(for: relativePath) else {
            return
        }

        try? FileManager.default.removeItem(at: audioFileURL)
    }

    private func writeAudioFile(_ audioWrite: PendingAudioWrite) {
        guard let audioFileURL = resolvedAudioURL(for: audioWrite.relativePath) else {
            return
        }

        try? FileManager.default.createDirectory(
            at: audioFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let wavData = WAVEncoder.encode(samples: audioWrite.samples, sampleRate: audioWrite.sampleRate)
        try? wavData.write(to: audioFileURL, options: .atomic)
    }

    private func resolvedAudioURL(for relativePath: String) -> URL? {
        resolvedHistoryAudioURL(audioDirectoryURL: audioDirectoryURL, relativePath: relativePath)
    }
}

private struct PendingAudioWrite: Sendable {
    let relativePath: String
    let samples: [Float]
    let sampleRate: Int
}

private func resolvedHistoryAudioURL(audioDirectoryURL: URL, relativePath: String) -> URL? {
    guard !relativePath.isEmpty else {
        return nil
    }

    let normalizedAudioDirectoryURL = audioDirectoryURL.standardizedFileURL
    let candidateURL = normalizedAudioDirectoryURL
        .appendingPathComponent(relativePath)
        .standardizedFileURL
    let allowedPrefix = normalizedAudioDirectoryURL.path.hasSuffix("/")
        ? normalizedAudioDirectoryURL.path
        : normalizedAudioDirectoryURL.path + "/"

    guard candidateURL.path.hasPrefix(allowedPrefix) else {
        return nil
    }

    return candidateURL
}
