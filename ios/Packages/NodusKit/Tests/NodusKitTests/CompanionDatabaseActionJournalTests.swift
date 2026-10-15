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

}
