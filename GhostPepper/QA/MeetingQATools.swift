import Foundation

enum MeetingQAToolError: LocalizedError {
    case searchFailed(String)
    case grepFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case timedOut(String)
    case notADirectory(String)
    case fileNotFound(String)
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .searchFailed(let m): return "search failed: \(m)"
        case .grepFailed(let m): return "grep failed: \(m)"
        case .readFailed(let m): return "read failed: \(m)"
        case .writeFailed(let m): return "write failed: \(m)"
        case .timedOut(let what): return "\(what) timed out after 30s. Narrow scope and retry."
        case .notADirectory(let p): return "Not a directory: \(p)"
        case .fileNotFound(let p): return "File not found: \(p)"
        case .invalidArguments(let m): return "Invalid arguments: \(m)"
        }
    }
}

struct MeetingQATools {
    let root: URL
    private let timeout: TimeInterval = 30

    init(root: URL) {
        self.root = root
    }

    // MARK: - qmd_search

    func qmdSearch(query: String, path: String?, caseInsensitive: Bool, maxResults: Int) async throws -> String {
        let normalizedQuery = Self.normalizedLiteralQuery(query)
        let searchURL: URL
        if let path = path, !path.isEmpty, path != "." {
            searchURL = try PathSandbox.resolveSafe(path, root: root)
        } else {
            searchURL = root
        }

        let relativePath = relativePathInRoot(for: searchURL)
        if shouldUseQMD(query: normalizedQuery, relativePath: relativePath, caseInsensitive: caseInsensitive),
           let binary = Self.preferredQMDBinary() {
            do {
                let qmdOutput = try await qmdSearchWithBinary(binary, query: normalizedQuery, maxResults: maxResults)
                if !Self.isNoMatchesOutput(qmdOutput) {
                    return qmdOutput
                }

                let textOutput = try await recursiveTextSearch(query: normalizedQuery, searchURL: searchURL, caseInsensitive: caseInsensitive, maxResults: maxResults)
                if !Self.isNoMatchesOutput(textOutput) {
                    return textOutput + "\n(qmd returned no matches; used exact text fallback.)"
                }
                return qmdOutput
            } catch {
                // qmd is an optional local accelerator. If it is missing a
                // runtime dependency, has a stale index, or otherwise fails,
                // keep the Q&A flow alive with the legacy text search path.
            }
        }

        return try await recursiveTextSearch(query: normalizedQuery, searchURL: searchURL, caseInsensitive: caseInsensitive, maxResults: maxResults)
    }

    /// Compatibility alias for older prompts/traces and local-model recoveries
    /// that still emit a `grep` tool call.
    func grep(pattern: String, path: String?, caseInsensitive: Bool, maxResults: Int) async throws -> String {
        try await qmdSearch(query: pattern, path: path, caseInsensitive: caseInsensitive, maxResults: maxResults)
    }

    // MARK: - exact text fallback

    private func recursiveTextSearch(query: String, searchURL: URL, caseInsensitive: Bool, maxResults: Int) async throws -> String {
        let files = try markdownFiles(in: searchURL)
        let cap = max(1, min(maxResults, 200))
        var groups: [[String]] = []

        for file in files {
            let content: String
            do {
                content = try String(contentsOf: file, encoding: .utf8)
            } catch {
                continue
            }

            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let searchableQuery = caseInsensitive ? query.lowercased() : query
            for (index, line) in lines.enumerated() {
                let searchableLine = caseInsensitive ? line.lowercased() : line
                guard searchableLine.contains(searchableQuery) else { continue }

                let lineNumber = index + 1
                let start = max(0, index - 2)
                let end = min(lines.count - 1, index + 2)
                let relative = relativePathInRoot(for: file) ?? file.lastPathComponent
                let block = (start...end).map { contextIndex in
                    let contextLineNumber = contextIndex + 1
                    let separator = contextLineNumber == lineNumber ? ":" : "-"
                    return "\(relative)\(separator)\(contextLineNumber)\(separator)\(lines[contextIndex])"
                }
                groups.append(block)
                if groups.count >= cap { break }
            }
            if groups.count >= cap { break }
        }

        guard !groups.isEmpty else {
            return "No matches found for query: \(query)"
        }

        var output = groups.map { $0.joined(separator: "\n") }.joined(separator: "\n--\n")
        if !output.isEmpty { output += "\n" }
        if groups.count >= cap {
            output += "\n(Returned \(groups.count) match groups; max_results hit. Increase max_results or narrow the query.)"
        } else {
            output += "\n(Returned \(groups.count) of \(groups.count) match groups.)"
        }
        return output
    }

