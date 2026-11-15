import Foundation
import Testing
@testable import NodusKit

@Suite("Private companion immersion progress")
struct CompanionImmersionProgressTests {
    private let sourceRevision = String(repeating: "a", count: 64)
    private func answer(_ value: String) -> CompanionImmersionProgress.Answer {
        .init(questionId: "choice", kind: "choice", answer: value, correct: value == "1", answeredAt: "2026-10-11T00:00:00Z")
    }
    private func snapshot(sessionId: String = "session", revision: String = String(repeating: "b", count: 64), progress: CompanionImmersionProgress.Progress = .init()) -> CompanionImmersionProgress.Snapshot {
        .init(version: 1, sessionId: sessionId, sourceRevision: sourceRevision, progressRevision: revision, progress: progress)
    }
    private func setup() throws -> (PrivateBridgeCache, URL, KeychainStore, String) {
        let id = UUID().uuidString, directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let keychain = KeychainStore(service: "nodus.tests.immersion-progress.\(id)")
        return (try PrivateBridgeCache(pairingId: id, directory: directory, keychain: keychain, readLimitBytes: 1), directory, keychain, id)
    }
    private func outbox(_ cache: PrivateBridgeCache) async throws -> CompanionImmersionProgressOutbox {
        try await .init(cache: cache, vaultId: "vault", data: cache.data(vaultId: "vault", domain: .writing, recordId: CompanionImmersionProgressOutbox.storageKey))
    }
    @Test("UTF-8 source identity agrees with Desktop and nullable wire fields remain explicit")
    func sourceIdentity() throws {
        let text = #"{"topic":"Fotografía / océano 🌊","title":"Recorrido de prueba","language":"es","generatedAt":"2026-10-11T00:00:00Z","minutes":60,"stations":[{"id":"station","quiz":[{"id":"choice","kind":"choice","question":"¿Qué cambió?","options":["Uno","Dos"],"correctIndex":1,"explanation":"Razón literal","expected":""}]}],"exam":{"questions":[{"id":"reflection","kind":"open","question":"Explica tu lectura","options":[],"correctIndex":null,"explanation":"","expected":"Vínculos y tensiones"}]}}"#
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: Data(text.utf8))
        #expect(try CompanionImmersionProgress.sourceRevision(plan: value) == "c19cf1805619e9cdb68381ef3842cbd1d65986712e67f04c098085f1a3f49f75")
        let request = CompanionImmersionProgress.Request(version: 1, id: UUID().uuidString, sourceRevision: sourceRevision, expectedProgressRevision: nil, progress: .init())
        let wire = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(request)).objectValue
        #expect(wire?["expectedProgressRevision"] == .null)
        #expect(wire?["progress"]?.objectValue?["startedAt"] == .null)
        #expect(wire?["progress"]?.objectValue?["finishedAt"] == .null)
    }
    @Test("private responses reopen independently of the reusable download budget")
    func durability() async throws {
        let (cache, directory, keychain, id) = try setup()
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let store = try await outbox(cache)
        try await store.seed(snapshot())
        try await store.answer(sessionId: "session", sourceRevision: sourceRevision, record: answer("1"))
        try await store.step(sessionId: "session", sourceRevision: sourceRevision, index: 1, completed: true)
        let reopened = try await outbox(cache)
        let local = try #require(await reopened.entry(sessionId: "session", sourceRevision: sourceRevision))
        #expect(local.progress.answers.first?.answer == "1"); #expect(local.progress.completedSteps == [1]); #expect(local.state == .pending)
        #expect(try await cache.data(vaultId: "other-vault", domain: .writing, recordId: CompanionImmersionProgressOutbox.storageKey) == nil)
        #expect(try await cache.data(vaultId: "vault", domain: .corpus, recordId: CompanionImmersionProgressOutbox.storageKey) == nil)
        await #expect(throws: APIError.self) { try await reopened.entry(sessionId: "session", sourceRevision: String(repeating: "c", count: 64)) }
    }
    @Test("lost acknowledgements freeze the original request while later phone answers survive")
    func lostAcknowledgement() async throws {
        let (cache, directory, keychain, id) = try setup()
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let store = try await outbox(cache), probe = ImmersionReceiptProbe()
        try await store.seed(snapshot()); try await store.answer(sessionId: "session", sourceRevision: sourceRevision, record: answer("1"))
        await #expect(throws: URLError.self) {
            try await store.synchronize { sessionId, request in
                _ = await probe.send(sessionId: sessionId, request: request)
                throw URLError(.networkConnectionLost)
            }
        }
        let sent = try #require(await probe.first)
        let reopened = try await outbox(cache)
        try await reopened.answer(sessionId: "session", sourceRevision: sourceRevision, record: answer("0"))
        try await reopened.synchronize { sessionId, request in await probe.send(sessionId: sessionId, request: request) }
        let requests = await probe.received
        #expect(requests.count == 3); #expect(requests[1] == sent); #expect(requests[2].id != sent.id)
        let local = try #require(await reopened.entry(sessionId: "session", sourceRevision: sourceRevision))
        #expect(local.state == .saved); #expect(local.progress.answers.first?.answer == "0")
    }
    @Test("concurrent Mac answers require explicit review and retain the phone version")
    func conflict() async throws {
        let (cache, directory, keychain, id) = try setup()
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let store = try await outbox(cache)
        try await store.seed(snapshot()); try await store.answer(sessionId: "session", sourceRevision: sourceRevision, record: answer("1"))
        var mac = CompanionImmersionProgress.Progress(); mac.answers = [answer("0")]
        let remote = snapshot(revision: String(repeating: "c", count: 64), progress: mac)
        let wire = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(remote))
        try await store.synchronize { _, _ in throw APIError(status: 409, code: "immersion_progress_conflict", details: ["remote": wire]) }
        let conflicted = try #require(await store.entry(sessionId: "session", sourceRevision: sourceRevision))
        #expect(conflicted.state == .conflict); #expect(conflicted.progress.answers.first?.answer == "1")
        #expect(conflicted.remote?.progress.answers.first?.answer == "0")
        let reopened = try await outbox(cache)
        try await reopened.resolve(sessionId: "session", keepPhone: true)
        let probe = ImmersionReceiptProbe()
        try await reopened.synchronize { sessionId, request in await probe.send(sessionId: sessionId, request: request) }
        #expect(await probe.first?.expectedProgressRevision == remote.progressRevision)
        #expect(try await reopened.entry(sessionId: "session", sourceRevision: sourceRevision)?.state == .saved)
    }
    @Test("shared player navigation preserves a newer authored answer")
    func staleNavigation() async throws {
        let (cache, directory, keychain, id) = try setup()
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let store = try await outbox(cache)
        try await store.prepare(sessionId: "session", sourceRevision: sourceRevision)
        try await store.answer(sessionId: "session", sourceRevision: sourceRevision, record: answer("1"))
        var navigation = CompanionImmersionProgress.Progress()
        navigation.currentStep = 2; navigation.furthestStep = 2; navigation.completedSteps = [1]
        try await store.navigate(sessionId: "session", sourceRevision: sourceRevision, progress: navigation)
        let reopened = try await outbox(cache)
        let entry = try await reopened.entry(sessionId: "session", sourceRevision: sourceRevision)
        #expect(entry?.progress.answers.first?.answer == "1")
        #expect(entry?.progress.currentStep == 2)
        #expect(entry?.progress.completedSteps == [1])
    }

    @Test("pending autonomous sessions wait for their canonical generation receipt")
    func pendingGeneration() async throws {
        let (cache, directory, keychain, id) = try setup()
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let store = try await outbox(cache), publication = UUID().uuidString, probe = ImmersionReceiptProbe()
        let identity = CompanionImmersionProgressOutbox.localSessionKey(publicationId: publication)
        try await store.prepare(sessionId: identity, sourceRevision: sourceRevision, publicationId: publication)
        try await store.answer(sessionId: identity, sourceRevision: sourceRevision, record: answer("1"))
        try await store.synchronize { sessionId, request in await probe.send(sessionId: sessionId, request: request) }
        #expect(await probe.received.isEmpty)
        try await store.associate(publicationId: publication, sessionId: "canonical-session", sourceRevision: sourceRevision)
        try await store.synchronize { sessionId, request in await probe.send(sessionId: sessionId, request: request) }
        #expect(await probe.sessionIds == ["canonical-session"])
        #expect(try await store.entry(sessionId: "canonical-session", sourceRevision: sourceRevision)?.progress.answers.first?.answer == "1")
    }
}

private actor ImmersionReceiptProbe {
    var received: [CompanionImmersionProgress.Request] = []
    var sessionIds: [String] = []
    private var receipts: [String: CompanionImmersionProgress.Receipt] = [:]
    var first: CompanionImmersionProgress.Request? { received.first }
    func send(sessionId: String, request: CompanionImmersionProgress.Request) -> CompanionImmersionProgress.Receipt {
        received.append(request); sessionIds.append(sessionId)
        if let receipt = receipts[request.id] { return receipt }
        let receipt = CompanionImmersionProgress.Receipt(id: request.id, snapshot: .init(version: 1, sessionId: sessionId,
            sourceRevision: request.sourceRevision, progressRevision: String(repeating: received.count > 2 ? "d" : "c", count: 64), progress: request.progress))
        receipts[request.id] = receipt; return receipt
    }
}
