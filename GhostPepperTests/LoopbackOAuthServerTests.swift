import XCTest
@testable import GhostPepper

/// The loopback server backs the Google Calendar OAuth redirect. It used to have no way to
/// stop, so abandoning sign-in left the port bound and the accept thread blocked for the
/// lifetime of the app.
final class LoopbackOAuthServerTests: XCTestCase {

    func testDeliversAuthorizationCodeFromRedirect() throws {
        let received = expectation(description: "callback delivered")
        var callback: LoopbackOAuthServer.Callback?

        let server = LoopbackOAuthServer {
            callback = $0
            received.fulfill()
        }
        defer { server.stop() }

        let port = try XCTUnwrap(server.start(), "server should bind a port")
        let client = try XCTUnwrap(Self.connect(toPort: port), "redirect should be accepted")
        defer { close(client) }

        let request = "GET /?code=test-auth-code&state=test-state HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        _ = request.withCString { write(client, $0, strlen($0)) }

        wait(for: [received], timeout: 5)
        XCTAssertEqual(callback?.code, "test-auth-code")
        XCTAssertEqual(callback?.state, "test-state")
    }

    func testStopReleasesListeningPort() throws {
        let server = LoopbackOAuthServer { _ in
            XCTFail("callback should not fire after the flow is abandoned")
        }

        let port = try XCTUnwrap(server.start(), "server should bind a port")
        server.stop()

        XCTAssertNil(Self.connect(toPort: port), "port should be released once the flow is abandoned")
    }

    func testStopIsIdempotent() throws {
        let server = LoopbackOAuthServer { _ in }
        _ = try XCTUnwrap(server.start(), "server should bind a port")

        server.stop()
        server.stop()
    }

    /// Opens a TCP connection to 127.0.0.1 on `port`, returning the socket or nil if refused.
    private static func connect(toPort port: UInt16) -> Int32? {
        let client = socket(AF_INET, SOCK_STREAM, 0)
        guard client >= 0 else { return nil }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(client)
            return nil
        }
        return client
    }
}