    private func markdownFiles(in searchURL: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchURL.path, isDirectory: &isDirectory) else {
            throw MeetingQAToolError.fileNotFound(relativePathInRoot(for: searchURL) ?? searchURL.path)
        }

        if !isDirectory.boolValue {
            return searchURL.pathExtension.lowercased() == "md" ? [searchURL] : []
        }

        guard let enumerator = FileManager.default.enumerator(
            at: searchURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MeetingQAToolError.notADirectory(relativePathInRoot(for: searchURL) ?? searchURL.path)
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".git" {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "md" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
            guard values?.isRegularFile == true, values?.isHidden != true else { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    // MARK: - process text search fallback

    private func recursiveGrep(pattern: String, searchURL: URL, caseInsensitive: Bool, maxResults: Int) async throws -> String {
        let backend = Self.preferredTextSearchBackend()
        // -B/-A include 2 lines before/after each match so weak local models
        // get context "for free" without needing a follow-up read_file. grep
        // emits "--" separators between non-adjacent match groups; we split
        // on those and cap by group count rather than raw line count.
        let binary: String
        let args: [String]
        switch backend {
        case .ripgrep(let path):
            binary = path
            var rgArgs: [String] = ["-n", "-g", "*.md", "-g", "!.git/**", "-B", "2", "-A", "2"]
            if caseInsensitive { rgArgs.append("-i") }
            rgArgs.append("--")
            rgArgs.append(pattern)
            rgArgs.append(searchURL.path)
            args = rgArgs
        case .grep(let path):
            binary = path
            var grepArgs: [String] = ["-r", "-n", "--include=*.md", "--exclude-dir=.git", "-B", "2", "-A", "2"]
            if caseInsensitive { grepArgs.append("-i") }
            grepArgs.append("-e")
            grepArgs.append(pattern)
            grepArgs.append(searchURL.path)
            args = grepArgs
        }

        let result = try await runProcess(launchPath: binary, arguments: args, timeoutDescription: "grep")
        if result.exitCode > 1 {
            throw MeetingQAToolError.grepFailed(result.stderr.isEmpty ? "exit \(result.exitCode)" : result.stderr)
        }
        if result.exitCode == 1 {
            return "No matches found for pattern: \(pattern)"
        }

        let allBlocks = result.stdout
            .components(separatedBy: "\n--\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let totalBlocks = allBlocks.count
        let cap = max(1, min(maxResults, 200))
        let truncated = Array(allBlocks.prefix(cap))

        let rebased = truncated.map { block -> String in
            block.split(separator: "\n", omittingEmptySubsequences: true)
                .map { line -> String in
                    let s = String(line)
                    if s.hasPrefix(root.path + "/") {
                        return String(s.dropFirst(root.path.count + 1))
                    }
                    return s
                }
                .joined(separator: "\n")
        }
        var output = rebased.joined(separator: "\n--\n")
        if !output.isEmpty { output += "\n" }
        if totalBlocks > cap {
            output += "\n(Returned \(cap) of \(totalBlocks) match groups; max_results hit. Increase max_results or narrow the pattern.)"
        } else {
            output += "\n(Returned \(totalBlocks) of \(totalBlocks) match groups.)"
        }
        return output
    }

    private func qmdSearchWithBinary(_ binary: String, query: String, maxResults: Int) async throws -> String {
        try await ensureQMDIndex(binary)

        let cap = max(1, min(maxResults, 200))
        // Ask qmd for a slightly larger candidate set so filtering and chunk
        // overlap don't hide useful meeting hits before we apply max_results.
        let candidateLimit = min(max(cap * 3, cap), 200)
        let result = try await runProcess(
            launchPath: binary,
            arguments: ["search", query, "--json", "--line-numbers", "-n", "\(candidateLimit)", "-c", qmdCollectionName],
            workingDirectory: root,
            timeoutDescription: "qmd search"
        )
        guard result.exitCode == 0 else {
            throw MeetingQAToolError.searchFailed(result.stderr.isEmpty ? "qmd search exited \(result.exitCode)" : result.stderr)
        }

        let matches = Self.parseQMDSearchResults(result.stdout, collectionName: qmdCollectionName)
            .filter { Self.isMeetingMarkdownPath($0.relativePath) }
        guard !matches.isEmpty else {
            return "No matches found for query: \(query)"
        }

        let limited = Array(matches.prefix(cap))
        let blocks = try await limited.mapAsync { match in
            try await qmdContextBlock(binary: binary, match: match)
        }

        var output = blocks.joined(separator: "\n--\n")
        if !output.isEmpty { output += "\n" }
        if matches.count > cap {
            output += "\n(Returned \(cap) of \(matches.count) qmd search results; max_results hit. Increase max_results or narrow the query.)"
        } else {
            output += "\n(Returned \(matches.count) of \(matches.count) qmd search results.)"
        }
        return output
    }

    private func qmdContextBlock(binary: String, match: QMDSearchResult) async throws -> String {
        let startLine = max(1, match.line - 2)
        let result = try await runProcess(
            launchPath: binary,
            arguments: ["get", "\(match.file):\(startLine)", "-l", "5", "--line-numbers"],
            workingDirectory: root,
            timeoutDescription: "qmd get"
        )
        guard result.exitCode == 0 else {
            return "\(match.relativePath):\(match.line):\(match.title)"
        }
        return Self.formatQMDContext(
            result.stdout,
            relativePath: match.relativePath,
            matchLine: match.line,
            fallbackTitle: match.title
        )
    }

    private func ensureQMDIndex(_ binary: String) async throws {
        let initResult = try await runProcess(
            launchPath: binary,
            arguments: ["init"],
            workingDirectory: root,
            timeoutDescription: "qmd init"
        )
        guard initResult.exitCode == 0 else {
            throw MeetingQAToolError.searchFailed(initResult.stderr.isEmpty ? "qmd init exited \(initResult.exitCode)" : initResult.stderr)
        }

        let addResult = try await runProcess(
            launchPath: binary,
            arguments: ["collection", "add", ".", "--name", qmdCollectionName],
            workingDirectory: root,
            timeoutDescription: "qmd collection add"
        )
        let addOutput = addResult.stdout + addResult.stderr
        if addResult.exitCode != 0 && !addOutput.contains("already exists") {
            throw MeetingQAToolError.searchFailed(addOutput.isEmpty ? "qmd collection add exited \(addResult.exitCode)" : addOutput)
        }

        let updateResult = try await runProcess(
            launchPath: binary,
            arguments: ["update"],
            workingDirectory: root,
            timeoutDescription: "qmd update"
        )
        guard updateResult.exitCode == 0 else {
            throw MeetingQAToolError.searchFailed(updateResult.stderr.isEmpty ? "qmd update exited \(updateResult.exitCode)" : updateResult.stderr)
        }
    }

    // MARK: - read_file

    func readFile(path: String, offset: Int, limit: Int) async throws -> String {
        let resolved = try PathSandbox.resolveSafe(path, root: root)
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            throw MeetingQAToolError.fileNotFound(path)
        }
        let content: String
        do {
            content = try String(contentsOf: resolved, encoding: .utf8)
        } catch {
            throw MeetingQAToolError.readFailed("\(path): \(error.localizedDescription)")
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        let totalLines = lines.count
        let safeOffset = max(1, offset)
        let safeLimit = max(1, min(limit, 1000))

        let startIndex = safeOffset - 1
        guard startIndex < totalLines else {
            return "(File has \(totalLines) lines; requested offset=\(safeOffset) is past end of file.)"
        }
        let endExclusive = min(startIndex + safeLimit, totalLines)
        let slice = lines[startIndex..<endExclusive]
        let numbered = slice.enumerated().map { (i, line) in
            "\(safeOffset + i)\t\(line)"
        }.joined(separator: "\n")

        let footer: String
        if endExclusive >= totalLines {
            footer = "\n\n(End of file at line \(totalLines).)"
        } else {
            footer = "\n\n(Returned lines \(safeOffset)-\(endExclusive) of \(totalLines). Use offset=\(endExclusive + 1) to continue.)"
        }
        return numbered + footer
    }

    // MARK: - write_file

    /// Writes (or overwrites) a `.md` file inside the sandbox root. Paths must be
    /// flat filenames (no subdirectories) ending in `.md` and must not start with
    /// `.` or `_` — this prevents the agent from clobbering `_manifest.json` or
    /// hidden bookkeeping files.
    func writeFile(path: String, content: String) async throws -> String {
        guard !path.isEmpty else {
            throw MeetingQAToolError.invalidArguments("write_file requires a non-empty path")
        }
        guard !path.contains("/") else {
            throw MeetingQAToolError.invalidArguments("write_file path must be a flat filename (no '/')")
        }
        guard path.hasSuffix(".md") else {
            throw MeetingQAToolError.invalidArguments("write_file only writes .md files; got: \(path)")
        }
        guard !path.hasPrefix(".") && !path.hasPrefix("_") else {
            throw MeetingQAToolError.invalidArguments("write_file rejects paths starting with '.' or '_'")
        }

        let resolved = try PathSandbox.resolveSafe(path, root: root)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try content.write(to: resolved, atomically: true, encoding: .utf8)
        } catch {
            throw MeetingQAToolError.writeFailed("\(path): \(error.localizedDescription)")
        }
        let bytes = content.utf8.count
        return "Wrote \(bytes) bytes to \(path)"
    }

    // MARK: - list_dir

    func listDir(path: String) async throws -> String {
        let resolved = try PathSandbox.resolveSafe(path, root: root)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue else {
            throw MeetingQAToolError.notADirectory(path.isEmpty ? "." : path)
        }
        let entries = try FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let formatted: [String] = try entries.map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            let name = url.lastPathComponent
            return (values.isDirectory ?? false) ? "\(name)/" : name
        }
        return formatted.sorted().joined(separator: "\n")
    }

    // MARK: - Process plumbing

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runProcess(
        launchPath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        timeoutDescription: String
    ) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory

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
                    resumeOnce { continuation.resume(throwing: MeetingQAToolError.timedOut(timeoutDescription)) }
                }
            }
            timer.resume()

