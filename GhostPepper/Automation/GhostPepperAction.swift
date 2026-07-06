import Foundation

/// The single action vocabulary shared by every automation front-end (menu,
/// configurable hotkeys, the `ghostpepper://` URL scheme, and App Intents). Front-ends
/// only *trigger* these; the behaviour lives in `AppState.perform(_:)`.
///
/// The surface is deliberately small: once exposed, every action becomes a caller
/// contract (Hyrum's law). Window navigation and the "+" menu's note / ad-hoc variants
/// are intentionally not actions — they call `AppState` methods directly.
enum GhostPepperAction: Equatable {
    /// Start a meeting transcription. `nil` name → a generated default name
    /// (the same path the in-app "+" menu uses). Subsumes note / ad-hoc.
    case startMeeting(name: String?)
    case stopMeeting
    case getLastTranscription
    /// Copy the newest Transcription Lab recording's text to the clipboard, app-side.
    /// Distinct from `getLastTranscription`, which reads the meeting archive.
    case copyLastRecording
    case getStatus
    /// `nil` ref → the active meeting.
    case summarizeMeeting(MeetingRef?)
    case openMeeting(MeetingRef)

    /// Whether this action needs the "Allow automation" opt-in. The read-only
    /// `getStatus` and the navigation-only `openMeeting` are always allowed;
    /// everything that records, returns transcript text, or summarizes is gated.
    var requiresAutomationConsent: Bool {
        switch self {
        case .getStatus, .openMeeting:
            return false
        case .startMeeting, .stopMeeting, .getLastTranscription, .copyLastRecording, .summarizeMeeting:
            return true
        }
    }
}

/// How a saved meeting is referenced. `id` resolves via the session id persisted
/// in the saved file's YAML frontmatter; `path` is relative to the archive root.
enum MeetingRef: Equatable {
    case id(String)
    case path(String)
}

/// Per-action result typing: value-returning actions carry typed payloads,
/// everything else returns generic success.
enum GhostPepperActionResult: Equatable {
    case ok
    case transcription(text: String)
    /// `id` is the session UUID; `viewURL` reopens the meeting.
    case meetingStarted(id: String, viewURL: URL)
    case status(recording: Bool, appStatus: String, meetingID: String?, meetingName: String?)

    var transcriptionText: String? {
        if case .transcription(let text) = self { return text }
        return nil
    }

    var startedMeetingID: String? {
        if case .meetingStarted(let id, _) = self { return id }
        return nil
    }

    var statusAppStatus: String? {
        if case .status(_, let appStatus, _, _) = self { return appStatus }
        return nil
    }
}

/// One error shape for the whole surface: a stable `code` plus a human-readable
/// `message`. The URL scheme sends both on `x-error`; App Intents surface the message.
struct GhostPepperActionError: Error, Equatable {
    /// Stable machine code. Keep this set small — it is part of the contract.
    let code: Code
    /// Human-readable detail. Put the specifics here, not in new codes.
    let message: String

    enum Code: String {
        /// Malformed request: unknown action, missing/invalid argument.
        case badRequest = "BAD_REQUEST"
        /// Referenced meeting or active session not found.
        case notFound = "NOT_FOUND"
        /// A required subsystem (e.g. the summary model) is not loaded yet.
        case notReady = "NOT_READY"
        /// Action rejected by current state, e.g. start while already recording.
        case conflict = "CONFLICT"
        /// Automation disabled, or consent denied.
        case forbidden = "FORBIDDEN"
    }

    static func badRequest(_ message: String) -> GhostPepperActionError { .init(code: .badRequest, message: message) }
    static func notFound(_ message: String) -> GhostPepperActionError { .init(code: .notFound, message: message) }
    static func notReady(_ message: String) -> GhostPepperActionError { .init(code: .notReady, message: message) }
    static func conflict(_ message: String) -> GhostPepperActionError { .init(code: .conflict, message: message) }
    static func forbidden(_ message: String) -> GhostPepperActionError { .init(code: .forbidden, message: message) }
}
