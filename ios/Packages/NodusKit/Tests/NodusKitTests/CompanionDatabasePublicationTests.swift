import Foundation
import Testing
@testable import NodusKit

@Suite("Autonomous database publication persistence")
struct CompanionDatabasePublicationTests {
    @Test("The exact device run and signed source enter a provider-free save")
    func publication() throws {
        let id = UUID().uuidString
        let detail = JSONValue.object(["run":.object(["id":.string("dbr_mobile_\(id)"),"status":.string("partial")]),"report":.object(["id":.string("dbr_report_dbr_mobile_\(id)"),"runId":.string("dbr_mobile_\(id)"),"title":.string("Informe verificable"),"markdown":.string("Contenido propio")])])
        let pack = JSONValue.object(["version":.int(1),"id":.string(String(repeating:"a",count:64)),"signature":.string(String(repeating:"b",count:64))])
        let checkpoint = JSONValue.object(["id":.string(id),"entityKey":.string("chosen"),"state":.string("saved"),"request":.object(["databaseIds":.array([.string("database")])]),"context":.object(["revision":.string(String(repeating:"c",count:64)),"packs":.array([pack])]),"detail":detail])
        let publication = try #require(CompanionGenerationPublication(kind:"database",entity:"chosen",checkpoint:checkpoint))
        #expect(publication.method == "saveMobileDatabaseResearchReport")
        #expect(DesktopBridgeClient.providerFreeJobMethods.contains(publication.method))
        #expect(publication.args[0].objectValue?["detail"] == detail)
        #expect(publication.args[0].objectValue?["sourcePacks"] == .array([pack]))
        #expect(publication.args[0].objectValue?["requestId"] == .string(id))
        var incomplete = checkpoint.objectValue!;incomplete["detail"] = .object(["run":.object(["id":.string("dbr_mobile_\(id)"),"status":.string("running")])])
        #expect(throws:(any Error).self) { try CompanionGenerationPublication(kind:"database",entity:"chosen",checkpoint:.object(incomplete)) }
    }
    @Test("Independent cache actors cannot lose concurrently saved result identities")
    func indexedCache() async throws {
        let id = UUID().uuidString,root = URL.temporaryDirectory.appendingPathComponent("nodus-db-index-\(id)")
        let keychain = KeychainStore(service:"nodus.tests.database-index.\(id)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id));try? FileManager.default.removeItem(at:root) }
        let first = try PrivateBridgeCache(pairingId:id,directory:root,keychain:keychain,readLimitBytes:0)
        let second = try PrivateBridgeCache(pairingId:id,directory:root,keychain:keychain,readLimitBytes:0)
        try await withThrowingTaskGroup(of:Void.self) { group in
            for i in 0..<20 {
                group.addTask { try await (i.isMultiple(of:2) ? first:second).storeIndexedGeneration(Data("own-\(i)".utf8),vaultId:"vault",recordId:"record-\(i)",indexId:"index",entity:String(i)) }
            }
            try await group.waitForAll()
        }
        let data = try #require(try await first.data(vaultId:"vault",domain:.researchGeneration,recordId:"index"))
        #expect(try JSONDecoder.nodus.decode([String].self,from:data).count == 20)
        let reopened = try PrivateBridgeCache(pairingId:id,directory:root,keychain:keychain,readLimitBytes:0)
        for i in 0..<20 { #expect(try await reopened.data(vaultId:"vault",domain:.researchGeneration,recordId:"record-\(i)") == Data("own-\(i)".utf8)) }
        #expect(try await reopened.data(vaultId:"other-vault",domain:.researchGeneration,recordId:"index") == nil)
    }
    @Test("A confirmed report releases raw source rows while preserving idempotent late saves")
    func acknowledgedSources() async throws {
        let pairing = UUID().uuidString,root = URL.temporaryDirectory.appendingPathComponent("nodus-db-prune-\(pairing)")
        let keychain = KeychainStore(service:"nodus.tests.database-prune.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:pairing));try? FileManager.default.removeItem(at:root) }
        let cache = try PrivateBridgeCache(pairingId:pairing,directory:root,keychain:keychain,readLimitBytes:0)
        let identity = UUID().uuidString
        let report:JSONValue = .object(["id":.string("report"),"runId":.string("dbr_mobile_\(identity)"),"markdown":.string("Trabajo propio")])
        let checkpoint:JSONValue = .object(["id":.string(identity),"entityKey":.string("entity"),"state":.string("saved"),"request":.object([:]),
            "context":.object(["revision":.string(String(repeating:"a",count:64)),"packs":.array([.object(["rows":.string(String(repeating:"private-source",count:1000))])])]),
            "detail":.object(["run":.object(["id":.string("dbr_mobile_\(identity)"),"status":.string("completed")]),"report":report]),"reader":.object(["report":report])])
        let publication = try #require(CompanionGenerationPublication(kind:"database",entity:"entity",checkpoint:checkpoint))
        let ledger = try DesktopJobLedger(cache:cache,vaultId:"vault",data:nil)
        try await ledger.preparePublication(publication)
        #expect(await ledger.all().first?.args == publication.args)
        try await ledger.update(id:identity,job:DesktopBridgeJob(id:"mac-job",vaultId:"vault",method:publication.method,state:.available,nextSequence:0,events:[],result:report,error:nil))
        let stored = try await cache.data(vaultId:"vault",domain:.researchGeneration,recordId:"job-ledger-v1")
        let reopened = try DesktopJobLedger(cache:cache,vaultId:"vault",data:stored)
        #expect(await reopened.all().first?.args.isEmpty == true)
        #expect(await reopened.generationCheckpoint(recordId:publication.recordId)?.objectValue?["context"] == nil)
        #expect(await reopened.generationCheckpoint(recordId:publication.recordId)?.objectValue?["reader"]?.objectValue?["report"] == report)
        try await reopened.preparePublication(publication)
        #expect(await reopened.all().first?.state == "available")
        var altered = checkpoint.objectValue!;altered["request"] = .object(["objective":.string("Changed")])
        let conflicting = try #require(CompanionGenerationPublication(kind:"database",entity:"entity",checkpoint:.object(altered)))
        await #expect(throws:DesktopBridgeError.self) { try await reopened.preparePublication(conflicting) }
    }
}
