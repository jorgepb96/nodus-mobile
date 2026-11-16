import Foundation
import NodusKit
import Synchronization
import Testing
@testable import Nodus

/// A computer that went out of reach and came back must bring every open screen back without
/// the reader switching vault or pressing Refresh, even though its publication did not change.
@Suite("Reconnection")
@MainActor
struct ReconnectionTests {
    @Test("a probe that succeeds after a failed one bumps the reconnection generation")
    func probeRecoveryRefreshesScreens() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = AppModel.Connection(origin: "https://reconnect.test", spaceId: "reconnect-\(UUID().uuidString)",
            spaceName: "Fixture", serverName: "Mac", role: .reader)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyMacProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let client = NodusClient(address: ServerAddress(trusted: connection.origin), token: "fixture-token", session: transport,
            cache: ResponseCache(directory: root.appendingPathComponent("http")))
        let session = SpaceSession(connection: connection, client: client, mirrorDirectory: root)

        FlakyMacProtocol.reachable.withLock { $0 = true }
        await session.refreshPublishedContent()
        let reached = session.contentEpoch
        #expect(session.publishedRevision == "r1")

        FlakyMacProtocol.reachable.withLock { $0 = false }
        await session.refreshPublishedContent()
        #expect(session.contentEpoch == reached, "A failed probe keeps the last coherent publication on screen.")

        FlakyMacProtocol.reachable.withLock { $0 = true }
        await session.refreshPublishedContent()
        #expect(session.publishedRevision == "r1", "The publication did not change while the Mac was away.")
        #expect(session.contentEpoch != reached, "Screens must read again once the Mac answers.")
        #expect(session.loadFailure == nil)

        let afterRecovery = session.contentEpoch
        await session.refreshPublishedContent()
        #expect(session.contentEpoch == afterRecovery, "An ordinary successful probe is not a reconnection.")

        await session.refreshAll()
        #expect(session.contentEpoch != afterRecovery, "Refresh asks every open screen to read again.")
    }
}

/// Answers the snapshot probe with revision r1 while reachable and the space read as not yet
/// published (a successful read with no body to decode); refuses everything while unreachable.
private nonisolated final class FlakyMacProtocol: URLProtocol, @unchecked Sendable {
    static let reachable = Mutex(true)
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "reconnect.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard Self.reachable.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let head = request.httpMethod == "HEAD"
        let body = head ? Data() : Data(#"{"error":"not_published"}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: head ? 200 : 409, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "x-nodus-revision": "r1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
