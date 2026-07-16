import Foundation

enum GhostPepperHistoryActor: String, Codable {
    case user
    case ghostPepper = "ghost_pepper"
}

struct GhostPepperHistoryEvent: Codable, Equatable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var actor: GhostPepperHistoryActor
    var operation: String
    var summary: String
    var relativePath: String
    var beforeHash: String?
    var afterHash: String?
    var beforeSnapshotPath: String?
    var afterSnapshotPath: String?
    var metadata: [String: String]
}

enum GhostPepperHistoryStore {
    static let metadataFolderName = ".ghostpepper"
    static let historyFolderName = "history"

    static func recordEvent(
        archiveRoot: URL,
        actor: GhostPepperHistoryActor,
        operation: String,
        summary: String,
        relativePath: String,
        metadata: [String: String] = [:]
    ) {
        do {
            try ensureHistoryRoot(in: archiveRoot)
            let event = GhostPepperHistoryEvent(
                actor: actor,
                operation: operation,
                summary: summary,
                relativePath: relativePath,
                beforeHash: nil,
                afterHash: nil,
                beforeSnapshotPath: nil,
                afterSnapshotPath: nil,
                metadata: metadata
            )
            try append(event, archiveRoot: archiveRoot)
        } catch {
            NSLog("GhostPepperHistoryStore: failed to record event %@ for %@: %@", operation, relativePath, error.localizedDescription)
        }
    }

    static func recordFileChange(
        archiveRoot: URL,
        fileURL: URL,
        actor: GhostPepperHistoryActor,
        operation: String,
        summary: String,
        before: String?,
        after: String?,
        metadata: [String: String] = [:]
    ) {
        guard let relativePath = relativePath(of: fileURL, in: archiveRoot) else { return }
        let beforeHash = before.map(stableHash)
        let afterHash = after.map(stableHash)
        guard beforeHash != afterHash || beforeSnapshotPathNeeded(operation: operation) else { return }

        do {
            try ensureHistoryRoot(in: archiveRoot)
            let beforeSnapshot = try before.flatMap {
                try writeSnapshotIfNeeded($0, hash: beforeHash, archiveRoot: archiveRoot, role: "before")
            }
            let afterSnapshot = try after.flatMap {
                try writeSnapshotIfNeeded($0, hash: afterHash, archiveRoot: archiveRoot, role: "after")
            }
            let event = GhostPepperHistoryEvent(
                actor: actor,
                operation: operation,
                summary: summary,
                relativePath: relativePath,
                beforeHash: beforeHash,
                afterHash: afterHash,
                beforeSnapshotPath: beforeSnapshot,
                afterSnapshotPath: afterSnapshot,
                metadata: metadata
            )
            try append(event, archiveRoot: archiveRoot)
        } catch {
            NSLog("GhostPepperHistoryStore: failed to record history for %@: %@", relativePath, error.localizedDescription)
        }
    }

    static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    static func historyRoot(in archiveRoot: URL) -> URL {
        archiveRoot
            .appendingPathComponent(metadataFolderName, isDirectory: true)
            .appendingPathComponent(historyFolderName, isDirectory: true)
    }

    private static func ensureHistoryRoot(in archiveRoot: URL) throws {
        let root = historyRoot(in: archiveRoot)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("events", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("snapshots", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    private static func writeSnapshotIfNeeded(_ text: String, hash: String?, archiveRoot: URL, role: String) throws -> String? {
        guard !text.isEmpty, let hash else { return nil }
        let day = dayString(Date())
        let dir = historyRoot(in: archiveRoot)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(hash)-\(role).md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return relativePath(of: url, in: archiveRoot)
    }

    private static func append(_ event: GhostPepperHistoryEvent, archiveRoot: URL) throws {
        let dir = historyRoot(in: archiveRoot).appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(dayString(event.createdAt)).jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var line = try String(data: encoder.encode(event), encoding: .utf8) ?? "{}"
        line.append("\n")

        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            if let data = line.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func beforeSnapshotPathNeeded(operation: String) -> Bool {
        operation == "generated_proposal_preserved_user_edit"
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func relativePath(of url: URL, in root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base) else { return nil }
        var rel = String(full.dropFirst(base.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel.isEmpty ? nil : rel
    }
}
