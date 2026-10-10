import Foundation
import Testing
@testable import NodusKit

@Suite("Durable live job requests")
struct DesktopJobLedgerTests {
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
}