            process.terminationHandler = { p in
                timer.cancel()
                let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                resumeOnce { continuation.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, exitCode: p.terminationStatus)) }
            }

            do {
                try process.run()
            } catch {
                timer.cancel()
                resumeOnce { continuation.resume(throwing: error) }
            }
        }
    }

    private enum TextSearchBackend {
        case ripgrep(String)
        case grep(String)
    }

    private static func preferredTextSearchBackend() -> TextSearchBackend {
        let candidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return .ripgrep(c)
        }
        return .grep("/usr/bin/grep")
    }

    private static func preferredQMDBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/qmd", "/usr/local/bin/qmd"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    private var qmdCollectionName: String {
        "meetings_\(Self.stableHexHash(root.standardizedFileURL.path))"
    }

    private struct QMDSearchResult {
        let file: String
        let relativePath: String
        let line: Int
        let title: String
    }

    private func relativePathInRoot(for url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        guard targetPath != rootPath else { return nil }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard targetPath.hasPrefix(prefix) else { return nil }
        return String(targetPath.dropFirst(prefix.count))
    }

    private func shouldUseQMD(query: String, relativePath: String?, caseInsensitive: Bool) -> Bool {
        guard relativePath == nil else { return false }
        guard caseInsensitive else { return false }
        guard !Self.looksLikeRegex(query) else { return false }
        return true
    }

    private static func looksLikeRegex(_ query: String) -> Bool {
        let regexCharacters = CharacterSet(charactersIn: #"[](){}.*+?|^$\"#)
        return query.rangeOfCharacter(from: regexCharacters) != nil
    }

    private static func normalizedLiteralQuery(_ query: String) -> String {
        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let quotePairs: [(Character, Character)] = [
            ("\"", "\""),
            ("“", "”"),
            ("'", "'"),
            ("‘", "’"),
        ]
        for (open, close) in quotePairs where trimmed.first == open && trimmed.last == close && trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
            return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func isNoMatchesOutput(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("no matches found for query:") || trimmed.hasPrefix("no matches found for pattern:")
    }

    private static func stableHexHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    private static func parseQMDSearchResults(_ stdout: String, collectionName: String) -> [QMDSearchResult] {
        guard let data = stdout.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { item in
            guard let file = item["file"] as? String,
                  let relativePath = qmdRelativePath(from: file, collectionName: collectionName) else {
                return nil
            }
            let line = (item["line"] as? Int) ?? 1
            let title = (item["title"] as? String) ?? relativePath
            return QMDSearchResult(file: file, relativePath: relativePath, line: max(1, line), title: title)
        }
    }

    private static func qmdRelativePath(from file: String, collectionName: String) -> String? {
        let prefix = "qmd://\(collectionName)/"
        if file.hasPrefix(prefix) {
            let raw = String(file.dropFirst(prefix.count))
            return raw.removingPercentEncoding ?? raw
        }
        return nil
    }

    private static func isMeetingMarkdownPath(_ path: String) -> Bool {
        guard path.hasSuffix(".md") else { return false }
        let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return false }
        return first.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func formatQMDContext(
        _ stdout: String,
        relativePath: String,
        matchLine: Int,
        fallbackTitle: String
    ) -> String {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        let formatted = lines.compactMap { rawLine -> String? in
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let numberText = line[..<colon]
            guard let lineNumber = Int(numberText.trimmingCharacters(in: .whitespaces)) else { return nil }
            var content = String(line[line.index(after: colon)...])
            if content.hasPrefix(" ") { content.removeFirst() }
            if lineNumber == matchLine {
                return "\(relativePath):\(lineNumber):\(content)"
            }
            return "\(relativePath)-\(lineNumber)-\(content)"
        }
        if formatted.isEmpty {
            return "\(relativePath):\(matchLine):\(fallbackTitle)"
        }
        return formatted.joined(separator: "\n")
    }
}

private extension Array {
    func mapAsync<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
