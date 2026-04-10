import Foundation

@MainActor
final class WhisperCppSpeechBackend {
    typealias TranscriptionOverride = @MainActor (
        SpeechModelDescriptor,
        URL,
        [Float],
        String?
    ) async throws -> String?
    typealias ExecutableURLOverride = @MainActor () -> URL?

    private let transcriptionOverride: TranscriptionOverride?
    private let executableURLOverride: ExecutableURLOverride?

    init(
        transcriptionOverride: TranscriptionOverride? = nil,
        executableURLOverride: ExecutableURLOverride? = nil
    ) {
        self.transcriptionOverride = transcriptionOverride
        self.executableURLOverride = executableURLOverride
    }

    func loadModel(
        _ model: SpeechModelDescriptor,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let modelURL = Self.modelURL(for: model)
        guard let executableURL = resolveExecutableURL() else {
            throw NSError(
                domain: "GhostPepper.WhisperCppSpeechBackend",
                code: 503,
                userInfo: [
                    NSLocalizedDescriptionKey: "whisper.cpp runtime not found. Install it with `brew install whisper-cpp`."
                ]
            )
        }

        try? FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !Self.modelIsCached(model) {
            guard let downloadURLString = model.downloadURL,
                  let downloadURL = URL(string: downloadURLString) else {
                throw NSError(
                    domain: "GhostPepper.WhisperCppSpeechBackend",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Missing download URL for \(model.name)"]
                )
            }

            try await downloadModel(from: downloadURL, to: modelURL, onProgress: onProgress)
        }

        try await validateModelLoad(modelURL: modelURL, executableURL: executableURL)
        return modelURL
    }

    func transcribe(
        model: SpeechModelDescriptor,
        modelURL: URL,
        audioBuffer: [Float],
        language: String?,
        debugLogger: ((DebugLogCategory, String) -> Void)? = nil
    ) async throws -> String? {
        if let transcriptionOverride {
            return try await transcriptionOverride(model, modelURL, audioBuffer, language)
        }

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            return nil
        }

        guard let executableURL = resolveExecutableURL() else {
            throw NSError(
                domain: "GhostPepper.WhisperCppSpeechBackend",
                code: 503,
                userInfo: [
                    NSLocalizedDescriptionKey: "whisper.cpp runtime not found. Install it with `brew install whisper-cpp`."
                ]
            )
        }

        let scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ghost-pepper-whispercpp-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let audioURL = scratchDirectory.appendingPathComponent("input.wav")
        let outputBaseURL = scratchDirectory.appendingPathComponent("transcript")
        let audioData = try AudioRecorder.serializePlayableArchiveAudioBuffer(audioBuffer)
        try audioData.write(to: audioURL)

        let arguments = [
            "--model", modelURL.path,
            "--file", audioURL.path,
            "--output-txt",
            "--output-file", outputBaseURL.path,
            "--no-prints",
            "--no-timestamps",
            "--language", normalizedLanguage(language),
        ]

        debugLogger?(.model, "Running whisper.cpp transcription with \(model.name).")
        try await runProcess(executableURL: executableURL, arguments: arguments)

        let transcriptURL = outputBaseURL.appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else {
            return nil
        }

        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func deleteCachedModel(_ model: SpeechModelDescriptor) {
        try? FileManager.default.removeItem(at: modelURL(for: model))
    }

    static func modelIsCached(_ model: SpeechModelDescriptor) -> Bool {
        FileManager.default.fileExists(atPath: modelURL(for: model).path)
    }

    static func modelURL(for model: SpeechModelDescriptor) -> URL {
        model.cachePathComponents.reduce(modelsDirectory) { partialURL, component in
            partialURL.appendingPathComponent(component, isDirectory: false)
        }
    }

    private static var modelsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("GhostPepper/whisper-cpp-models", isDirectory: true)
    }

    private func downloadModel(
        from url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = WhisperCppDownloadProgressDelegate(onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func resolveExecutableURL() -> URL? {
        if let executableURLOverride {
            return executableURLOverride()
        }

        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["GHOSTPEPPER_WHISPER_CPP_CLI"],
           !explicitPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: explicitPath) {
            return URL(fileURLWithPath: explicitPath)
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("whisper-cli")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        let fallbackPaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]

        for path in fallbackPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func normalizedLanguage(_ language: String?) -> String {
        guard let language else {
            return "auto"
        }

        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "auto" : trimmed
    }

    private func validateModelLoad(modelURL: URL, executableURL: URL) async throws {
        let scratchDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ghost-pepper-whispercpp-validate-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDirectory) }

        let audioURL = scratchDirectory.appendingPathComponent("validation.wav")
        let outputBaseURL = scratchDirectory.appendingPathComponent("validation")
        let silence = [Float](repeating: 0, count: 1_600)
        let audioData = try AudioRecorder.serializePlayableArchiveAudioBuffer(silence)
        try audioData.write(to: audioURL)

        try await runProcess(
            executableURL: executableURL,
            arguments: [
                "--model", modelURL.path,
                "--file", audioURL.path,
                "--duration", "100",
                "--output-txt",
                "--output-file", outputBaseURL.path,
                "--no-prints",
                "--no-timestamps",
                "--language", "en",
            ]
        )
    }

    private func runProcess(executableURL: URL, arguments: [String]) async throws {
        let outputPipe = Pipe()
        let outputBuffer = ProcessOutputBuffer()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let outputHandle = outputPipe.fileHandleForReading
            outputHandle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                outputBuffer.append(data)
            }

            process.terminationHandler = { process in
                outputHandle.readabilityHandler = nil
                outputBuffer.append(outputHandle.readDataToEndOfFile())
                let outputText = outputBuffer.text.trimmingCharacters(in: .whitespacesAndNewlines)

                if process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                    return
                }

                let message = outputText.isEmpty == false
                    ? outputText
                    : "whisper.cpp exited with status \(process.terminationStatus)."
                continuation.resume(
                    throwing: NSError(
                        domain: "GhostPepper.WhisperCppSpeechBackend",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )
                )
            }

            do {
                try process.run()
            } catch {
                outputHandle.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

private final class WhisperCppDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Handled by the async download(from:) call in WhisperCppSpeechBackend.
    }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(decoding: snapshot, as: UTF8.self)
    }
}
