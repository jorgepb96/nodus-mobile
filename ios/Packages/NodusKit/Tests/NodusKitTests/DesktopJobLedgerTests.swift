import Foundation
import Testing
@testable import NodusKit

@Suite("Durable live job requests")
struct DesktopJobLedgerTests {
    private actor RecoveringMac {
        var jobs: [DesktopBridgeJob] = []
        var submitted: [String] = []
        func list() -> [DesktopBridgeJob] { jobs }
        func submit(_ request: DesktopJobLedger.Request) -> DesktopBridgeJob {
            submitted.append(request.id)
            if let job = jobs.first(where: { $0.id == request.id }) { return job }
            let job = DesktopBridgeJob(id: request.id, vaultId: "vault-a", method: request.method, state: .accepted,
                nextSequence: 0, events: [], result: .null, error: nil)
            jobs.append(job)
            return job
        }
        func finish(_ request: DesktopJobLedger.Request, state: DesktopBridgeJob.State) {
            jobs.removeAll { $0.id == request.id }
            jobs.append(DesktopBridgeJob(id: request.id, vaultId: "vault-a", method: request.method, state: state,
                nextSequence: 0, events: [], result: .string("Durable result"), error: state == .failed ? "Provider failed" : nil))
        }
        func sentIds() -> [String] { submitted }
    }
    @Test("provider request identities survive JSON decoding and object insertion order")
    func canonicalRequestIdentity() throws {
        let first = JSONValue.object(["model": .object(["model": .string("example"), "provider": .string("deepseek")]), "generationId": .string("stable"), "user": .string("Private corpus prompt")])
        let reordered = try JSONDecoder.nodus.decode(JSONValue.self, from: Data(#"{"user":"Private corpus prompt","generationId":"stable","model":{"provider":"deepseek","model":"example"}}"#.utf8))
        #expect(try JSONEncoder.nodus.encode(first) == JSONEncoder.nodus.encode(reordered))
    }
    @Test("closing and reopening retains the same request and keeps its content encrypted")
    func recover() async throws {
        let pairing = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nodus-job-ledger-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.ledger.\(pairing)")
        defer {
            try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing))
            try? FileManager.default.removeItem(at: directory)
        }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let first = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: nil)
        let id = UUID().uuidString
        let args: [JSONValue] = [.object(["question": .string("private acceptance content")])]
        _ = try await first.prepare(id: id, method: "researchChat", args: args)
        try await first.disconnected(id: id, issue: "Mac disconnected")
        let persisted = try await cache.data(vaultId: "vault-a", domain: .researchGeneration, recordId: "job-ledger-v1")
        let reopened = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: persisted)
        let recovered = try await reopened.prepare(id: id, method: "researchChat", args: args)
        #expect(recovered.id == id); #expect(recovered.issue == "Mac disconnected")
        #expect(await reopened.all().count == 1)
        #expect(try await cache.data(vaultId: "another-vault", domain: .researchGeneration, recordId: "job-ledger-v1") == nil)
        for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("bridge-\(pairing)"), includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: Data("private acceptance content".utf8)) == nil)
        }
        await #expect(throws: DesktopBridgeError.self) { try await reopened.prepare(id: id, method: "researchChat", args: [.string("changed")]) }
    }

    @Test("automatic reconnection reuses a lost acknowledgement and only observes accepted jobs")
    func reconnect() async throws {
        let id = UUID().uuidString, pairing = UUID().uuidString
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-job-reconnect-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.reconnect.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let ledger = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: nil), mac = RecoveringMac()
        let request = try await ledger.prepare(id: id, method: "generateImmersionSession", args: [.object(["topic": .string("A retained request")])])
        // The Mac accepted the first send, but the phone lost its acknowledgement.
        _ = await mac.submit(request)
        try await ledger.disconnected(id: id, issue: "Lost acknowledgement")
        let persisted = try await cache.data(vaultId: "vault-a", domain: .researchGeneration, recordId: "job-ledger-v1")
        let reopened = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: persisted)
        try await reopened.synchronize(list: { await mac.list() }, submit: { await mac.submit($0) })
        #expect(await mac.list().count == 1)
        #expect(await mac.sentIds() == [id, id])
        #expect(await reopened.all().first?.jobId == id)
        await mac.finish(request, state: .available)
        try await reopened.synchronize(list: { await mac.list() }, submit: { await mac.submit($0) })
        #expect(await reopened.all().first?.state == "available")
        #expect(await mac.sentIds() == [id, id])
    }

    @Test("autonomous mode sends completed portable results without starting queued Mac generation or retrying a failure")
    func explicitExecutionMode() async throws {
        let pairing = UUID().uuidString, directory = URL.temporaryDirectory.appendingPathComponent("nodus-job-mode-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.jobmode.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let ledger = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: nil), mac = RecoveringMac()
        let generation = try await ledger.prepare(id: UUID().uuidString, method: "researchChat", args: [])
        let saved = try await ledger.prepare(id: UUID().uuidString, method: "saveContentTranslationFromMobile", args: [])
        try await ledger.synchronize(list: { await mac.list() }, canSubmit: { DesktopBridgeClient.providerFreeJobMethods.contains($0.method) }, submit: { await mac.submit($0) })
        #expect(await mac.sentIds() == [saved.id])
        #expect(await ledger.all().first(where: { $0.id == generation.id })?.jobId == nil)
        await mac.finish(saved, state: .failed)
        try await ledger.synchronize(list: { await mac.list() }, canSubmit: { DesktopBridgeClient.providerFreeJobMethods.contains($0.method) }, submit: { await mac.submit($0) })
        #expect(await ledger.all().first(where: { $0.id == saved.id })?.state == "failed")
        #expect(await mac.sentIds() == [saved.id])
        let wrongVault = DesktopBridgeJob(id: generation.id, vaultId: "vault-b", method: generation.method, state: .available, nextSequence: 0, events: [], result: .null, error: nil)
        await #expect(throws: DesktopBridgeError.self) { try await ledger.update(id: generation.id, job: wrongVault) }
        #expect(await ledger.all().first(where: { $0.id == generation.id })?.jobId == nil)
    }
}
