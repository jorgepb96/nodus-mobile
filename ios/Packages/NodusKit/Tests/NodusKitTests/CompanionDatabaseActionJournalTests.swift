import Foundation
import CryptoKit
import Testing
@testable import NodusKit

@Suite("Database action paid recovery") struct CompanionDatabaseActionJournalTests {
    struct Fixture {
        let id=UUID().uuidString
        let folder:URL
        let keys:KeychainStore
        let cache:PrivateBridgeCache
        init()throws{folder=URL.temporaryDirectory.appendingPathComponent("database-journal-\(id)");keys=KeychainStore(service:"nodus.tests.db-action.\(id)");cache=try PrivateBridgeCache(pairingId:id,directory:folder,keychain:keys,readLimitBytes:0)}
        func clear(){try? keys.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id));try? FileManager.default.removeItem(at:folder)}
    }
    actor Calls {var count=0;func next()->JSONValue{count+=1;return .object(["text":.string("Received canonical text")])};func value()->Int{count}}
    func accepted(id:String=UUID().uuidString.lowercased())throws->CompanionDatabaseActionCheckpoint {
        try .init(.object(["version":.int(1),"vaultId":.string("vault"),"id":.string(id),"request":.object(["rowId":.string("own-row"),"columnId":.string("own-column"),"kind":.string("text"),"revision":.string(String(repeating:"a",count:64))]),"model":.object(["provider":.string("openai"),"model":.string("device-selected")]),"createdAt":.string(ISO8601DateFormatter().string(from:Date())),"state":.string("accepted")]))
    }
    @Test func receivedResultReopensWithSameIdentityWithoutProvider()async throws {
        let fixture=try Fixture();defer{fixture.clear()};let calls=Calls(),first=try await CompanionDatabaseActionJournal(cache:fixture.cache,vault:"vault")
        let intent=try accepted();let saved=try await first.perform(accepted:intent){await calls.next()}
        let reopened=try await CompanionDatabaseActionJournal(cache:fixture.cache,vault:"vault")
        let recovered=try await reopened.perform(accepted:accepted()){await calls.next()}
        #expect(recovered.id==saved.id);#expect(recovered.publicationInput==saved.publicationInput);#expect(await calls.value()==1)
        #expect(recovered.publicationInput?.objectValue?["text"] == .string("Received canonical text"))
    }
    @Test func unfinishedAndReviewedRequestsCannotPurchaseAgain()async throws {
        let fixture=try Fixture();defer{fixture.clear()};let calls=Calls(),journal=try await CompanionDatabaseActionJournal(cache:fixture.cache,vault:"vault"),intent=try accepted()
        try await journal.put(intent.changing(state:.running))
        await #expect(throws:APIError.self){try await journal.perform(accepted:self.accepted()){await calls.next()}}
        #expect(await calls.value()==0)
        var reviewed=intent.value.objectValue!;reviewed["state"] = .string("saved");reviewed["text"] = .string("Saved before regrant");reviewed["recoveryReviewRequired"] = .bool(true)
        try await journal.put(CompanionDatabaseActionCheckpoint(.object(reviewed)))
        await #expect(throws:APIError.self){try await journal.perform(accepted:self.accepted(),regenerateCompleted:true){await calls.next()}}
        #expect(await calls.value()==0)
    }
    @Test func onlyExplicitCompletedRegenerationUsesNewIdentity()async throws {
        let fixture=try Fixture();defer{fixture.clear()};let calls=Calls(),journal=try await CompanionDatabaseActionJournal(cache:fixture.cache,vault:"vault")
        let first=try await journal.perform(accepted:accepted()){await calls.next()}
        let next=try await journal.perform(accepted:accepted(),regenerateCompleted:true){await calls.next()}
        #expect(first.id != next.id);#expect(await calls.value()==2)
    }
    @Test func stagedPublicationKeepsPaidBytesAndSameIdentityInLedger() async throws {
        let fixture = try Fixture(); defer { fixture.clear() }
        let bytes = Data(repeating: 0x4e, count: 4 * 1024 * 1024 + 17), original = try accepted()
        var fields = original.value.objectValue!, request = fields["request"]!.objectValue!
        request["kind"] = .string("image"); fields["request"] = .object(request); fields["state"] = .string("saved")
        fields["bytes"] = .string(bytes.base64EncodedString()); fields["mime"] = .string("image/png")
        let checkpoint = try CompanionDatabaseActionCheckpoint(.object(fields))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let staged: JSONValue = .object(["blobUploadId":.string(checkpoint.id),"sha256":.string(hash),"mimeType":.string("image/png")])
        let prepared = try CompanionGenerationPublication(databaseAction: checkpoint, stagedImage: staged)
        let publication = try #require(prepared)
        #expect(publication.id == checkpoint.id); #expect(publication.args[0].objectValue?["bytes"] == nil)
        #expect(publication.checkpoint.objectValue?["bytes"] == fields["bytes"])
        let ledger = try DesktopJobLedger(cache: fixture.cache, vaultId: "vault", data: nil)
        try await ledger.archiveDatabaseActionCheckpoint(recordId: checkpoint.scope, checkpoint: checkpoint.value)
        try await ledger.preparePublication(publication)
        let pending = try #require(await ledger.all().first)
        #expect(pending.id == checkpoint.id); #expect(pending.method == "saveMobileDatabaseGeneratedCell"); #expect(pending.state == "pending")
        #expect(pending.checkpoint?.objectValue?["bytes"] == fields["bytes"])
        #expect(throws: DesktopBridgeError.self) { try CompanionGenerationPublication(databaseAction: checkpoint, stagedImage: .object(["blobUploadId":.string(checkpoint.id),"sha256":.string(String(repeating:"0",count:64)),"mimeType":.string("image/png")])) }
    }

    @Test func manualUncertainResolutionRetainsIntentAndAtomicallyReopensProviderFree() async throws {
        let fixture = try Fixture(); defer { fixture.clear() }
        var fields = try accepted().value.objectValue!, request = fields["request"]!.objectValue!
        request["kind"] = .string("button"); fields["request"] = .object(request); fields["model"] = .null
        let clicked = fields["createdAt"]!
        let attempt: JSONValue = .object(["clickedAt":clicked,"completedSteps":.int(1),"pendingWebhook":.int(1),"webhooks":.object([:])])
        fields["buttonResult"] = attempt; fields["state"] = .string("failed")
        fields["source"] = .object(["plan":.object(["operations":.array([
            .object(["type":.string("button_click"),"rowId":.string("own-row"),"columnId":.string("own-column"),"clicks":.int(1)]),
            .object(["type":.string("webhook"),"url":.string("https://never-called.invalid")]),
            .object(["type":.string("notify"),"id":.string("never-created")])])])])
        let original = try CompanionDatabaseActionCheckpoint(.object(fields))
        #expect(original.publicationInput == nil)
        let journal = try await CompanionDatabaseActionJournal(cache:fixture.cache,vault:"vault")
        try await journal.put(original)
        let ledger = try DesktopJobLedger(cache:fixture.cache,vaultId:"vault",data:nil)
        try await ledger.archiveDatabaseActionCheckpoint(recordId:original.scope,checkpoint:original.value)
        let prepared = try await journal.resolveInterruptedButton(original,ledger:ledger)
        #expect(prepared.id == original.id); #expect(prepared.method == "saveMobileDatabaseButtonResult")
        #expect(prepared.state == "pending"); #expect(prepared.jobId == nil)
        #expect(prepared.args[0].objectValue?["result"]?.objectValue?["interruptedExecution"] == attempt)
        #expect(prepared.args[0].objectValue?["result"]?.objectValue?["pendingWebhook"] == nil)
        let ledgerData = try await fixture.cache.data(vaultId:"vault",domain:.researchGeneration,recordId:"job-ledger-v1")
        let reopenedLedger = try DesktopJobLedger(cache:fixture.cache,vaultId:"vault",data:ledgerData)
        #expect(await reopenedLedger.all().first?.args == prepared.args)
        let reopenedJournal = try await CompanionDatabaseActionJournal(cache:fixture.cache,vault:"vault")
        let loaded = try await reopenedJournal.load(scope:original.scope)
        let reopened = try #require(loaded)
        #expect(reopened.id == original.id); #expect(reopened.publicationInput == prepared.args.first)
        #expect(try reopened.projectedAuthoredRows().isEmpty)
        await #expect(throws:DesktopBridgeError.self) { try await reopenedJournal.resolveInterruptedButton(original,ledger:reopenedLedger) }
        let calls = Calls()
        let reused = try await reopenedJournal.perform(accepted:original) { await calls.next() }
        #expect(reused.id == original.id); #expect(await calls.value() == 0)
    }

}
