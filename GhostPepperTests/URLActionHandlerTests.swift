import XCTest
@testable import GhostPepper

final class URLActionHandlerTests: XCTestCase {

    private func parse(_ string: String) -> URLActionHandler.Request? {
        guard let url = URL(string: string) else { return nil }
        return URLActionHandler.parse(url)
    }

    private func queryDict(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    // MARK: - Action-token parsing

    func testParsesActionFromCallbackPath() {
        let request = parse("ghostpepper://x-callback-url/start-meeting?name=Standup")
        XCTAssertEqual(request?.action, "start-meeting")
        XCTAssertEqual(request?.parameters["name"], "Standup")
    }

    func testParsesActionFromHostShorthand() {
        XCTAssertEqual(parse("ghostpepper://stop-meeting")?.action, "stop-meeting")
        XCTAssertEqual(parse("ghostpepper://x-callback-url/open-meeting?id=abc")?.action, "open-meeting")
    }

    func testRejectsNonGhostPepperScheme() {
        XCTAssertNil(parse("https://example.com/start-meeting"))
    }

    func testRejectsMissingActionToken() {
        XCTAssertNil(parse("ghostpepper://"))
        XCTAssertNil(parse("ghostpepper://x-callback-url"))
    }

    func testExtractsReservedParameters() {
        let request = parse("ghostpepper://x-callback-url/get-status?x-success=raycast://ok&x-error=raycast://err&x-source=Raycast&x-cancel=raycast://cancel")
        XCTAssertEqual(request?.xSuccess, URL(string: "raycast://ok"))
        XCTAssertEqual(request?.xError, URL(string: "raycast://err"))
        XCTAssertEqual(request?.xSource, "Raycast")
        XCTAssertEqual(request?.xCancel, URL(string: "raycast://cancel"))
        XCTAssertTrue(request?.parameters.isEmpty == true)
    }

    // MARK: - Action mapping

    func testMapsKnownActions() {
        XCTAssertEqual(map("ghostpepper://x-callback-url/start-meeting?name=Sync"), .startMeeting(name: "Sync"))
        XCTAssertEqual(map("ghostpepper://stop-meeting"), .stopMeeting)
        XCTAssertEqual(map("ghostpepper://get-last-transcription"), .getLastTranscription)
        XCTAssertEqual(map("ghostpepper://get-status"), .getStatus)
        XCTAssertEqual(map("ghostpepper://summarize-meeting"), .summarizeMeeting(nil))
        XCTAssertEqual(map("ghostpepper://x-callback-url/summarize-meeting?id=xyz"), .summarizeMeeting(.id("xyz")))
        XCTAssertEqual(map("ghostpepper://x-callback-url/open-meeting?path=2026-06-30/x.md"), .openMeeting(.path("2026-06-30/x.md")))
    }

    func testIdWinsOverPath() {
        XCTAssertEqual(map("ghostpepper://x-callback-url/open-meeting?id=abc&path=x.md"), .openMeeting(.id("abc")))
    }

    func testUnknownActionIsBadRequest() {
        XCTAssertEqual(mapError("ghostpepper://frobnicate")?.code, .badRequest)
    }

    func testOpenMeetingWithoutRefIsBadRequest() {
        XCTAssertEqual(mapError("ghostpepper://open-meeting")?.code, .badRequest)
    }

    private func map(_ string: String) -> GhostPepperAction? {
        guard let request = parse(string) else { return nil }
        if case .success(let action) = URLActionHandler.action(for: request) { return action }
        return nil
    }

    private func mapError(_ string: String) -> GhostPepperActionError? {
        guard let request = parse(string) else { return nil }
        if case .failure(let error) = URLActionHandler.action(for: request) { return error }
        return nil
    }

    // MARK: - Callback mapping: success

    func testOkOpensSuccessWithNoParams() {
        let request = parse("ghostpepper://x-callback-url/stop-meeting?x-success=raycast://done")!
        let callback = URLActionHandler.callbackURL(for: request, result: .success(.ok))
        XCTAssertEqual(callback, URL(string: "raycast://done"))
    }

    func testOkWithoutSuccessIsNoOp() {
        let request = parse("ghostpepper://stop-meeting")!
        XCTAssertNil(URLActionHandler.callbackURL(for: request, result: .success(.ok)))
    }

    func testValueActionWithoutSuccessIsNoOp() {
        let request = parse("ghostpepper://get-last-transcription")!
        XCTAssertNil(URLActionHandler.callbackURL(for: request, result: .success(.transcription(text: "hi"))))
    }

    func testTranscriptionAppendsText() {
        let request = parse("ghostpepper://x-callback-url/get-last-transcription?x-success=raycast://done")!
        let callback = URLActionHandler.callbackURL(for: request, result: .success(.transcription(text: "hello world")))
        XCTAssertEqual(queryDict(callback!)["text"], "hello world")
    }

    func testStatusAppendsFields() {
        let request = parse("ghostpepper://x-callback-url/get-status?x-success=raycast://done")!
        let result = GhostPepperActionResult.status(recording: true, appStatus: "recording", meetingID: "mid", meetingName: "Standup")
        let dict = queryDict(URLActionHandler.callbackURL(for: request, result: .success(result))!)
        XCTAssertEqual(dict["recording"], "true")
        XCTAssertEqual(dict["appStatus"], "recording")
        XCTAssertEqual(dict["meetingID"], "mid")
        XCTAssertEqual(dict["meetingName"], "Standup")
    }

    func testStatusOmitsNilMeetingFields() {
        let request = parse("ghostpepper://x-callback-url/get-status?x-success=raycast://done")!
        let result = GhostPepperActionResult.status(recording: false, appStatus: "idle", meetingID: nil, meetingName: nil)
        let dict = queryDict(URLActionHandler.callbackURL(for: request, result: .success(result))!)
        XCTAssertNil(dict["meetingID"])
        XCTAssertNil(dict["meetingName"])
    }

    // MARK: - Callback mapping: B0 web-scheme rejection

    func testHttpSuccessDoesNotReturnTranscript() {
        for scheme in ["http", "https"] {
            let request = parse("ghostpepper://x-callback-url/get-last-transcription?x-success=\(scheme)://evil.example")!
            XCTAssertNil(
                URLActionHandler.callbackURL(for: request, result: .success(.transcription(text: "secret"))),
                "\(scheme) x-success must not receive transcript text"
            )
        }
    }

    func testHttpSuccessDropsStatusPayload() {
        let request = parse("ghostpepper://x-callback-url/get-status?x-success=http://evil.example")!
        let result = GhostPepperActionResult.status(recording: true, appStatus: "recording", meetingID: "m", meetingName: "n")
        XCTAssertNil(URLActionHandler.callbackURL(for: request, result: .success(result)))
    }

    func testHttpSuccessDropsMeetingStartedPayload() {
        for scheme in ["http", "https"] {
            let request = parse("ghostpepper://x-callback-url/start-meeting?x-success=\(scheme)://evil.example")!
            let id = "22222222-2222-2222-2222-222222222222"
            let result = GhostPepperActionResult.meetingStarted(id: id, viewURL: URLActionHandler.viewURL(forMeetingID: id))
            XCTAssertNil(
                URLActionHandler.callbackURL(for: request, result: .success(result)),
                "\(scheme) x-success must not receive the meeting id / viewURL"
            )
        }
    }

    // MARK: - Callback mapping: meetingStarted round-trip

    func testMeetingStartedViewURLRoundTrips() {
        let request = parse("ghostpepper://x-callback-url/start-meeting?x-success=raycast://done")!
        let id = "11111111-1111-1111-1111-111111111111"
        let viewURL = URLActionHandler.viewURL(forMeetingID: id)
        let callback = URLActionHandler.callbackURL(for: request, result: .success(.meetingStarted(id: id, viewURL: viewURL)))!
        let dict = queryDict(callback)
        XCTAssertEqual(dict["meetingID"], id)
        // Decoding the appended (percent-encoded) viewURL yields the original URL.
        XCTAssertEqual(dict["viewURL"], viewURL.absoluteString)
        XCTAssertEqual(dict["viewURL"], "ghostpepper://x-callback-url/open-meeting?id=\(id)")
    }

    func testAppendingPreservesExistingQueryItems() {
        let request = parse("ghostpepper://x-callback-url/get-status?x-success=raycast://run%3Ffoo%3Dbar")!
        let result = GhostPepperActionResult.status(recording: false, appStatus: "idle", meetingID: nil, meetingName: nil)
        let dict = queryDict(URLActionHandler.callbackURL(for: request, result: .success(result))!)
        XCTAssertEqual(dict["foo"], "bar")
        XCTAssertEqual(dict["appStatus"], "idle")
    }

    func testValueWithSpecialCharactersIsEscaped() {
        let request = parse("ghostpepper://x-callback-url/get-last-transcription?x-success=raycast://done")!
        let text = "a&b=c d/e?f#g"
        let callback = URLActionHandler.callbackURL(for: request, result: .success(.transcription(text: text)))!
        // The raw query must be escaped (no stray separators), yet decode back to the original.
        XCTAssertFalse(callback.absoluteString.contains("a&b=c"))
        XCTAssertEqual(queryDict(callback)["text"], text)
    }

    // MARK: - Callback mapping: errors

    func testErrorGoesToErrorCallback() {
        let request = parse("ghostpepper://x-callback-url/open-meeting?id=missing&x-error=raycast://err")!
        let error = GhostPepperActionError.notFound("No meeting with id missing")
        let dict = queryDict(URLActionHandler.callbackURL(for: request, result: .failure(error))!)
        XCTAssertEqual(dict["errorCode"], "NOT_FOUND")
        XCTAssertEqual(dict["errorMessage"], "No meeting with id missing")
    }

    func testErrorWithoutErrorCallbackIsNoOp() {
        let request = parse("ghostpepper://open-meeting?id=missing")!
        let error = GhostPepperActionError.notFound("nope")
        XCTAssertNil(URLActionHandler.callbackURL(for: request, result: .failure(error)))
    }
}
