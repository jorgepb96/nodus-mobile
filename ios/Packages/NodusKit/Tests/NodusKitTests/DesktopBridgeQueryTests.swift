import Foundation
import Testing
@testable import NodusKit

@Suite("Companion corpus queries and typed actions", .serialized)
struct DesktopBridgeQueryTests {
    @Test("live consultation projection uses the Mac vault identity and keeps offline copies separate from a complete snapshot")
    func snapshotConsultations() async throws {
        let (bridge, session) = try fixture(); defer { session.invalidateAndCancel() }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NodusClient(address: try ServerAddress(validating: "https://mac.nodus.test:7443"), cache: ResponseCache(directory: root), desktopBridge: bridge, vaultId: "Mac/vault")
        for selection: SnapshotConsultation in [.dictionary, .sources] {
            let snapshot = try await client.snapshot(in: "different-publication", consultation: selection)
            #expect(snapshot.document["requestedProjection"]?.stringValue == selection.rawValue)
        }
        #expect(try await client.snapshot(in: "different-publication").document["requestedProjection"] == .string("complete"))
        let calls = CorpusQueryProtocol.state.calls()
        #expect(calls.count == 3)
        #expect(calls.allSatisfy { $0.request.url?.path == "/bridge/v2/vaults/Mac/vault/corpus/snapshot" })
        #expect(calls[0].request.url?.query == "projection=dictionary")
        #expect(calls[1].request.url?.query == "projection=sources")
        #expect(calls[2].request.url?.query == nil)
        for selection: SnapshotConsultation in [.sources, .dictionary] {
            CorpusQueryProtocol.state.respond(.offline)
            let restored = try await client.snapshot(in: "different-publication", consultation: selection)
            #expect(restored.document["requestedProjection"]?.stringValue == selection.rawValue)
        }
        CorpusQueryProtocol.state.respond(.offline)
        #expect(try await client.snapshot(in: "different-publication").document["requestedProjection"] == .string("complete"))
    }

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

