import Foundation

/// Pure translation between `ghostpepper://` URLs and the action core.
///
/// It parses an inbound URL into a `Request`, maps that to a `GhostPepperAction`,
/// and maps an action `Result` back onto an x-callback-url callback URL. It performs
/// no I/O and never opens anything — `AppDelegate` does the actual `NSWorkspace.open`,
/// which keeps this fully unit-testable without mocking AppKit.
///
/// Conventions follow the x-callback-url spec: host `x-callback-url`, action in the
/// path, reserved `x-source` / `x-success` / `x-error` / `x-cancel`, results appended
/// as query items to `x-success`, errors sent to `x-error` with `errorCode` +
/// `errorMessage`.
enum URLActionHandler {
    static let scheme = "ghostpepper"

    struct Request: Equatable {
        /// The action token (e.g. `start-meeting`).
        let action: String
        /// Non-reserved query items, decoded (last value wins on duplicates).
        let parameters: [String: String]
        let xSuccess: URL?
        let xError: URL?
        let xSource: String?
        let xCancel: URL?
    }

    // MARK: - Parsing

    /// Parse an inbound URL. Returns nil for a non-`ghostpepper` scheme or a URL with
    /// no resolvable action token.
    ///
    /// Action-token rule: if `host == "x-callback-url"`, the action is the first path
    /// segment; otherwise the action is the host. So
    /// `ghostpepper://x-callback-url/start-meeting` and `ghostpepper://stop-meeting`
    /// both resolve.
    static func parse(_ url: URL) -> Request? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        let host = components.host ?? ""
        let action: String
        if host == "x-callback-url" {
            guard let first = components.path.split(separator: "/").first else { return nil }
            action = String(first)
        } else if !host.isEmpty {
            action = host
        } else {
            return nil
        }

        var parameters: [String: String] = [:]
        var xSuccess: URL?
        var xError: URL?
        var xCancel: URL?
        var xSource: String?
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name {
            case "x-success": xSuccess = URL(string: value)
            case "x-error": xError = URL(string: value)
            case "x-cancel": xCancel = URL(string: value)
            case "x-source": xSource = value
            default: parameters[item.name] = value
            }
        }

        return Request(
            action: action,
            parameters: parameters,
            xSuccess: xSuccess,
            xError: xError,
            xSource: xSource,
            xCancel: xCancel
        )
    }

    /// Map a parsed request to an action, or a `BAD_REQUEST` for an unknown action or
    /// a missing required reference.
    static func action(for request: Request) -> Result<GhostPepperAction, GhostPepperActionError> {
        switch request.action {
        case "start-meeting":
            return .success(.startMeeting(name: request.parameters["name"]))
        case "stop-meeting":
            return .success(.stopMeeting)
        case "get-last-transcription":
            return .success(.getLastTranscription)
        case "get-status":
            return .success(.getStatus)
        case "summarize-meeting":
            return .success(.summarizeMeeting(meetingRef(from: request)))
        case "open-meeting":
            guard let ref = meetingRef(from: request) else {
                return .failure(.badRequest("open-meeting requires an id or path."))
            }
            return .success(.openMeeting(ref))
        default:
            return .failure(.badRequest("Unknown action \u{201C}\(request.action)\u{201D}."))
        }
    }

    /// `id` wins over `path` when both are present.
    private static func meetingRef(from request: Request) -> MeetingRef? {
        if let id = request.parameters["id"], !id.isEmpty { return .id(id) }
        if let path = request.parameters["path"], !path.isEmpty { return .path(path) }
        return nil
    }

    // MARK: - Callback mapping

    /// Map an action result to the callback URL to open, or nil for a no-op.
    ///
    /// On success: `.ok` opens `x-success` with no params; value-bearing results
    /// append their fields to `x-success` — but only if `x-success` is a non-web
    /// scheme (never hand transcript text or other payloads to `http`/`https`).
    /// A value action with no `x-success` is a no-op over URL.
    /// On failure: append `errorCode` + `errorMessage` to `x-error`.
    static func callbackURL(
        for request: Request,
        result: Result<GhostPepperActionResult, GhostPepperActionError>
    ) -> URL? {
        switch result {
        case .success(let payload):
            return successCallback(for: request, payload: payload)
        case .failure(let error):
            guard let xError = request.xError else { return nil }
            return appending(
                to: xError,
                items: [("errorCode", error.code.rawValue), ("errorMessage", error.message)]
            )
        }
    }

    private static func successCallback(for request: Request, payload: GhostPepperActionResult) -> URL? {
        switch payload {
        case .ok:
            // No payload, so opening any x-success leaks nothing.
            return request.xSuccess
        case .transcription(let text):
            return dataCallback(for: request, items: [("text", text)])
        case .meetingStarted(let id, let viewURL):
            return dataCallback(for: request, items: [("meetingID", id), ("viewURL", viewURL.absoluteString)])
        case .status(let recording, let appStatus, let meetingID, let meetingName):
            var items: [(String, String)] = [
                ("recording", recording ? "true" : "false"),
                ("appStatus", appStatus),
            ]
            if let meetingID { items.append(("meetingID", meetingID)) }
            if let meetingName { items.append(("meetingName", meetingName)) }
            return dataCallback(for: request, items: items)
        }
    }

    /// Value-bearing callback: drop `http`/`https` `x-success` so payloads
    /// never reach the web; no `x-success` is a no-op.
    private static func dataCallback(for request: Request, items: [(String, String)]) -> URL? {
        guard let xSuccess = request.xSuccess else { return nil }
        if isWebScheme(xSuccess) { return nil }
        return appending(to: xSuccess, items: items)
    }

    private static func isWebScheme(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    // MARK: - URL building

    /// The stable view URL returned by `start-meeting`:
    /// `ghostpepper://x-callback-url/open-meeting?id=<uuid>`.
    static func viewURL(forMeetingID id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "x-callback-url"
        components.path = "/open-meeting"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        // Safe to force-unwrap: scheme/host/path are valid and `id` is appended via
        // queryItems, which URLComponents percent-encodes.
        return components.url!
    }

    /// Append percent-encoded items to a callback URL, preserving its existing query
    /// items and fragment. Every appended value — including nested `ghostpepper://`
    /// URLs — is fully percent-encoded.
    private static func appending(to base: URL, items: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var encoded = components.percentEncodedQueryItems ?? []
        for (name, value) in items {
            encoded.append(URLQueryItem(name: name, value: percentEncode(value)))
        }
        components.percentEncodedQueryItems = encoded
        return components.url
    }

    /// RFC 3986 unreserved set only, so reserved characters (`:` `/` `?` `&` `=` `#` …)
    /// in appended values are always escaped.
    private static let unreserved: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
