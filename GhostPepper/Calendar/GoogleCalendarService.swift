import Foundation
import AppKit
import CommonCrypto
import os.log

private let calendarLog = Logger(subsystem: "com.github.matthartman.ghostpepper", category: "calendar")

private struct CalendarFetchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Reads Google Calendar events via OAuth 2.0 (PKCE flow for desktop apps).
/// Tokens are stored locally in Keychain and only sent to googleapis.com.
@MainActor
final class GoogleCalendarService: ObservableObject {
    static let shared = GoogleCalendarService()

    @Published var isSignedIn = false
    @Published var isLoading = false
    @Published var userName: String?
    @Published var authError: String?

    private static let clientID = Secrets.googleClientID
    private static let clientSecret = Secrets.googleClientSecret
    static var isConfigured: Bool {
        !clientID.isEmpty
            && !clientID.contains("YOUR_CLIENT_ID")
            && !clientSecret.contains("YOUR_CLIENT_SECRET")
    }
    // Google requires loopback redirect for desktop OAuth clients.
    // We bind to 127.0.0.1 only (not accessible from network), use a random port,
    // and shut down immediately after receiving the code.
    private static let loopbackHost = "http://127.0.0.1"
    // calendar.readonly lets us list calendars (calendarList) AND read events from each.
    // Existing connections issued with the old narrow scope will need to disconnect+reconnect.
    private static let scope = "https://www.googleapis.com/auth/calendar.readonly"
    private static let tokenKey = "googleCalendarAccessToken"
    private static let refreshTokenKey = "googleCalendarRefreshToken"
    private static let tokenExpiryKey = "googleCalendarTokenExpiry"

    private var accessToken: String? {
        get { KeychainHelper.get(Self.tokenKey) }
        set { _ = KeychainHelper.set(newValue ?? "", for: Self.tokenKey) }
    }

    private var refreshToken: String? {
        get { KeychainHelper.get(Self.refreshTokenKey) }
        set { _ = KeychainHelper.set(newValue ?? "", for: Self.refreshTokenKey) }
    }

    private var tokenExpiry: Date? {
        get { UserDefaults.standard.object(forKey: Self.tokenExpiryKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenExpiryKey) }
    }

    private var codeVerifier: String?
    private var oauthState: String?

    private init() {
        KeychainHelper.migrateUserDefaultsString(defaultsKey: Self.tokenKey, keychainKey: Self.tokenKey)
        KeychainHelper.migrateUserDefaultsString(defaultsKey: Self.refreshTokenKey, keychainKey: Self.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.diskCacheKey)
        isSignedIn = accessToken != nil
    }

    private var loopbackPort: UInt16 = 0
    private var activeServer: LoopbackOAuthServer?

    // MARK: - OAuth Flow

    /// Start the OAuth sign-in flow — starts a loopback server and opens the browser.
    func signIn() {
        authError = nil
        isLoading = true
        defer {
            if activeServer == nil {
                isLoading = false
            }
        }

        guard Self.isConfigured else {
            authError = "Google Calendar OAuth is not configured in this build."
            calendarLog.error("OAuth client is not configured")
            return
        }

        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let state = generateCodeVerifier()
        oauthState = state
        let challenge = generateCodeChallenge(from: verifier)

        // Start loopback server on a random port (127.0.0.1 only, not network-accessible)
        let server = LoopbackOAuthServer { [weak self] callback in
            Task { @MainActor [weak self] in
                guard let self, let verifier = self.codeVerifier, callback.state == self.oauthState else {
                    self?.codeVerifier = nil
                    self?.oauthState = nil
                    self?.activeServer = nil
                    return
                }
                self.codeVerifier = nil
                self.oauthState = nil
                self.activeServer = nil
                self.isLoading = true
                await self.exchangeCodeForToken(code: callback.code, verifier: verifier)
                self.isLoading = false
            }
        }
        activeServer = server
        guard let port = server.start() else {
            authError = "Could not start the local Google sign-in callback. Check the app sandbox network server entitlement."
            calendarLog.error("Failed to start loopback OAuth server")
            activeServer = nil
            return
        }
        loopbackPort = port

        let redirectURI = "\(Self.loopbackHost):\(port)"

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        guard let url = components.url else {
            authError = "Could not create the Google sign-in URL."
            calendarLog.error("Failed to create Google OAuth URL")
            activeServer = nil
            return
        }
        if !NSWorkspace.shared.open(url) {
            authError = "Could not open the Google sign-in page."
            calendarLog.error("NSWorkspace failed to open Google OAuth URL")
            activeServer = nil
        }
    }

