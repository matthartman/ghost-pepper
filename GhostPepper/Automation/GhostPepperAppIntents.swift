import AppIntents

/// Shortcuts / Spotlight front-end over the shared action core. Each intent calls
/// `AppState.perform(_:)` and maps the typed result back. No app logic lives here.
///
/// Spotlight phrase surfacing on macOS 14 is weaker than on later releases; verify in
/// Shortcuts.app.

/// Bridges a `GhostPepperActionError` into a user-facing intent error.
struct GhostPepperIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

private enum GhostPepperIntentRunner {
    @MainActor
    static func run(_ action: GhostPepperAction) async throws -> GhostPepperActionResult {
        guard let appState = await AppState.ready() else {
            throw GhostPepperIntentError(message: "Ghost Pepper is still launching. Try again in a moment.")
        }
        switch await appState.perform(action) {
        case .success(let value):
            return value
        case .failure(let error):
            throw GhostPepperIntentError(message: error.message)
        }
    }
}

struct StartMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Meeting"
    static var description = IntentDescription("Start recording and transcribing a meeting. Prompts for consent unless you have turned that off.")
    static var openAppWhenRun = true

    @Parameter(title: "Name")
    var name: String?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await GhostPepperIntentRunner.run(.startMeeting(name: name))
        return .result(value: result.startedMeetingID ?? "")
    }
}

struct StopMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Meeting"
    static var description = IntentDescription("Stop the meeting that is currently recording.")

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await GhostPepperIntentRunner.run(.stopMeeting)
        return .result()
    }
}

struct GetLastTranscriptionIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Last Transcription"
    static var description = IntentDescription("Return the transcript of the most recent meeting.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await GhostPepperIntentRunner.run(.getLastTranscription)
        return .result(value: result.transcriptionText ?? "")
    }
}

struct CopyLastRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Last Recording"
    static var description = IntentDescription("Copy the transcript of your most recent recording to the clipboard, and return it.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await GhostPepperIntentRunner.run(.copyLastRecording)
        return .result(value: result.transcriptionText ?? "")
    }
}

struct GetMeetingStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Status"
    static var description = IntentDescription("Return whether Ghost Pepper is recording, and the app's current state.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = try await GhostPepperIntentRunner.run(.getStatus)
        return .result(value: result.statusAppStatus ?? "")
    }
}

struct SummarizeMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Summarize Meeting"
    static var description = IntentDescription("Summarize a meeting. Leave the id empty to summarize the active meeting.")
    // Summary generation runs a local-LLM pass; foreground the app so a
    // background-launched intent isn't killed mid-run.
    static var openAppWhenRun = true

    @Parameter(title: "Meeting ID")
    var meetingID: String?

    @MainActor
    func perform() async throws -> some IntentResult {
        let ref = meetingID.flatMap { $0.isEmpty ? nil : MeetingRef.id($0) }
        _ = try await GhostPepperIntentRunner.run(.summarizeMeeting(ref))
        return .result()
    }
}

struct OpenMeetingIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Meeting"
    static var description = IntentDescription("Open a saved meeting by its id.")
    static var openAppWhenRun = true

    @Parameter(title: "Meeting ID")
    var meetingID: String

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await GhostPepperIntentRunner.run(.openMeeting(.id(meetingID)))
        return .result()
    }
}

struct GhostPepperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartMeetingIntent(),
            phrases: ["Start a \(.applicationName) meeting"],
            shortTitle: "Start Meeting",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopMeetingIntent(),
            phrases: ["Stop the \(.applicationName) meeting"],
            shortTitle: "Stop Meeting",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: GetLastTranscriptionIntent(),
            phrases: ["Get the last \(.applicationName) transcription"],
            shortTitle: "Last Transcription",
            systemImageName: "text.quote"
        )
        AppShortcut(
            intent: CopyLastRecordingIntent(),
            phrases: ["Copy the last \(.applicationName) recording"],
            shortTitle: "Copy Last Recording",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: GetMeetingStatusIntent(),
            phrases: ["Get \(.applicationName) status"],
            shortTitle: "Status",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: SummarizeMeetingIntent(),
            phrases: ["Summarize the \(.applicationName) meeting"],
            shortTitle: "Summarize Meeting",
            systemImageName: "doc.text"
        )
    }
}
