import Foundation
import Testing
@testable import NodusKit

@Suite("Completed companion generation publication")
struct CompanionGenerationPublicationTests {
    private let revision = String(repeating: "a", count: 64)
    private func checkpoint(kind: String, id: String = UUID().uuidString, state: String = "saved") -> JSONValue {
        var value: [String: JSONValue] = ["id": .string(id), "state": .string(state), "entityKey": .string("entity-a"),
            "request": .object(["entryId": .string("entity-a"), "webSearch": .null,
                "model": .object(["provider": .string("deepseek"), "model": .string("phone-model")])]),
            "context": .object(["revision": .string(revision)])]
        switch kind {
        case "dictionary": value["definition"] = .object(["entryId": .string("entity-a"), "contentMarkdown": .string("Private definition")])
        case "translation": value["markdown"] = .string("Private translation")
        case "immersion": value["plan"] = .object(["title": .string("Private itinerary"), "stations": .array([])])
        case "writing":
            value["raw"] = .string("Private protected response")
            value["preview"] = .object(["text": .string("Private writing result")])
        default: break
        }
        return .object(value)
    }

    @Test("every portable lane binds the exact phone result and revision to its original identity")
    func typedSaves() throws {
        for (kind, method, field) in [("dictionary", "saveDictionaryGeneratedVersion", "definition"),
                                    ("translation", "saveContentTranslationFromMobile", "markdown"),
                                    ("immersion", "saveImmersionGeneratedSession", "plan"),
                                    ("writing", "saveStudyImprovementFromMobile", "raw")] {
            let source = checkpoint(kind: kind)
            let publication = try #require(CompanionGenerationPublication(kind: kind, entity: "entity-a", checkpoint: source))
            #expect(publication.method == method)
            #expect(DesktopBridgeClient.providerFreeJobMethods.contains(method))
            #expect(publication.args.count == 1)
            #expect(publication.args[0].objectValue?[field] == source.objectValue?[field])
            #expect(publication.args[0].objectValue?["requestId"] == source.objectValue?["id"])
            #expect(publication.args[0].objectValue?[kind == "dictionary" ? "contextRevision" : "revision"] == .string(revision))
            if kind == "dictionary" { #expect(publication.args[0].objectValue?["webSearch"] == .string("off")) }
        }
    }

    @Test("unfinished, failed and cancelled provider responses never queue an automatic publication")
    func incompleteAndInvalid() throws {
        for state in ["accepted", "running", "available", "failed", "cancelled"] {
            #expect(try CompanionGenerationPublication(kind: "writing", entity: "entity-a", checkpoint: checkpoint(kind: "writing", state: state))?.id == nil)
        }
        #expect(throws: DesktopBridgeError.self) { try CompanionGenerationPublication(kind: "writing", entity: "another-entity", checkpoint: checkpoint(kind: "writing")) }
        #expect(throws: DesktopBridgeError.self) { try CompanionGenerationPublication(kind: "writing", entity: "entity-a", checkpoint: checkpoint(kind: "writing", id: "invalid")) }
        #expect(throws: DesktopBridgeError.self) { try CompanionGenerationPublication(kind: "translation", entity: "entity-a", checkpoint: checkpoint(kind: "writing")) }
    }

    @Test("portable source versions survive the atomic publication and reject unknown contracts")
    func offlineSourceVersion() throws {
        for kind in ["writing", "translation", "immersion"] {
            var value = try #require(checkpoint(kind: kind).objectValue)
            value["context"] = .object(["revision": .string(revision), "offlineSourceVersion": .int(1)])
            let publication = try #require(CompanionGenerationPublication(kind: kind, entity: "entity-a", checkpoint: .object(value)))
            #expect(publication.args[0].objectValue?["offlineSourceVersion"] == .int(1))
            value["context"] = .object(["revision": .string(revision), "offlineSourceVersion": .int(2)])
            #expect(throws: DesktopBridgeError.self) { try CompanionGenerationPublication(kind: kind, entity: "entity-a", checkpoint: .object(value)) }
        }
        var dictionary = try #require(checkpoint(kind: "dictionary").objectValue)
        dictionary["context"] = .object(["revision": .string(revision), "offlineSourceVersion": .int(1)])
        #expect(throws: DesktopBridgeError.self) { try CompanionGenerationPublication(kind: "dictionary", entity: "entity-a", checkpoint: .object(dictionary)) }
    }

    @Test("termination before the second checkpoint write retains both completed content and its idempotent send")
    func atomicQueueAndRecovery() async throws {
        let pairing = UUID().uuidString, directory = URL.temporaryDirectory.appendingPathComponent("nodus-publication-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.publication.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let ledger = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: nil)
        let source = checkpoint(kind: "writing")
        let publication = try #require(CompanionGenerationPublication(kind: "writing", entity: "entity-a", checkpoint: source))
        try await ledger.preparePublication(publication)
        // No separate checkpoint record has been written yet: simulate closing
        // immediately after the single durable publication acknowledgement.
        #expect(try await cache.data(vaultId: "vault-a", domain: .researchGeneration, recordId: publication.recordId) == nil)
        try await cache.removeReusableCopies()
        let stored = try await cache.data(vaultId: "vault-a", domain: .researchGeneration, recordId: "job-ledger-v1")
        let reopened = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: stored)
        let retained = try #require(await reopened.generationCheckpoint(recordId: publication.recordId))
        #expect(retained.objectValue?["preview"] == source.objectValue?["preview"])
        #expect(retained.objectValue?["state"] == .string("saved"))
        #expect(await reopened.all().first?.args == publication.args)
        let result = JSONValue.object(["text": .string("Canonical writing result"), "logId": .string("original-log")])
        try await reopened.update(id: publication.id, job: DesktopBridgeJob(id: "mac-job-a", vaultId: "vault-a", method: publication.method,
            state: .available, nextSequence: 0, events: [], result: result, error: nil))
        // A late renderer write after transport loss cannot reset the completed
        // Mac acknowledgement or turn it into another provider request.
        try await reopened.preparePublication(publication)
        try await reopened.update(id: publication.id, job: DesktopBridgeJob(id: "mac-job-a", vaultId: "vault-a", method: publication.method,
            state: .accepted, nextSequence: 0, events: [], result: .null, error: nil))
        let complete = try #require(await reopened.generationCheckpoint(recordId: publication.recordId, generationId: publication.id))
        #expect(complete.objectValue?["state"] == .string("available")); #expect(complete.objectValue?["result"] == result)
        #expect(await reopened.all().count == 1)
        #expect(await reopened.generationCheckpoint(recordId: publication.recordId, generationId: UUID().uuidString) == nil)
        for file in try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("bridge-\(pairing)"), includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: Data("Private writing result".utf8)) == nil)
        }
    }

    @Test("a canonical save conflict preserves the local result and stays failed when requeued")
    func conflict() async throws {
        let pairing = UUID().uuidString, directory = URL.temporaryDirectory.appendingPathComponent("nodus-publication-conflict-\(pairing)")
        let keychain = KeychainStore(service: "nodus.tests.publication-conflict.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing)); try? FileManager.default.removeItem(at: directory) }
        let cache = try PrivateBridgeCache(pairingId: pairing, directory: directory, keychain: keychain)
        let ledger = try DesktopJobLedger(cache: cache, vaultId: "vault-a", data: nil)
        let source = checkpoint(kind: "translation")
        let publication = try #require(CompanionGenerationPublication(kind: "translation", entity: "entity-a", checkpoint: source))
        try await ledger.preparePublication(publication)
        try await ledger.update(id: publication.id, job: DesktopBridgeJob(id: "mac-job-b", vaultId: "vault-a", method: publication.method,
            state: .failed, nextSequence: 0, events: [], result: .null, error: "translation_generation_conflict"))
        try await ledger.preparePublication(publication)
        let failed = try #require(await ledger.generationCheckpoint(recordId: publication.recordId))
        #expect(failed.objectValue?["state"] == .string("failed")); #expect(failed.objectValue?["markdown"] == source.objectValue?["markdown"])
        #expect(failed.objectValue?["error"] == .string("translation_generation_conflict"))
        var altered = source.objectValue!; altered["markdown"] = .string("Changed response")
        let other = try #require(CompanionGenerationPublication(kind: "translation", entity: "entity-a", checkpoint: .object(altered)))
        await #expect(throws: DesktopBridgeError.self) { try await ledger.preparePublication(other) }
    }
}
