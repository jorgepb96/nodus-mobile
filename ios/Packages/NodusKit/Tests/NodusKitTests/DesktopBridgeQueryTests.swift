import Foundation
import Testing
@testable import NodusKit

@Suite("Companion read-only POST queries", .serialized)
struct DesktopBridgeQueryTests {
    private func fixture(domains: Set<DesktopBridgeDomain> = [.corpus], expiresAt: Date? = nil) throws -> (DesktopBridgeClient, URLSession) {
        let pair = try DesktopBridgePairing(id: UUID().uuidString, origin: "https://mac.nodus.test:7443",
            certificateFingerprint: String(repeating: "a", count: 64), deviceId: "phone", deviceName: "phone",
            vaultIds: ["Mac/vault"], domains: domains, pairedAt: Date(), expiresAt: expiresAt)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CorpusQueryProtocol.self]
        let session = URLSession(configuration: config)
        let store = DesktopBridgePairingStore(keychain: KeychainStore(service: "nodus.tests.query.\(pair.id)"))
        CorpusQueryProtocol.state.reset()
        return (DesktopBridgeClient(pairing: pair, token: "test-only-token", store: store, session: session), session)
    }

    @Test("the normal client adapter forwards the identity probe body to its owning Mac vault")
    func semanticIdentityProbe() async throws {
        let (bridge, session) = try fixture(); defer { session.invalidateAndCancel() }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NodusClient(address: try ServerAddress(validating: "https://mac.nodus.test:7443"), cache: ResponseCache(directory: root), desktopBridge: bridge, vaultId: "Mac/vault")
        let identity = try await client.publishedEmbeddingIdentity(in: "published-space-different-from-vault")
        #expect(identity == EmbeddingIdentity(provider: "fixture-provider", model: "fixture-model", dim: 3))
        let call = try #require(CorpusQueryProtocol.state.calls().first)
        #expect(call.request.url?.absoluteString == "https://mac.nodus.test:7443/bridge/v2/vaults/Mac%2Fvault/corpus/search/semantic")
        #expect(call.request.httpMethod == "POST")
        #expect(call.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONDecoder.nodus.decode(JSONValue.self, from: call.body)
        #expect(body.objectValue?["query"]?.stringValue == "")
        #expect(body.objectValue?["kind"]?.stringValue == "ideas")
        #expect(body.objectValue?["limit"]?.intValue == 1)
        #expect(body.objectValue?["provider"]?.stringValue == EmbeddingIdentity.probe.provider)
    }

    @Test("context is a permitted read query and forwards its bounded retrieval options")
    func contextBody() async throws {
        let (bridge, session) = try fixture(); defer { session.invalidateAndCancel() }
        let body: JSONValue = .object(["query": .string("Evidence for the topic"), "budget": .int(4096), "include": .array([.string("ideas")])])
        let result = try await bridge.corpusWithOfflineCopy(vaultId: "Mac/vault", path: "context", method: "POST", body: body)
        #expect(!result.fromCache)
        let call = try #require(CorpusQueryProtocol.state.calls().first)
        #expect(call.request.url?.path.hasSuffix("/context") == true)
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: call.body) == body)
    }

    @Test("other writes and encoded aliases fail before any transport")
    func forbiddenWrites() async throws {
        let (bridge, session) = try fixture(); defer { session.invalidateAndCancel() }
        let input: JSONValue = .object(["query": .string("test")])
        for path in ["mutations", "notes", "context/extra", "search/semantic/extra", "search/%73emantic", "search/../semantic", "context?operation=delete"] {
            await #expect(throws: DesktopBridgeError.permissionDenied) {
                try await bridge.corpus(vaultId: "Mac/vault", path: path, method: "POST", body: input, percentEncoded: true)
            }
        }
        await #expect(throws: DesktopBridgeError.permissionDenied) {
            try await bridge.corpus(vaultId: "other-vault", path: "search/semantic", method: "POST", body: input)
        }
        await #expect(throws: DesktopBridgeError.permissionDenied) {
            try await bridge.corpus(vaultId: "Mac/vault", path: "context", method: "DELETE", body: input)
        }
        for body: JSONValue? in [nil, .array([]), .object(["query": .string(String(repeating: "x", count: 256 * 1024))])] {
            await #expect(throws: DesktopBridgeError.malformedResponse) {
                try await bridge.corpus(vaultId: "Mac/vault", path: "context", method: "POST", body: body)
            }
        }
        #expect(CorpusQueryProtocol.state.calls().isEmpty)
    }

    @Test("query access still requires the corpus grant and a current pairing")
    func queryPermissions() async throws {
        let input: JSONValue = .object(["query": .string("test")])
        let (privateOnly, firstSession) = try fixture(domains: [.writing]); defer { firstSession.invalidateAndCancel() }
        await #expect(throws: DesktopBridgeError.permissionDenied) {
            try await privateOnly.corpus(vaultId: "Mac/vault", path: "context", method: "POST", body: input)
        }
        #expect(CorpusQueryProtocol.state.calls().isEmpty)
        let (expired, secondSession) = try fixture(expiresAt: .distantPast); defer { secondSession.invalidateAndCancel() }
        await #expect(throws: DesktopBridgeError.expired) {
            try await expired.corpus(vaultId: "Mac/vault", path: "context", method: "POST", body: input)
        }
        #expect(CorpusQueryProtocol.state.calls().isEmpty)
    }
}

private final class CorpusQueryProtocol: URLProtocol, @unchecked Sendable {
    static let state = CorpusQueryState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(read))
            }
        }
        Self.state.record(request, body: bytes)
        let result = request.url?.path.hasSuffix("/search/semantic") == true
            ? #"{"indexed":false,"reason":"provider_mismatch","expected":{"provider":"fixture-provider","model":"fixture-model","dim":3},"results":[],"warning":"different provider"}"#
            : #"{"sections":[],"stats":{"chars":0,"budget":4096,"truncated":false,"matched":0}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class CorpusQueryState: @unchecked Sendable {
    struct Call { let request: URLRequest; let body: Data }
    private let lock = NSLock()
    private var values: [Call] = []
    func reset() { lock.withLock { values = [] } }
    func record(_ request: URLRequest, body: Data) { lock.withLock { values.append(Call(request: request, body: body)) } }
    func calls() -> [Call] { lock.withLock { values } }
}
