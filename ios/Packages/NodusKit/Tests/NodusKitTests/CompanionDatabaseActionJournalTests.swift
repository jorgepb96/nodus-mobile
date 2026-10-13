import Foundation
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
}
