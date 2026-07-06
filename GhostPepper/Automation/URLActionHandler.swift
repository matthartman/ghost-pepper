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
        case "copy-last-recording":
            return .success(.copyLastRecording)
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
    /// On success: `.ok` opens `x-success` with no params; value-bearing results append
    /// their fields to `x-success` — but only if `x-success` is a non-web scheme (never
    /// hand transcript text or other payloads to `http`/`https`). Two optional params
    /// shape the payload: `retParam` renames a single-value payload's key (and names the
    /// envelope under `retFormat=json`), and `retFormat=json` packs the whole payload into
    /// one JSON object. A value action with no `x-success` is a no-op over URL.
    /// On failure — including a callback-shaping `BAD_REQUEST` — append `errorCode` +
    /// `errorMessage` to `x-error`.
    static func callbackURL(
        for request: Request,
        result: Result<GhostPepperActionResult, GhostPepperActionError>
    ) -> URL? {
        switch result {
        case .success(let payload):
            switch successCallback(for: request, payload: payload) {
            case .success(let url): return url
            case .failure(let error): return errorCallback(for: request, error: error)
            }
        case .failure(let error):
            return errorCallback(for: request, error: error)
        }
    }

    private static func errorCallback(for request: Request, error: GhostPepperActionError) -> URL? {
        guard let xError = request.xError else { return nil }
        return appending(
            to: xError,
            items: [("errorCode", error.code.rawValue), ("errorMessage", error.message)]
        )
    }

    /// Shape a successful payload into the callback URL to open. `.success(url)` is that
    /// URL (nil = no-op); `.failure` is a shaping error the caller routes to `x-error`.
    private static func successCallback(
        for request: Request,
        payload: GhostPepperActionResult
    ) -> Result<URL?, GhostPepperActionError> {
        let fields = payloadFields(for: payload)

        // No payload (.ok): open x-success as-is — nothing to leak, so even web schemes are fine.
        guard !fields.isEmpty else { return .success(request.xSuccess) }

        let retParam = nonEmpty(request.parameters["retParam"])
        let retFormat = nonEmpty(request.parameters["retFormat"])

        // Validate the shaping combo before the delivery guards, so a malformed request
        // reaches x-error even when x-success is absent or a (dropped) web scheme.
        let useJSON: Bool
        if let retFormat {
            guard retFormat.lowercased() == "json" else {
                return .failure(.badRequest("Unsupported retFormat \u{201C}\(retFormat)\u{201D}; only json is supported."))
            }
            useJSON = true
        } else {
            useJSON = false
            // retParam alone renames the key of a single-value payload; a multi-value
            // payload needs retFormat=json so no field is silently dropped.
            if retParam != nil, fields.count > 1 {
                return .failure(.badRequest("retParam needs retFormat=json for the multi-value \(request.action) response."))
            }
        }

        // Value-bearing: no x-success is a no-op, and a web x-success is dropped so
        // payloads never reach http/https.
        guard let xSuccess = request.xSuccess else { return .success(nil) }
        guard !isWebScheme(xSuccess) else { return .success(nil) }

        if useJSON {
            guard let json = jsonPayload(from: fields) else {
                return .failure(.badRequest("Could not encode the \(request.action) response as JSON."))
            }
            return .success(appending(to: xSuccess, items: [(retParam ?? "payload", json)]))
        }

        if let retParam {
            // fields.count == 1 here (validated above), so retParam names its lone value.
            let (_, value) = fields[0]
            return .success(appending(to: xSuccess, items: [(retParam, value.queryValue)]))
        }

        return .success(appending(to: xSuccess, items: fields.map { name, value in (name, value.queryValue) }))
    }

    /// The success payload as ordered `(name, value)` fields; empty for `.ok`.
    private static func payloadFields(for payload: GhostPepperActionResult) -> [(String, PayloadValue)] {
        switch payload {
        case .ok:
            return []
        case .transcription(let text):
            return [("text", .string(text))]
        case .meetingStarted(let id, let viewURL):
            return [("meetingID", .string(id)), ("viewURL", .string(viewURL.absoluteString))]
        case .status(let recording, let appStatus, let meetingID, let meetingName):
            var fields: [(String, PayloadValue)] = [
                ("recording", .bool(recording)),
                ("appStatus", .string(appStatus)),
            ]
            if let meetingID { fields.append(("meetingID", .string(meetingID))) }
            if let meetingName { fields.append(("meetingName", .string(meetingName))) }
            return fields
        }
    }

    /// A payload field value. Query callbacks stringify it; `retFormat=json` keeps its JSON
    /// type — notably `recording` as a boolean, not the string "true".
    private enum PayloadValue {
        case string(String)
        case bool(Bool)

        var queryValue: String {
            switch self {
            case .string(let value): return value
            case .bool(let value): return value ? "true" : "false"
            }
        }
    }

    /// Encode payload fields as one JSON object string, with sorted keys for a stable result.
    private static func jsonPayload(from fields: [(String, PayloadValue)]) -> String? {
        var object: [String: Any] = [:]
        for (name, value) in fields {
            switch value {
            case .string(let string): object[name] = string
            case .bool(let bool): object[name] = bool
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
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
    /// items and fragment. Both name and value — including a caller-supplied `retParam`
    /// and nested `ghostpepper://` URLs — are fully percent-encoded. Names must be encoded
    /// too: the `percentEncodedQueryItems` setter traps on a raw reserved character.
    private static func appending(to base: URL, items: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var encoded = components.percentEncodedQueryItems ?? []
        for (name, value) in items {
            encoded.append(URLQueryItem(name: percentEncode(name), value: percentEncode(value)))
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
