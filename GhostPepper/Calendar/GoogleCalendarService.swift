import Foundation
import AppKit
import CommonCrypto

/// Reads Google Calendar events via OAuth 2.0 (PKCE flow for desktop apps).
/// Token is stored locally in UserDefaults — never sent anywhere except googleapis.com.
@MainActor
final class GoogleCalendarService: ObservableObject {
    static let shared = GoogleCalendarService()

    @Published var isSignedIn = false
    @Published var isLoading = false
    @Published var userName: String?

    private static let clientID = Secrets.googleClientID
    private static let clientSecret = Secrets.googleClientSecret
    // Google requires loopback redirect for desktop OAuth clients.
    // We bind to 127.0.0.1 only (not accessible from network), use a random port,
    // and shut down immediately after receiving the code.
    private static let loopbackHost = "http://127.0.0.1"
    private static let scope = "https://www.googleapis.com/auth/calendar.events.readonly"
    private static let tokenKey = "googleCalendarAccessToken"
    private static let refreshTokenKey = "googleCalendarRefreshToken"
    private static let tokenExpiryKey = "googleCalendarTokenExpiry"

    private var accessToken: String? {
        get { UserDefaults.standard.string(forKey: Self.tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenKey) }
    }

    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: Self.refreshTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.refreshTokenKey) }
    }

    private var tokenExpiry: Date? {
        get { UserDefaults.standard.object(forKey: Self.tokenExpiryKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Self.tokenExpiryKey) }
    }

    private var codeVerifier: String?

    private init() {
        isSignedIn = accessToken != nil
    }

    private var loopbackPort: UInt16 = 0
    private var activeServer: LoopbackOAuthServer?

    // MARK: - OAuth Flow

    /// Start the OAuth sign-in flow — starts a loopback server and opens the browser.
    func signIn() {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        // Start loopback server on a random port (127.0.0.1 only, not network-accessible)
        let server = LoopbackOAuthServer { [weak self] code in
            Task { @MainActor [weak self] in
                guard let self, let verifier = self.codeVerifier else { return }
                self.codeVerifier = nil
                self.activeServer = nil
                self.isLoading = true
                await self.exchangeCodeForToken(code: code, verifier: verifier)
                self.isLoading = false
            }
        }
        activeServer = server
        guard let port = server.start() else {
            print("GoogleCalendar: failed to start loopback server")
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
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sign out — clear stored tokens.
    func signOut() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        isSignedIn = false
        userName = nil
    }

    // MARK: - Calendar API

    /// Fetch the current or upcoming meeting from Google Calendar.
    /// Returns the event happening now (or starting within the next 5 minutes).
    func currentMeeting() async -> CalendarEvent? {
        guard let token = await validAccessToken() else { return nil }

        let now = Date()
        let soon = now.addingTimeInterval(5 * 60) // 5 minutes from now
        let earlier = now.addingTimeInterval(-5 * 60) // 5 minutes ago

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        components.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: earlier)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: soon)),
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "5"),
        ]

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return nil
        }

        // Find the event that's happening now or about to start
        for item in items {
            guard let summary = item["summary"] as? String else { continue }

            // Parse start time
            let start = item["start"] as? [String: Any]
            let startStr = (start?["dateTime"] as? String) ?? (start?["date"] as? String) ?? ""

            // Parse attendees
            var attendees: [String] = []
            if let attendeeList = item["attendees"] as? [[String: Any]] {
                for attendee in attendeeList {
                    if let name = attendee["displayName"] as? String {
                        attendees.append(name)
                    } else if let email = attendee["email"] as? String {
                        // Use email prefix as fallback name
                        attendees.append(email.components(separatedBy: "@").first ?? email)
                    }
                }
            }

            // Parse organizer
            let organizer = (item["organizer"] as? [String: Any])?["displayName"] as? String

            return CalendarEvent(
                title: summary,
                startTime: startStr,
                attendees: attendees,
                organizer: organizer,
                meetLink: (item["hangoutLink"] as? String) ?? (item["htmlLink"] as? String)
            )
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
        let params = [
            "code": code,
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "redirect_uri": "\(Self.loopbackHost):\(loopbackPort)",
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]

        guard let tokenData = await postTokenRequest(params: params) else { return }
        storeTokens(from: tokenData)
    }

    private func refreshAccessToken() async -> Bool {
        guard let refresh = refreshToken else { return false }

        let params = [
            "refresh_token": refresh,
            "client_id": Self.clientID,
            "client_secret": Self.clientSecret,
            "grant_type": "refresh_token",
        ]

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
    private let onCode: (String) -> Void
    private var serverSocket: Int32 = -1

    init(onCode: @escaping (String) -> Void) {
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

            // Extract code from: GET /?code=AUTH_CODE&scope=... HTTP/1.1
            var authCode: String?
            if let queryStart = request.range(of: "GET /?"),
               let httpEnd = request.range(of: " HTTP/") {
                let query = String(request[queryStart.upperBound..<httpEnd.lowerBound])
                for param in query.components(separatedBy: "&") {
                    let kv = param.components(separatedBy: "=")
                    if kv.count == 2, kv[0] == "code" {
                        authCode = kv[1].removingPercentEncoding ?? kv[1]
                    }
                }
            }

            let html = authCode != nil
                ? "<html><body style='font-family:system-ui;text-align:center;padding:60px'><h2>Connected to Ghost Pepper!</h2><p>You can close this tab.</p></body></html>"
                : "<html><body style='font-family:system-ui;text-align:center;padding:60px'><h2>Something went wrong</h2><p>Please try again from Ghost Pepper settings.</p></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.count)\r\nConnection: close\r\n\r\n\(html)"
            _ = response.withCString { write(client, $0, response.count) }

            if let code = authCode {
                onCode(code)
            }
        }

        return port
    }
}

/// A calendar event with meeting metadata.
struct CalendarEvent {
    let title: String
    let startTime: String
    let attendees: [String]
    let organizer: String?
    let meetLink: String?
}
