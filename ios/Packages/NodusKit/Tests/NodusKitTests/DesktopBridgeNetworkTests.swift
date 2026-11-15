import Foundation
import Testing
@testable import NodusKit

@Suite("Linked Mac address recovery", .serialized)
struct DesktopBridgeNetworkTests {
    @Test("a failed connection changes address before sending; ambiguous writes and bad certificates stop")
    func transportRecovery() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeNetworkProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for (code, method, expectedRequests) in [
            (URLError.Code.cannotConnectToHost, "POST", 2), (.cannotFindHost, "POST", 2),
            (.timedOut, "GET", 2), (.networkConnectionLost, "GET", 2),
            (.timedOut, "POST", 1), (.networkConnectionLost, "POST", 1),
            (.secureConnectionFailed, "GET", 1), (.serverCertificateUntrusted, "POST", 1),
        ] {
            BridgeNetworkProtocol.state.reset(error: code)
            var request = URLRequest(url: URL(string: "https://previous.nodus.test:7443/bridge/v2/vaults/Mac%2Fvault/operations?cursor=a%2Bb")!)
            request.httpMethod = method
            request.setValue("private-token", forHTTPHeaderField: "Authorization")
            request.httpBody = Data("unique-write".utf8)
            do {
                let result = try await DesktopBridgeClient.perform(request, session: session, relay: nil,
                    alternateOrigins: ["https://current.nodus.test:7443"])
                #expect(expectedRequests == 2)
                #expect(result.0 == Data("saved-once".utf8))
                #expect(result.1.url?.host == "current.nodus.test")
            } catch {
                #expect(expectedRequests == 1)
                #expect((error as? URLError)?.code == code)
            }
            let calls = BridgeNetworkProtocol.state.requests()
            #expect(calls.count == expectedRequests)
            if calls.count == 2 {
                #expect(calls[1].url?.absoluteString == "https://current.nodus.test:7443/bridge/v2/vaults/Mac%2Fvault/operations?cursor=a%2Bb")
                #expect(calls[1].value(forHTTPHeaderField: "Authorization") == "private-token")
                #expect(calls[1].httpMethod == method)
            }
        }
    }

    @Test("stored alternative addresses remain HTTPS and old pairings still decode")
    func storedAddresses() throws {
        let pair = try DesktopBridgePairing(id: "grant", origin: "https://mac.local:7443", certificateFingerprint: String(repeating: "a", count: 64),
            deviceId: "phone", deviceName: "phone", vaultIds: ["vault"], domains: [.corpus], pairedAt: Date(), expiresAt: nil,
            alternateOrigins: ["https://mac.local:7443", "https://10.0.0.2:7443", "https://10.0.0.2:7443"])
        #expect(pair.alternateOrigins == ["https://10.0.0.2:7443"])
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder.nodus.encode(pair)) as? [String: Any])
        old.removeValue(forKey: "alternateOrigins")
        let decoded = try JSONDecoder.nodus.decode(DesktopBridgePairing.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.alternateOrigins == nil)
        #expect(decoded.origin == pair.origin)
        #expect(throws: DesktopBridgeError.invalidOrigin) {
            try DesktopBridgePairing.validateOrigin("http://10.0.0.2:7443")
        }
    }
}

private final class BridgeNetworkProtocol: URLProtocol, @unchecked Sendable {
    static let state = BridgeNetworkState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let failure = Self.state.record(request)
        if let failure { client?.urlProtocol(self, didFailWithError: URLError(failure)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("saved-once".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class BridgeNetworkState: @unchecked Sendable {
    private let lock = NSLock()
    private var error = URLError.Code.cannotConnectToHost
    private var calls: [URLRequest] = []
    func reset(error: URLError.Code) { lock.withLock { self.error = error; calls = [] } }
    func record(_ request: URLRequest) -> URLError.Code? {
        lock.withLock { calls.append(request); return request.url?.host == "previous.nodus.test" ? error : nil }
    }
    func requests() -> [URLRequest] { lock.withLock { calls } }
}
