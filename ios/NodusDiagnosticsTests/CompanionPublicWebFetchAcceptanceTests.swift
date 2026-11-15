import CryptoKit
import Foundation
import XCTest
@testable import Nodus

/// Explicit online acceptance, intentionally in the opt-in NodusDiagnostics
/// scheme rather than ordinary NodusTests. No provider credentials or paid calls.
/// Select only this class and set NODUS_ACCEPTANCE_PUBLIC_WEB=1 in its test-host
/// environment. Missing authorization is a setup failure, never a passing skip.
final class CompanionPublicWebFetchAcceptanceTests: XCTestCase {
    private enum SetupError: Error { case explicitPublicWebAcceptanceRequired }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_PUBLIC_WEB"] == "1" else {
            XCTFail("Set NODUS_ACCEPTANCE_PUBLIC_WEB=1 for this explicitly selected online acceptance class.")
            throw SetupError.explicitPublicWebAcceptanceRequired
        }
        executionTimeAllowance = 90
    }

    func testRealHTTPSHTMLReturnsBoundedReadableContent() async throws {
        let limit = 64 * 1_024
        let result = try await CompanionPublicWebFetch.fetch("https://www.iana.org/help/example-domains", limit: limit)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.url.scheme, "https")
        XCTAssertEqual(result.url.host, "www.iana.org")
        XCTAssertTrue(result.headers["content-type"]?.lowercased().contains("text/html") == true)
        XCTAssertGreaterThan(result.data.count, 100)
        XCTAssertLessThanOrEqual(result.data.count, limit)
        let html = try XCTUnwrap(String(data: result.data, encoding: .utf8))
        XCTAssertTrue(html.contains("Example Domains"))
        XCTAssertTrue(html.contains("documentation"), "IANA must return its real explanation of reserved example domains.")
        record(result, name: "public-web-example-html")
    }

    func testRealHTTPSCommonsJSONPreservesStructuredSource() async throws {
        let limit = 256 * 1_024
        let url = "https://commons.wikimedia.org/w/api.php?action=query&format=json&formatversion=2&meta=siteinfo&siprop=general"
        let result = try await CompanionPublicWebFetch.fetch(url, limit: limit)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.url.host, "commons.wikimedia.org")
        XCTAssertTrue(result.headers["content-type"]?.lowercased().contains("application/json") == true)
        XCTAssertGreaterThan(result.data.count, 100)
        XCTAssertLessThanOrEqual(result.data.count, limit)
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        XCTAssertNil(root["error"], "An API error is not a successful source response.")
        let query = try XCTUnwrap(root["query"] as? [String: Any])
        let general = try XCTUnwrap(query["general"] as? [String: Any])
        XCTAssertEqual(general["sitename"] as? String, "Wikimedia Commons")
        XCTAssertEqual(general["wikiid"] as? String, "commonswiki")
        record(result, name: "public-web-commons-json")
    }

    func testRealHTTPSRedirectRechecksDestinationAndReturnsJPEG() async throws {
        let limit = 512 * 1_024
        let start = "https://commons.wikimedia.org/wiki/Special:FilePath/Example.jpg"
        let result = try await CompanionPublicWebFetch.fetch(start, limit: limit)
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.url.scheme, "https")
        XCTAssertEqual(result.url.host, "upload.wikimedia.org", "The genuine file redirect must finish on Wikimedia's file host.")
        XCTAssertNotEqual(result.url.absoluteString, start)
        XCTAssertTrue(result.headers["content-type"]?.lowercased().contains("image/jpeg") == true)
        XCTAssertGreaterThan(result.data.count, 3)
        XCTAssertLessThanOrEqual(result.data.count, limit)
        XCTAssertEqual(Array(result.data.prefix(3)), [0xff, 0xd8, 0xff])
        record(result, name: "public-web-commons-file-redirect")
    }

    func testRealHTTPSBodyBoundRejectsContentAndCancellationTerminates() async throws {
        // First establish real reachability so a DNS/TLS/network error cannot be
        // misreported as successful enforcement of the body budget.
        let reachable = try await CompanionPublicWebFetch.fetch("https://example.org/", limit: 64 * 1_024)
        XCTAssertEqual(reachable.status, 200)
        do {
            _ = try await CompanionPublicWebFetch.fetch("https://example.org/", limit: 1)
            XCTFail("An actual HTML document must not fit a one-byte body budget.")
        } catch let error as URLError {
            XCTAssertTrue([URLError.Code.badServerResponse, .dataLengthExceedsMaximum].contains(error.code), "Only a framing/body-limit rejection proves this boundary; network failures must fail acceptance.")
        }
        // Deterministic pre-cancellation exercises the actual resolver/exchange
        // cancellation path. It does not claim a remotely timed in-flight cancel.
        let began = Date()
        let task = Task { () async throws -> CompanionPublicWebFetch.Response in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CompanionPublicWebFetch.fetch("https://example.org/", limit: 64 * 1_024)
        }
        do {
            _ = try await task.value
            XCTFail("A pre-cancelled fetch must not return source content.")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(began), 5, "Cancellation must not wait for the DNS or transport timeout.")
        }
    }

    private func record(_ response: CompanionPublicWebFetch.Response, name: String) {
        // Metadata only: no cookies, response body, credentials or image bytes.
        let hash = SHA256.hash(data: response.data).map { String(format: "%02x", $0) }.joined()
        let text = "url=\(response.url.absoluteString) mime=\(response.headers["content-type"] ?? "") status=\(response.status) bytes=\(response.data.count) sha256=\(hash)"
        let attachment = XCTAttachment(string: text)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