    @Test("a copied read can use a short network deadline without changing its authenticated payload")
    func copiedReadDeadline() async throws {
        let (bridge, session) = try fixture(); defer { session.invalidateAndCancel() }
        let value = try await bridge.operation(vaultId: "Mac/vault", method: "getNotesTree", args: [.bool(true)], timeout: 4)
        #expect(value == .object(["folders": .array([]), "notes": .array([])]))
        let call = try #require(CorpusQueryProtocol.state.calls().first)
        #expect(call.request.timeoutInterval == 4)
        #expect(call.request.httpMethod == "POST")
        #expect(call.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-token")
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: call.body) == .object(["method": .string("getNotesTree"), "args": .array([.bool(true)])]))
        #expect(CorpusQueryProtocol.state.calls().count == 1)
    }

    @Test("invalid read deadlines and another vault fail before transport")
    func invalidReadDeadline() async throws {
        let (bridge, session) = try fixture(); defer { session.invalidateAndCancel() }
        for timeout in [Double.nan, .infinity, 0, -1, 121] {
            await #expect(throws: DesktopBridgeError.malformedResponse) {
                try await bridge.operation(vaultId: "Mac/vault", method: "getNotesTree", args: [], timeout: timeout)
            }
        }
        await #expect(throws: DesktopBridgeError.permissionDenied) {
            try await bridge.operation(vaultId: "another-vault", method: "getNotesTree", args: [], timeout: 4)
        }
        #expect(CorpusQueryProtocol.state.calls().isEmpty)
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

    private var actionBody: JSONValue { .object([
        "id": .string("41BCE15F-FA11-469D-9399-7ACB49620F83"), "kind": .string("pages.restoreRevision"),
        "schemaVersion": .int(1), "payload": .object(["pageId": .string("page-owned"), "revision": .int(2)]),
        "idempotencyKey": .string("restore:page-owned:2")
    ]) }

    @Test("the normal action API uses the actual owning vault and the persisted Mac receipt")
    func directAction() async throws {
        let (bridge, session) = try fixture(domains: [.corpus, .writing]); defer { session.invalidateAndCancel() }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NodusClient(address: try ServerAddress(validating: "https://mac.nodus.test:7443"), cache: ResponseCache(directory: root), desktopBridge: bridge, vaultId: "Mac/vault")
        let created = try await client.createSpaceAction(idempotencyKey: "restore:page-owned:2", kind: .pageRestoreRevision,
            payload: ["pageId": .string("page-owned"), "revision": .int(2)], executionMode: "autonomous", in: "different-published-space")
        #expect(created.action.spaceId == "Mac/vault")
        #expect(created.action.status == .queued)
        #expect(created.action.sequence == 7)
        let request = try #require(CorpusQueryProtocol.state.calls().first)
        #expect(request.request.url?.absoluteString == "https://mac.nodus.test:7443/bridge/v2/vaults/Mac%2Fvault/jobs")
        #expect(request.request.httpMethod == "POST")
        let submitted = try JSONDecoder.nodus.decode(JSONValue.self, from: request.body).objectValue
        #expect(submitted?["args"]?.arrayValue?.first?.objectValue?["executionMode"] == .string("autonomous"))
        #expect(submitted?["idempotencyKey"] == .string(DesktopCompanionActions.key("restore:page-owned:2")))
        #expect(CorpusQueryProtocol.state.calls().count == 1)
    }

    @Test("typed content actions cannot open generic writes, toolkit or an encoded alias")
    func closedActionBoundary() async throws {
        let (bridge, session) = try fixture(domains: [.corpus, .writing, .researchGeneration]); defer { session.invalidateAndCancel() }
        for path in ["%61ctions", "actions/", "actions/../actions", "actions/invalid/cancel", "actions?method=delete", "notes"] {
            await #expect(throws: DesktopBridgeError.permissionDenied) {
                try await bridge.corpus(vaultId: "Mac/vault", path: path, method: "POST", body: actionBody, percentEncoded: true)
            }
        }
        var input = try #require(actionBody.objectValue)
        for kind in ["toolkit.desktopRun", "library.importToSpace", "academic.recompute", "pages.automationRun", "unknown"] {
            input["kind"] = .string(kind)
            let value = JSONValue.object(input)
            await #expect(throws: DesktopBridgeError.permissionDenied) { try await bridge.corpus(vaultId: "Mac/vault", path: "actions", method: "POST", body: value) }
        }
        input["kind"] = .string("pages.restoreRevision"); input["method"] = .string("arbitraryIPC")
        let extra = JSONValue.object(input)
        await #expect(throws: DesktopBridgeError.malformedResponse) { try await bridge.corpus(vaultId: "Mac/vault", path: "actions", method: "POST", body: extra) }
        #expect(CorpusQueryProtocol.state.calls().isEmpty)
    }

    @Test("offline action intent survives reopen and reuses the same Mac key")
    func durableActionReopen() async throws {
        let (bridge, session) = try fixture(domains: [.corpus, .writing]); defer { session.invalidateAndCancel() }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NodusClient(address: try ServerAddress(validating: "https://mac.nodus.test:7443"), cache: ResponseCache(directory: root), desktopBridge: bridge, vaultId: "Mac/vault")
        let key = "restore:page-owned:2", payload: [String: JSONValue] = ["pageId": .string("page-owned"), "revision": .int(2)]
        CorpusQueryProtocol.state.respond(.offline)
        let queued = try await client.createSpaceAction(idempotencyKey: key, kind: .pageRestoreRevision, payload: payload, in: "publication")
        #expect(queued.action.sequence == 0)
        #expect(queued.action.status == .queued)
        #expect(queued.action.spaceId == "Mac/vault")
        #expect(queued.action.id == DesktopCompanionActions.identity(key))
        let pair = await bridge.pairing
        await DesktopJobLedgers.shared.forget(pairingId: pair.id)
        CorpusQueryProtocol.state.respond(.offline)
        let reopened = try await client.spaceAction(id: queued.action.id, in: "publication")
        #expect(reopened.status == .queued)
        #expect(CorpusQueryProtocol.state.calls().last?.request.httpMethod == "GET")
        let accepted = try await client.createSpaceAction(idempotencyKey: key, kind: .pageRestoreRevision, payload: payload, in: "publication")
        #expect(accepted.duplicate)
        #expect(accepted.action.sequence == 7)
        let posts = CorpusQueryProtocol.state.calls().filter { $0.request.httpMethod == "POST" }
        #expect(posts.count == 2)
        let keys = try posts.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0.body).objectValue?["idempotencyKey"] }
        #expect(keys[0] == keys[1])
        CorpusQueryProtocol.state.respond(.available)
        #expect(try await client.spaceAction(id: accepted.action.id, in: "publication").status == .applied)
    }

    @Test("a lost acknowledgement can be cancelled without ever resubmitting the action")
    func cancelLostAcknowledgement() async throws {
        let (bridge, session) = try fixture(domains: [.corpus, .writing]); defer { session.invalidateAndCancel() }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NodusClient(address: try ServerAddress(validating: "https://mac.nodus.test:7443"), cache: ResponseCache(directory: root), desktopBridge: bridge, vaultId: "Mac/vault")
        let payload: [String: JSONValue] = ["pageId": .string("page-owned"), "revision": .int(2)]
        CorpusQueryProtocol.state.respond(.offline)
        let queued = try await client.createSpaceAction(idempotencyKey: "restore:page-owned:2", kind: .pageRestoreRevision, payload: payload, in: "publication")
        CorpusQueryProtocol.state.respond(.offline)
        #expect(try await client.cancelSpaceAction(id: queued.action.id, in: "publication").status == .queued)
        let pair = await bridge.pairing
        await DesktopJobLedgers.shared.forget(pairingId: pair.id)
        CorpusQueryProtocol.state.respond(.notFound)
        CorpusQueryProtocol.state.respond(.cancelled)
        try await bridge.reconcileDurableCancellations(vaultId: "Mac/vault")
        #expect(try await client.spaceAction(id: queued.action.id, in: "publication").status == .cancelled)
        let again = try await client.createSpaceAction(idempotencyKey: "restore:page-owned:2", kind: .pageRestoreRevision, payload: payload, in: "publication")
        #expect(again.action.status == .cancelled)
        #expect(CorpusQueryProtocol.state.calls().filter { $0.request.httpMethod == "POST" }.count == 1)
        let lookup = CorpusQueryProtocol.state.calls().compactMap { call -> URL? in
            guard call.request.httpMethod == "GET", let url = call.request.url,
                  URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "requestId" && $0.value == DesktopCompanionActions.key("restore:page-owned:2") }) == true else { return nil }
            return url
        }
        #expect(!lookup.isEmpty)
        let cancellation = try #require(CorpusQueryProtocol.state.calls().last { $0.request.httpMethod == "DELETE" })
        let body = try JSONDecoder.nodus.decode(JSONValue.self, from: cancellation.body)
        #expect(body.objectValue?["idempotencyKey"]?.stringValue == DesktopCompanionActions.key("restore:page-owned:2"))
        #expect(body.objectValue?["method"]?.stringValue == "runMobileSpaceAction")
        #expect(body.objectValue?["args"]?.arrayValue?.first?.objectValue?["kind"]?.stringValue == "pages.restoreRevision")
    }

    @Test("a Mac without durable cancellation leaves the intent pending and never submits it")
    func cancellationNeedsMacReceipt() async throws {
        let (bridge, session) = try fixture(domains: [.corpus, .writing]); defer { session.invalidateAndCancel() }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NodusClient(address: try ServerAddress(validating: "https://mac.nodus.test:7443"), cache: ResponseCache(directory: root), desktopBridge: bridge, vaultId: "Mac/vault")
        CorpusQueryProtocol.state.respond(.offline)
        let queued = try await client.createSpaceAction(idempotencyKey: "restore:page-owned:2", kind: .pageRestoreRevision,
            payload: ["pageId": .string("page-owned"), "revision": .int(2)], in: "publication")
        CorpusQueryProtocol.state.respond(.notFound)
        CorpusQueryProtocol.state.respond(.notFound)
        do { _ = try await client.cancelSpaceAction(id: queued.action.id, in: "publication"); Issue.record("Cancellation without a Mac receipt must remain unresolved") }
        catch let error as APIError { #expect(error.status == 404) }
        let pair = await bridge.pairing
        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pair.id, vaultId: "Mac/vault")
        let saved = try #require(await ledger.all().first)
        #expect(saved.cancellationRequested == true)
        #expect(saved.state == "pending")
        let again = try await client.createSpaceAction(idempotencyKey: "restore:page-owned:2", kind: .pageRestoreRevision,
            payload: ["pageId": .string("page-owned"), "revision": .int(2)], in: "publication")
        #expect(again.action.status == .queued)
        #expect(CorpusQueryProtocol.state.calls().filter { $0.request.httpMethod == "POST" }.count == 1)
    }

    @Test("recovering cancellation preserves an operation already applied on the Mac")
    func cancelAlreadyApplied() async throws {
        let (bridge, session) = try fixture(domains: [.corpus, .writing]); defer { session.invalidateAndCancel() }
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = NodusClient(address: try ServerAddress(validating: "https://mac.nodus.test:7443"), cache: ResponseCache(directory: root), desktopBridge: bridge, vaultId: "Mac/vault")
        CorpusQueryProtocol.state.respond(.offline)
        let queued = try await client.createSpaceAction(idempotencyKey: "restore:page-owned:2", kind: .pageRestoreRevision,
            payload: ["pageId": .string("page-owned"), "revision": .int(2)], in: "publication")
        CorpusQueryProtocol.state.respond(.available)
        #expect(try await client.cancelSpaceAction(id: queued.action.id, in: "publication").status == .applied)
        #expect(!CorpusQueryProtocol.state.calls().contains { $0.request.httpMethod == "DELETE" })
        #expect(!DesktopBridgeClient.isProviderFreeJob(method: "runMobileSpaceAction", args: [.object(["kind": .string("author.synthesis.generate")])]))
        #expect(DesktopBridgeClient.isProviderFreeJob(method: "runMobileSpaceAction", args: [.object(["kind": .string("pages.restoreRevision")])]))
    }

    @Test("research actions require explicit live mode and content actions still require writing")
    func actionPermissionsAndMode() async throws {
        let (bridge, session) = try fixture(domains: [.corpus, .writing, .researchGeneration]); defer { session.invalidateAndCancel() }
        var input = try #require(actionBody.objectValue); input["kind"] = .string("author.synthesis.generate")
        let modes: [JSONValue?] = [nil, .string("autonomous")]
        for mode in modes {
            input["executionMode"] = mode; let value = JSONValue.object(input)
            do {
                _ = try await bridge.corpus(vaultId: "Mac/vault", path: "actions", method: "POST", body: value)
                Issue.record("An autonomous action reached the Mac providers")
            } catch let error as APIError { #expect(error.code == "explicit_live_mode_required") }
        }
        #expect(CorpusQueryProtocol.state.calls().isEmpty)
        let (readOnly, readSession) = try fixture(); defer { readSession.invalidateAndCancel() }
        await #expect(throws: DesktopBridgeError.permissionDenied) { try await readOnly.corpus(vaultId: "Mac/vault", path: "actions", method: "POST", body: actionBody) }
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
        let outcome = Self.state.nextResponse()
        if outcome == .offline { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        if outcome == .notFound {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":"job_not_found"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self); return
        }
        let projection = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "projection" })?.value ?? "complete"
        let result = request.url?.path.hasSuffix("/snapshot") == true
            ? "{\"format\":\"nodus.server-snapshot\",\"formatVersion\":2,\"tables\":{},\"requestedProjection\":\"\(projection)\"}"
            : request.url?.path.hasSuffix("/jobs") == true || request.url?.path.contains("/jobs/") == true
            ? #"{"job":{"id":"55471b5e-aa10-48c0-9d4c-cfc37b1c0ce1","vaultId":"Mac/vault","method":"runMobileSpaceAction","state":"accepted","actionSequence":7,"createdAt":"2026-10-11T08:00:00.000Z","updatedAt":"2026-10-11T08:00:00.000Z","nextSequence":0,"events":[],"result":null,"error":null}}"#
            : request.url?.path.hasSuffix("/actions") == true
            ? #"{"action":{"id":"55471b5e-aa10-48c0-9d4c-cfc37b1c0ce1","sequence":7,"spaceId":"Mac/vault","idempotencyKey":"restore:page-owned:2","kind":"pages.restoreRevision","schemaVersion":1,"payload":{"pageId":"page-owned","revision":2},"actorUserId":"phone","createdByDevice":"phone","status":"queued","createdAt":"2026-10-11T08:00:00.000Z","updatedAt":"2026-10-11T08:00:00.000Z"},"duplicate":false}"#
            : request.url?.path.hasSuffix("/operations") == true
            ? #"{"result":{"folders":[],"notes":[]}}"#
            : request.url?.path.hasSuffix("/search/semantic") == true
            ? #"{"indexed":false,"reason":"provider_mismatch","expected":{"provider":"fixture-provider","model":"fixture-model","dim":3},"results":[],"warning":"different provider"}"#
            : #"{"sections":[],"stats":{"chars":0,"budget":4096,"truncated":false,"matched":0}}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        let current = outcome == .available ? result.replacingOccurrences(of: "\"state\":\"accepted\"", with: "\"state\":\"available\"")
            : outcome == .cancelled ? result.replacingOccurrences(of: "\"state\":\"accepted\"", with: "\"state\":\"cancelled\"") : result
        // Individual job reads use the same receipt fixture as collection POSTs.
        let receipt = outcome == .available && request.url?.path.contains("/jobs/") == true
            ? #"{"job":{"id":"55471b5e-aa10-48c0-9d4c-cfc37b1c0ce1","vaultId":"Mac/vault","method":"runMobileSpaceAction","state":"available","actionSequence":7,"nextSequence":0,"events":[],"result":{},"error":null}}"# : current
        client?.urlProtocol(self, didLoad: Data(receipt.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class CorpusQueryState: @unchecked Sendable {
    enum Outcome { case accepted, offline, notFound, available, cancelled }
    struct Call { let request: URLRequest; let body: Data }
    private let lock = NSLock()
    private var values: [Call] = []
    private var responses: [Outcome] = []
    func reset() { lock.withLock { values = []; responses = [] } }
    func respond(_ outcome: Outcome) { lock.withLock { responses.append(outcome) } }
    func nextResponse() -> Outcome { lock.withLock { responses.isEmpty ? .accepted : responses.removeFirst() } }
    func record(_ request: URLRequest, body: Data) { lock.withLock { values.append(Call(request: request, body: body)) } }
    func calls() -> [Call] { lock.withLock { values } }
}