    /// Sign out — clear stored tokens.
    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        UserDefaults.standard.removeObject(forKey: Self.diskCacheKey)
        isSignedIn = false
        userName = nil
    }

    // MARK: - Calendar API

    /// Fetch the meeting happening right now from Google Calendar.
    /// Skips all-day, declined, and not-yet-started/already-ended events.
    func currentMeeting() async -> CalendarEvent? {
        let result = await eventsForToday()
        let now = Date()
        let grace: TimeInterval = 2 * 60
        let candidates = result.events.filter { event in
            guard !event.isAllDay,
                  let s = event.startDate,
                  let e = event.endDate else { return false }
            return now >= s.addingTimeInterval(-grace) && now <= e
        }
        return candidates.sorted {
            ($0.startDate ?? .distantPast) > ($1.startDate ?? .distantPast)
        }.first
    }

    /// Result of an eventsForToday fetch. Carries an optional error so the UI can surface it.
    struct TodayResult {
        let events: [CalendarEvent]
        let errorMessage: String?
    }

    /// Fetch all of today's calendar events from every selected calendar on the account.
    /// Cached for 60 seconds in memory to avoid hammering the API on UI redraws,
    /// and persisted to disk so we can fall back to it when offline / API fails.
    func eventsForToday() async -> TodayResult {
        if let cached = todayCache, Date().timeIntervalSince(cached.fetchedAt) < 60 {
            return TodayResult(events: cached.events, errorMessage: nil)
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? Date()

        // First, get all the calendar IDs the user has selected. If listing fails (e.g. old
        // narrow scope), fall back to primary only so something still works.
        let calendarIDs: [String]
        let listResult = await fetchCalendarIDs()
        switch listResult {
        case .success(let ids) where !ids.isEmpty:
            calendarIDs = ids
        case .success:
            calendarIDs = ["primary"]
        case .failure(let listErr):
            calendarLog.error("eventsForToday: calendar list failed: \(listErr.message, privacy: .public)")
            // Try primary as a fallback.
            switch await fetchEvents(calendarID: "primary", timeMin: startOfDay, timeMax: endOfDay) {
            case .success(let events):
                rememberTodayCache(events)
                return TodayResult(events: events, errorMessage: "Couldn't list calendars (\(listErr.message)). Showing primary only — try Disconnect & Reconnect.")
            case .failure(let primaryErr):
                return fallbackToDiskCache(reason: "Calendar fetch failed: \(primaryErr.message)")
            }
        }

        var merged: [CalendarEvent] = []
        var lastError: String?
        var hadAnySuccess = false
        for calendarID in calendarIDs {
            switch await fetchEvents(calendarID: calendarID, timeMin: startOfDay, timeMax: endOfDay) {
            case .success(let events):
                hadAnySuccess = true
                merged.append(contentsOf: events)
            case .failure(let err):
                lastError = err.message
                calendarLog.error("eventsForToday: calendar \(calendarID, privacy: .public) failed: \(err.message, privacy: .public)")
            }
        }

        // If every calendar fetch failed, try the disk cache before giving up.
        if !hadAnySuccess {
            return fallbackToDiskCache(reason: "Calendar fetch failed: \(lastError ?? "unknown error")")
        }

        merged.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        var seen = Set<String>()
        let deduped = merged.filter { seen.insert($0.id).inserted }

        rememberTodayCache(deduped)
        return TodayResult(events: deduped, errorMessage: deduped.isEmpty ? lastError : nil)
    }

    func invalidateTodayCache() {
        todayCache = nil
    }

    private var todayCache: (events: [CalendarEvent], fetchedAt: Date)?

    // MARK: Disk-backed cache (offline fallback)

    private static let diskCacheKey = "calendarEventsTodayCache"

    private func rememberTodayCache(_ events: [CalendarEvent]) {
        let now = Date()
        todayCache = (events: events, fetchedAt: now)
    }

    private func fallbackToDiskCache(reason: String) -> TodayResult {
        UserDefaults.standard.removeObject(forKey: Self.diskCacheKey)
        return TodayResult(events: [], errorMessage: Self.userFacingCalendarError(from: reason))
    }

    static func userFacingCalendarError(from rawMessage: String) -> String {
        let lowercased = rawMessage.lowercased()
        if lowercased.contains("http 401")
            || lowercased.contains("invalid authentication credentials")
            || lowercased.contains("unauthorized")
            || lowercased.contains("no access token") {
            return "Google Calendar connection expired. Disconnect and reconnect to continue."
        }

        if lowercased.contains("http 403") || lowercased.contains("insufficient") {
            return "Google Calendar needs updated permissions. Disconnect and reconnect to continue."
        }

        if lowercased.contains("timed out")
            || lowercased.contains("not connected")
            || lowercased.contains("network")
            || lowercased.contains("offline") {
            return "Couldn't reach Google Calendar. Check your connection and try Refresh."
        }

        return "Couldn't load Google Calendar. Try Refresh, or Disconnect and reconnect."
    }

    private func fetchCalendarIDs() async -> Result<[String], CalendarFetchError> {
        guard let token = await validAccessToken() else {
            return .failure(CalendarFetchError(message: "no access token"))
        }
        let url = URL(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure(CalendarFetchError(message: "non-HTTP response"))
            }
            if http.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                calendarLog.error("fetchCalendarIDs failed: HTTP \(http.statusCode, privacy: .public), body: \(body.prefix(500), privacy: .private)")
                return .failure(CalendarFetchError(message: "HTTP \(http.statusCode)"))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                return .failure(CalendarFetchError(message: "malformed JSON"))
            }
            // Use only calendars currently selected in the user's UI (i.e. visible).
            let ids = items.compactMap { item -> String? in
                let id = item["id"] as? String
                let selected = (item["selected"] as? Bool) ?? false
                let primary = (item["primary"] as? Bool) ?? false
                return (selected || primary) ? id : nil
            }
            return .success(ids)
        } catch {
            return .failure(CalendarFetchError(message: "\(error)"))
        }
    }

    private func fetchEvents(calendarID: String, timeMin: Date, timeMax: Date) async -> Result<[CalendarEvent], CalendarFetchError> {
        guard let token = await validAccessToken() else {
            return .failure(CalendarFetchError(message: "no access token"))
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        let escapedID = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? calendarID
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(escapedID)/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: timeMin)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: timeMax)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "50"),
        ]

        guard let url = components.url else { return .failure(CalendarFetchError(message: "bad URL")) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(CalendarFetchError(message: "non-HTTP response"))
            }
            if httpResponse.statusCode != 200 {
                let body = String(data: data, encoding: .utf8) ?? ""
                calendarLog.error("fetchEvents failed: HTTP \(httpResponse.statusCode, privacy: .public), body: \(body.prefix(500), privacy: .private)")
                return .failure(CalendarFetchError(message: "HTTP \(httpResponse.statusCode)"))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                return .failure(CalendarFetchError(message: "malformed JSON"))
            }
            calendarLog.info("fetchEvents[\(calendarID, privacy: .public)]: \(items.count) raw, \(items.compactMap { Self.parseEventItem($0) }.count) parsed")
            return .success(items.compactMap { Self.parseEventItem($0) })
        } catch {
            return .failure(CalendarFetchError(message: "\(error)"))
        }
    }

    private static func parseEventItem(_ item: [String: Any]) -> CalendarEvent? {
        guard let summary = item["summary"] as? String else { return nil }
        let id = (item["id"] as? String) ?? UUID().uuidString

        let startBlock = item["start"] as? [String: Any]
        let endBlock = item["end"] as? [String: Any]

        let startDateTime = startBlock?["dateTime"] as? String
        let startDateOnly = startBlock?["date"] as? String
        let endDateTime = endBlock?["dateTime"] as? String
        let endDateOnly = endBlock?["date"] as? String

        let isAllDay = startDateTime == nil && startDateOnly != nil
        let startStr = startDateTime ?? startDateOnly ?? ""

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        func parseDateTime(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            return isoFormatter.date(from: s) ?? isoFormatterNoFrac.date(from: s)
        }
        func parseDateOnly(_ s: String?) -> Date? {
            guard let s, !s.isEmpty else { return nil }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone.current
            return f.date(from: s)
        }

        let startDate = parseDateTime(startDateTime) ?? parseDateOnly(startDateOnly)
        let endDate = parseDateTime(endDateTime) ?? parseDateOnly(endDateOnly)

        var attendees: [MeetingAttendee] = []
        var attendeeCount = 0
        var selfDeclined = false
        if let attendeeList = item["attendees"] as? [[String: Any]] {
            attendeeCount = attendeeList.count
            for attendee in attendeeList {
                let isSelf = (attendee["self"] as? Bool) ?? false
                let responseStatus = attendee["responseStatus"] as? String
                let declined = (responseStatus == "declined")
                if isSelf && declined {
                    selfDeclined = true
                }
                let name: String?
                if let displayName = attendee["displayName"] as? String {
                    name = displayName
                } else if let email = attendee["email"] as? String {
                    name = email.components(separatedBy: "@").first ?? email
                } else {
                    name = nil
                }
                if let name {
                    attendees.append(MeetingAttendee(name: name, declined: declined))
                }
            }
        }

        if selfDeclined { return nil }

        let organizer = (item["organizer"] as? [String: Any])?["displayName"] as? String
        let meetLink = Self.extractMeetingLink(from: item)

        return CalendarEvent(
            id: id,
            title: summary,
            startTime: startStr,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            attendees: attendees,
            attendeeCount: attendeeCount,
            organizer: organizer,
            meetLink: meetLink
        )
    }

    /// Extract a join URL from a Google Calendar event JSON, in priority order:
    /// 1. hangoutLink (Google Meet)
    /// 2. conferenceData.entryPoints[] first entry where entryPointType == "video"
    /// 3. URL in `location` matching a known conferencing host
    /// 4. URL in `description` matching a known conferencing host
    /// htmlLink is intentionally NOT used — it's the calendar event page, not a join URL.
    private static func extractMeetingLink(from item: [String: Any]) -> String? {
        if let link = item["hangoutLink"] as? String, !link.isEmpty {
            return link
        }
        if let conf = item["conferenceData"] as? [String: Any],
           let entryPoints = conf["entryPoints"] as? [[String: Any]] {
            for entry in entryPoints {
                if (entry["entryPointType"] as? String) == "video",
                   let uri = entry["uri"] as? String, !uri.isEmpty {
                    return uri
                }
            }
        }
        if let location = item["location"] as? String,
           let url = firstConferencingURL(in: location) {
            return url
        }
        if let description = item["description"] as? String,
           let url = firstConferencingURL(in: description) {
            return url
        }
        return nil
    }

    /// Find the first URL in a string whose host matches a known conferencing provider.
    private static func firstConferencingURL(in text: String) -> String? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let knownHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "whereby.com"]
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url, let host = url.host?.lowercased() else { continue }
            if knownHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return url.absoluteString
            }
        }
        return nil
    }

    // MARK: - Token Management

    private func validAccessToken() async -> String? {
        guard let token = accessToken else { return nil }

        // Check if token is expired
        if let expiry = tokenExpiry, Date() >= expiry {
            // Try to refresh
            if await refreshAccessToken() {
                return accessToken
            }
            return nil
        }

        return token
    }

    private func exchangeCodeForToken(code: String, verifier: String) async {
        var params = [
            "code": code,
            "client_id": Self.clientID,
            "redirect_uri": "\(Self.loopbackHost):\(loopbackPort)",
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        if !Self.clientSecret.isEmpty {
            params["client_secret"] = Self.clientSecret
        }

        guard let tokenData = await postTokenRequest(params: params) else { return }
        storeTokens(from: tokenData)
    }

    private func refreshAccessToken() async -> Bool {
        guard let refresh = refreshToken else { return false }

        var params = [
            "refresh_token": refresh,
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
        ]
        if !Self.clientSecret.isEmpty {
            params["client_secret"] = Self.clientSecret
        }

        guard let tokenData = await postTokenRequest(params: params) else { return false }
        storeTokens(from: tokenData)
        return true
    }

    private func postTokenRequest(params: [String: String]) async -> [String: Any]? {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch {
            print("GoogleCalendar: token request network error: \(error)")
            return nil
        }
        let (data, response) = result
        let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("GoogleCalendar: token response HTTP \(httpStatus), \(data.count) bytes")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("GoogleCalendar: failed to parse token response: \(String(data: data, encoding: .utf8) ?? "")")
            return nil
        }

        if let error = json["error"] as? String {
            print("GoogleCalendar: token error: \(error) — \(json["error_description"] ?? "")")
            return nil
        }

        return json
    }

    private func storeTokens(from json: [String: Any]) {
        if let token = json["access_token"] as? String {
            accessToken = token
        }
        if let refresh = json["refresh_token"] as? String {
            refreshToken = refresh
        }
        if let expiresIn = json["expires_in"] as? TimeInterval {
            tokenExpiry = Date().addingTimeInterval(expiresIn - 60) // Refresh 1 min early
        }
        isSignedIn = accessToken != nil
        print("GoogleCalendar: signed in successfully")
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Loopback OAuth Server

/// Minimal HTTP server bound to 127.0.0.1 (localhost only, not network-accessible).
/// Listens on a random port, accepts one request (the Google OAuth redirect),
/// extracts the auth code, sends a "success" page, and shuts down immediately.
/// This is Google's officially recommended approach for desktop OAuth apps.
private class LoopbackOAuthServer {
    struct Callback {
        let code: String
        let state: String?
    }

    private let onCode: (Callback) -> Void
    private var serverSocket: Int32 = -1

    init(onCode: @escaping (Callback) -> Void) {
        self.onCode = onCode
    }

    /// Start listening. Returns the assigned port, or nil on failure.
    func start() -> UInt16? {
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0 // Random port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(serverSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { close(serverSocket); return nil }
        guard listen(serverSocket, 1) == 0 else { close(serverSocket); return nil }

        // Get the assigned port
        var assignedAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &assignedAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(serverSocket, $0, &len) }
        }
        let port = UInt16(bigEndian: assignedAddr.sin_port)

        // Accept one connection in background
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let client = accept(serverSocket, nil, nil)
            defer { close(client); close(serverSocket) }
            guard client >= 0 else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(client, &buffer, buffer.count)
            let request = bytesRead > 0 ? String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? "" : ""

            // Extract query params from: GET /?code=AUTH_CODE&state=... HTTP/1.1
            var queryParams: [String: String] = [:]
            if let requestTarget = Self.httpRequestTarget(from: request),
               let queryStart = requestTarget.firstIndex(of: "?") {
                let query = String(requestTarget[requestTarget.index(after: queryStart)...])
                for param in query.components(separatedBy: "&") {
                    let kv = param.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 {
                        queryParams[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
                    }
                }
            }
            let authCode = queryParams["code"]
            let state = queryParams["state"]

            let html = authCode != nil
                ? Self.successHTML
                : Self.failureHTML
            let htmlData = Data(html.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(htmlData.count)\r\nConnection: close\r\n\r\n"
            _ = header.withCString { write(client, $0, strlen($0)) }
            htmlData.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    _ = write(client, base, htmlData.count)
                }
            }

            if let code = authCode {
                onCode(Callback(code: code, state: state))
            }
        }

        return port
    }

    private static func httpRequestTarget(from request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private static let successHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Ghost Pepper Connected</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #20272b; color: #f1f3f4; }
          main { text-align: center; max-width: 520px; padding: 48px 24px; }
          h1 { font-size: 32px; margin: 0 0 12px; }
          p { color: #aeb6ba; font-size: 17px; line-height: 1.45; margin: 0 0 24px; }
          a { display: inline-block; background: #ff8f2a; color: white; text-decoration: none; font-weight: 700; padding: 12px 18px; border-radius: 8px; }
        </style>
      </head>
      <body>
        <main>
          <h1>Ready to return to Ghost Pepper</h1>
          <p>Google Calendar is connected. You can close this tab, or jump back to the app.</p>
          <a href="com.github.matthartman.ghostpepper://calendar-connected">Return to Ghost Pepper</a>
        </main>
        <script>
          setTimeout(function () {
            window.location.href = "com.github.matthartman.ghostpepper://calendar-connected";
          }, 700);
        </script>
      </body>
    </html>
    """

    private static let failureHTML = """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Ghost Pepper Calendar Error</title>
        <style>
          body { margin: 0; min-height: 100vh; display: grid; place-items: center; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #20272b; color: #f1f3f4; }
          main { text-align: center; max-width: 520px; padding: 48px 24px; }
          h1 { font-size: 32px; margin: 0 0 12px; }
          p { color: #aeb6ba; font-size: 17px; line-height: 1.45; margin: 0; }
        </style>
      </head>
      <body>
        <main>
          <h1>Could not connect Calendar</h1>
          <p>Please return to Ghost Pepper and try connecting Google Calendar again.</p>
        </main>
      </body>
    </html>
    """
}

/// A calendar event with meeting metadata.
struct CalendarEvent: Identifiable, Codable {
    let id: String
    let title: String
    let startTime: String
    let startDate: Date?
    let endDate: Date?
    let isAllDay: Bool
    let attendees: [MeetingAttendee]
    let attendeeCount: Int
    let organizer: String?
    let meetLink: String?
}
