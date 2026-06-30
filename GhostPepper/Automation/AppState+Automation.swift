import Foundation

// MARK: - Shared instance + readiness gate

extension AppState {
    private static var sharedInstance: AppState?

    /// The live AppState once SwiftUI has constructed it. `nil` during cold launch,
    /// before the scene's `@StateObject` is built.
    static var shared: AppState? { sharedInstance }

    static func registerShared(_ instance: AppState) {
        sharedInstance = instance
    }

    /// Suspend until AppState exists, or give up after `timeout`. A URL or App Intent
    /// can launch the app before the scene is built; front-ends use this to map that
    /// race to `NOT_READY` rather than crash on a missing instance.
    static func ready(timeout: Duration = .seconds(8)) async -> AppState? {
        await poll(timeout: timeout, interval: .milliseconds(50)) { sharedInstance }
    }

    /// Sleeping suspends (does not block) the main actor.
    static func poll<T>(timeout: Duration, interval: Duration, _ predicate: () -> T?) async -> T? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let value = predicate() { return value }
            if ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: interval)
        }
    }
}

// MARK: - Dispatcher

extension AppState {
    /// The single automation boundary. The menu, configurable hotkeys, the
    /// `ghostpepper://` URL scheme, and App Intents all cross into the app here.
    func perform(_ action: GhostPepperAction) async -> Result<GhostPepperActionResult, GhostPepperActionError> {
        if action.requiresAutomationConsent, !allowAutomation {
            return .failure(.forbidden("Automation is disabled. Enable \u{201C}Allow automation\u{201D} in Settings."))
        }

        switch action {
        case .startMeeting(let name):
            return await startMeetingAction(name: name)
        case .stopMeeting:
            return stopMeetingAction()
        case .getLastTranscription:
            return await getLastTranscriptionAction()
        case .getStatus:
            return .success(statusSnapshot())
        case .summarizeMeeting(let ref):
            return await summarizeMeetingAction(ref)
        case .openMeeting(let ref):
            return await openMeetingAction(ref)
        }
    }

    // MARK: Start / stop

    private func startMeetingAction(name: String?) async -> Result<GhostPepperActionResult, GhostPepperActionError> {
        guard activeMeetingSession == nil else {
            return .failure(.conflict("A meeting is already being recorded."))
        }

        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let meetingName = (trimmed?.isEmpty == false) ? trimmed! : Self.generatedMeetingName()

        // Route through the existing consent path: this prompts unless the
        // user opted out globally, so a URL/Shortcut can't silently record.
        startMeetingTranscription(meetingName: meetingName)

        // Wait until the session exists and its first autosave has written the
        // `id:` frontmatter, so the returned viewURL resolves by-id. The wait is
        // bounded so a pending consent dialog can't block the URL queue indefinitely;
        // on timeout the meeting may still start, so report NOT_READY (retryable),
        // not FORBIDDEN.
        guard let session = await awaitMeetingFileReady(timeout: .seconds(30)) else {
            return .failure(.notReady("Recording did not start in time. If a consent prompt is open, approve it and retry."))
        }

        let id = session.transcript.sessionID.uuidString
        return .success(.meetingStarted(id: id, viewURL: URLActionHandler.viewURL(forMeetingID: id)))
    }

    private func stopMeetingAction() -> Result<GhostPepperActionResult, GhostPepperActionError> {
        guard activeMeetingSession != nil else {
            return .failure(.notFound("No meeting is currently being recorded."))
        }
        stopMeetingTranscription()
        return .success(.ok)
    }

    // MARK: Queries

    private func statusSnapshot() -> GhostPepperActionResult {
        // Ungated read-only snapshot. It includes the meeting name (can be sensitive),
        // but the web-scheme guard keeps it off http/https callbacks.
        let meeting = activeMeetingSession
        let recording = isRecording || (meeting?.isActive == true)
        return .status(
            recording: recording,
            appStatus: publicAppStatus,
            meetingID: meeting?.transcript.sessionID.uuidString,
            meetingName: meeting?.transcript.meetingName
        )
    }

    /// Internal `AppStatus` mapped to a small, frozen public vocabulary. Never
    /// expose the internal `rawValue` (Hyrum: don't freeze a UI string into the contract).
    private var publicAppStatus: String {
        if activeMeetingSession?.isActive == true { return "recording" }
        switch status {
        case .ready: return "idle"
        case .recording: return "recording"
        case .transcribing, .cleaningUp: return "transcribing"
        case .loading, .error: return "busy"
        }
    }

