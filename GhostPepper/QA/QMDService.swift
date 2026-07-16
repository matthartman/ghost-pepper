import Foundation
import CryptoKit

/// Bridges the meeting Q&A agent to `qmd` (github.com/tobi/qmd) — a local
/// hybrid search engine (BM25 + embeddings + rerank) for markdown. Gives the
/// agent a `search` tool for conceptual queries that grep's lexical matching
/// can't answer ("companies building environment capture for robotics").
///
/// Integration is CLI-transport, mirroring the existing `rg` pattern in
/// `MeetingQATools`: we spawn the user-installed `qmd` binary per call.
/// Everything stays on-device. When qmd isn't installed, `isAvailable` is
/// false and the Q&A agent simply doesn't get the search tool — grep still
/// works.
///
/// Install: `npm install -g @tobilu/qmd` (needs Node 22+ or Bun). First
/// index build downloads qmd's GGUF models (~2 GB) into the app's cache.
final class QMDService {
    struct Hit: Equatable {
        var path: String        // relative to archive root when possible
        var snippet: String
        var score: Double?
        var startLine: Int?
        var endLine: Int?
    }

    enum QMDError: LocalizedError {
        case notInstalled
        case commandFailed(String)
        case timedOut(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "qmd is not installed. Install with: npm install -g @tobilu/qmd"
            case .commandFailed(let message):
                return "qmd failed: \(message)"
            case .timedOut(let what):
                return "\(what) timed out."
            }
        }
    }

    let archiveRoot: URL

    private static var registeredCollections = Set<String>()
    private static var lastMaintenance: Date?
    private static let maintenanceLock = NSLock()

    init(archiveRoot: URL) {
        self.archiveRoot = archiveRoot
    }

    // MARK: - Availability

    static func detectBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/qmd",
            "/usr/local/bin/qmd",
            "\(home)/.bun/bin/qmd",
            "\(home)/.local/bin/qmd",
            "\(home)/.npm-global/bin/qmd",
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    var isAvailable: Bool { Self.detectBinary() != nil }

    /// One collection per archive directory, name derived from the path so
    /// multiple archives can't collide.
    var collectionName: String {
        let digest = SHA256.hash(data: Data(archiveRoot.standardizedFileURL.path.utf8))
        let hex = digest.prefix(5).map { String(format: "%02x", $0) }.joined()
        return "ghostpepper-\(hex)"
    }

    // MARK: - Search

    /// Runs a hybrid search and returns a grep-shaped tool result the agent
    /// can cite from (`path:line` ranges). Tries `qmd query` (hybrid) first,
    /// falling back to `qmd search` (BM25 only) if the vector stage isn't
    /// ready yet.
    func search(query: String, limit: Int) async throws -> String {
        guard isAvailable else { throw QMDError.notInstalled }
        await ensureCollectionRegistered()

        let k = max(1, min(limit, 20))
        var hits: [Hit]
        do {
            let out = try await runQMD(["query", query, "--json", "-n", "\(k)", "-c", collectionName], timeout: 120)
            hits = Self.parseHits(fromJSON: out)
        } catch {
            let out = try await runQMD(["search", query, "--json", "-n", "\(k)", "-c", collectionName], timeout: 60)
            hits = Self.parseHits(fromJSON: out)
        }

        let mapped = hits.map { mapToLines($0) }
        return Self.formatHits(mapped, query: query)
    }

    // MARK: - Collection lifecycle

    /// Registers the archive as a qmd collection (idempotent; qmd treats a
    /// duplicate add as an update/no-op, and we ignore its exit status).
    func ensureCollectionRegistered() async {
        let key = collectionName
        Self.maintenanceLock.lock()
        let alreadyRegistered = Self.registeredCollections.contains(key)
        Self.maintenanceLock.unlock()
        if alreadyRegistered { return }
        _ = try? await runQMD(
            ["collection", "add", archiveRoot.path, "--name", key, "--mask", "**/*.md"],
            timeout: 60
        )
        Self.maintenanceLock.lock()
        Self.registeredCollections.insert(key)
        Self.maintenanceLock.unlock()
    }

    /// Kicks a background `qmd update` + `qmd embed` so new meetings become
    /// searchable. Debounced to at most once per 10 minutes; runs detached
    /// with a generous timeout (first embed downloads models and embeds the
    /// whole corpus).
    func noteArchiveChanged() {
        guard isAvailable else { return }
        Self.maintenanceLock.lock()
        let last = Self.lastMaintenance
        let now = Date()
        if let last, now.timeIntervalSince(last) < 600 {
            Self.maintenanceLock.unlock()
            return
        }
        Self.lastMaintenance = now
        Self.maintenanceLock.unlock()

        let service = self
        Task.detached(priority: .utility) {
            await service.ensureCollectionRegistered()
            _ = try? await service.runQMD(["update", "-c", service.collectionName], timeout: 1800)
            _ = try? await service.runQMD(["embed", "-c", service.collectionName], timeout: 3600)
        }
    }

    // MARK: - Output parsing

    /// Defensive JSON parsing: qmd's exact `--json` shape isn't pinned, so
    /// accept a top-level array or an object wrapping one, and read fields
    /// under their likely names.
    static func parseHits(fromJSON raw: String) -> [Hit] {
        guard let data = raw.data(using: .utf8) else { return [] }
        let top = try? JSONSerialization.jsonObject(with: data)

        var items: [Any] = []
        if let array = top as? [Any] {
            items = array
        } else if let dict = top as? [String: Any] {
            for key in ["results", "hits", "documents", "matches", "data"] {
                if let array = dict[key] as? [Any] {
                    items = array
                    break
                }
            }
        }

        return items.compactMap { item -> Hit? in
            guard let d = item as? [String: Any] else { return nil }
            var path = ""
            for key in ["path", "file", "filepath", "filename", "relative_path"] {
                if let s = d[key] as? String, !s.isEmpty { path = s; break }
            }
            guard !path.isEmpty else { return nil }

            var snippet = ""
            for key in ["snippet", "text", "content", "body", "chunk", "excerpt"] {
                if let s = d[key] as? String, !s.isEmpty { snippet = s; break }
            }

            var score: Double?
            for key in ["score", "relevance", "similarity"] {
                if let n = d[key] as? NSNumber { score = n.doubleValue; break }
                if let s = d[key] as? String, let v = Double(s) { score = v; break }
            }

            var line: Int?
            for key in ["line", "line_start", "start_line", "lineStart"] {
                if let n = d[key] as? NSNumber { line = n.intValue; break }
            }

            return Hit(path: path, snippet: snippet, score: score, startLine: line, endLine: nil)
        }
    }

    /// Rebases an absolute path onto the archive root and locates the
    /// snippet's line range in the source file so citations are real
    /// `path:line` positions.
    func mapToLines(_ hit: Hit) -> Hit {
        var mapped = hit

        // Rebase absolute paths (and qmd://-style prefixes) to archive-relative.
        let rootPrefix = archiveRoot.standardizedFileURL.path + "/"
        if mapped.path.hasPrefix(rootPrefix) {
            mapped.path = String(mapped.path.dropFirst(rootPrefix.count))
        } else if let range = mapped.path.range(of: "://") {
            // "qmd://collection/2026-04-28/x.md" → strip scheme + collection.
            let after = String(mapped.path[range.upperBound...])
            let parts = after.split(separator: "/", maxSplits: 1)
            if parts.count == 2 { mapped.path = String(parts[1]) }
        }

        if mapped.startLine == nil, !mapped.snippet.isEmpty {
            let fileURL = archiveRoot.appendingPathComponent(mapped.path)
            if let content = try? String(contentsOf: fileURL, encoding: .utf8), content.utf8.count < 4_000_000 {
                let fileLines = content.components(separatedBy: "\n")
                let snippetLines = mapped.snippet.components(separatedBy: "\n")
                if let anchor = snippetLines.first(where: { $0.trimmingCharacters(in: .whitespaces).count >= 12 }) {
                    let needle = anchor.trimmingCharacters(in: .whitespaces)
                    for (i, line) in fileLines.enumerated() where line.contains(needle) {
                        mapped.startLine = i + 1
                        mapped.endLine = min(fileLines.count, i + snippetLines.count)
                        break
                    }
                }
            }
        }
        return mapped
    }

    /// Grep-shaped output so the agent reads/cites search results exactly
    /// like grep results.
    static func formatHits(_ hits: [Hit], query: String) -> String {
        guard !hits.isEmpty else {
            return "No results for: \(query)\n(Semantic search found nothing relevant — try grep with exact terms, or rephrase.)"
        }
        var blocks: [String] = []
        for hit in hits {
            var header = hit.path
            if let start = hit.startLine {
                header += ":\(start)"
                if let end = hit.endLine, end > start { header += "-\(end)" }
            }
            if let score = hit.score {
                header += String(format: " (score %.2f)", score)
            }
            var snippet = hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if snippet.count > 1200 {
                snippet = String(snippet.prefix(1200)) + "…"
            }
            blocks.append("\(header)\n\(snippet)")
        }
        var out = blocks.joined(separator: "\n--\n")
        out += "\n\n(\(hits.count) results from hybrid semantic+keyword search.)"
        return out
    }

    // MARK: - Process plumbing

    private func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.local/bin"]
        let current = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extra + [current]).joined(separator: ":")
        // Keep qmd's index + models in the app's cache so the sandboxed app
        // (and its children) can always reach them.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            env["XDG_CACHE_HOME"] = caches.appendingPathComponent("GhostPepper-qmd").path
        }
        return env
    }

    @discardableResult
    private func runQMD(_ arguments: [String], timeout: TimeInterval) async throws -> String {
        guard let binary = Self.detectBinary() else { throw QMDError.notInstalled }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            process.environment = processEnvironment()

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var didResume = false
            let resumeLock = NSLock()
            func resumeOnce(_ block: () -> Void) {
                resumeLock.lock(); defer { resumeLock.unlock() }
                guard !didResume else { return }
                didResume = true
                block()
            }

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                if process.isRunning {
                    process.terminate()
                    resumeOnce { continuation.resume(throwing: QMDError.timedOut("qmd \(arguments.first ?? "")")) }
                }
            }
            timer.resume()

            process.terminationHandler = { p in
                timer.cancel()
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                if p.terminationStatus == 0 {
                    resumeOnce { continuation.resume(returning: stdout) }
                } else {
                    let message = stderr.isEmpty ? "exit \(p.terminationStatus)" : String(stderr.prefix(400))
                    resumeOnce { continuation.resume(throwing: QMDError.commandFailed(message)) }
                }
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                resumeOnce { continuation.resume(throwing: error) }
            }
        }
    }
}
