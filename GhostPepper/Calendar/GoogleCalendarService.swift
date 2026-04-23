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

    private static let clientID = "132905683480-3iajprr7h347avmgpejodsladgnvartk.apps.googleusercontent.com"
    private static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"
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

    @Published var isWaitingForCode = false

    // MARK: - OAuth Flow

    /// Start the OAuth sign-in flow — opens browser, user copies code back.
    func signIn() {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = generateCodeChallenge(from: verifier)

        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]

        if let url = components.url {
            NSWorkspace.shared.open(url)
            isWaitingForCode = true
        }
    }

    /// Complete sign-in with the auth code the user copied from Google.
    func submitAuthCode(_ code: String) async {
        guard let verifier = codeVerifier else { return }
        codeVerifier = nil
        isWaitingForCode = false
        isLoading = true
        await exchangeCodeForToken(code: code.trimmingCharacters(in: .whitespacesAndNewlines), verifier: verifier)
        isLoading = false
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
            "redirect_uri": Self.redirectURI,
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

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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

/// A calendar event with meeting metadata.
struct CalendarEvent {
    let title: String
    let startTime: String
    let attendees: [String]
    let organizer: String?
    let meetLink: String?
}