    private func getLastTranscriptionAction() async -> Result<GhostPepperActionResult, GhostPepperActionError> {
        if let active = activeMeetingSession, !active.transcript.segments.isEmpty {
            return .success(.transcription(text: active.transcript.plainText))
        }

        // Newest saved file that actually holds a transcript. Reader/article entries
        // share the archive but have no segments, so skip them. Directory scan runs
        // off the main actor; parsing builds a @MainActor transcript here.
        let saveDir = MeetingTranscriptSettings.effectiveSaveDirectory()
        let files = await Task.detached(operation: { Self.meetingFilesNewestFirst(in: saveDir) }).value
        for url in files {
            if let transcript = try? MeetingMarkdownWriter.parse(from: url), !transcript.segments.isEmpty {
                return .success(.transcription(text: transcript.plainText))
            }
        }
        return .failure(.notFound("No transcription available."))
    }

    // MARK: Summarize

    private func summarizeMeetingAction(_ ref: MeetingRef?) async -> Result<GhostPepperActionResult, GhostPepperActionError> {
        let transcript: MeetingTranscript
        if let ref {
            switch await resolveMeetingURL(for: ref) {
            case .success(let url):
                guard let parsed = try? MeetingMarkdownWriter.parse(from: url) else {
                    return .failure(.notFound("Could not read the meeting file."))
                }
                transcript = parsed
            case .failure(let error):
                return .failure(error)
            }
        } else {
            guard let active = activeMeetingSession else {
                return .failure(.notFound("No active meeting to summarize."))
            }
            transcript = active.transcript
        }

        guard !transcript.segments.isEmpty else {
            return .failure(.notFound("The meeting has no transcript to summarize."))
        }
        // Pre-check readiness: the generator swallows a not-loaded model into a nil
        // result, so map NOT_READY here before dispatching.
        guard textCleanupManager.isReady else {
            return .failure(.notReady("The summary model is not loaded yet."))
        }

        await generateMeetingSummary(for: transcript)
        return .success(.ok)
    }

    // MARK: Open

    /// Not gated by the opt-in: opening only navigates the local UI (no payload is
    /// returned), and `resolveMeetingURL` confines paths to the archive. `get-status`
    /// is likewise ungated; its payload still can't reach a web callback (see
    /// `URLActionHandler.dataCallback`).
    private func openMeetingAction(_ ref: MeetingRef) async -> Result<GhostPepperActionResult, GhostPepperActionError> {
        switch await resolveMeetingURL(for: ref) {
        case .success(let url):
            openSavedMeeting(at: url)
            return .success(.ok)
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: Resolution

    /// Resolve a `MeetingRef` to a file URL, rejecting path traversal and
    /// resolving ids via the active session, then the on-disk index.
    private func resolveMeetingURL(for ref: MeetingRef) async -> Result<URL, GhostPepperActionError> {
        let saveDir = MeetingTranscriptSettings.effectiveSaveDirectory()
        switch ref {
        case .path(let raw):
            guard raw.hasSuffix(".md") else {
                return .failure(.badRequest("Meeting path must end in .md"))
            }
            let url: URL
            do {
                url = try PathSandbox.resolveSafe(raw, root: saveDir)
            } catch {
                return .failure(.badRequest("Path is outside the meeting archive."))
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .failure(.notFound("No meeting at \(raw)"))
            }
            return .success(url)

        case .id(let raw):
            guard let uuid = UUID(uuidString: raw) else {
                return .failure(.badRequest("Invalid meeting id."))
            }
            if let active = activeMeetingSession, active.transcript.sessionID == uuid, let url = active.fileURL {
                return .success(url)
            }
            await meetingSessionIndex.ensureBuilt(from: saveDir)
            if let url = await meetingSessionIndex.resolve(uuid) {
                return .success(url)
            }
            return .failure(.notFound("No meeting with id \(raw)"))
        }
    }

    // MARK: Helpers

    private static func generatedMeetingName() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "Meeting \u{2014} \(formatter.string(from: Date()))"
    }

    /// Safe to call off the main actor. Each file is stat'd once (decorate-sort).
    nonisolated private static func meetingFilesNewestFirst(in baseDirectory: URL) -> [URL] {
        MeetingHistory.markdownFileURLs(in: baseDirectory)
            .map { ($0, MeetingHistory.modificationDate(of: $0)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Wait for the active meeting's first autosave (file URL set), or nil on timeout.
    private func awaitMeetingFileReady(timeout: Duration) async -> MeetingSession? {
        await Self.poll(timeout: timeout, interval: .milliseconds(100)) {
            activeMeetingSession?.fileURL != nil ? activeMeetingSession : nil
        }
    }
}
