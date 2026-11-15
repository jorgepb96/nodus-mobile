import Foundation
import Testing
@testable import NodusKit

@Suite("Closed native Mac chat protocol")
struct CompanionLiveChatTests {
    @Test("Frozen requests keep the same identity and cannot carry provider keys")
    func requestContract() throws {
        let requestId=UUID().uuidString,answer=UUID().uuidString,id=UUID().uuidString
        let edit:JSONValue = .object(["version":.int(1),"id":.string(requestId),"conversationId":.string(id),"action":.string("save"),"expectedRevision":.null,"draft":.object(["title":.string("Consulta"),"archived":.bool(false),"messages":.array([.object(["id":.string(UUID().uuidString),"role":.string("user"),"content":.string("Pregunta 🌊")])])])])
        let generation:JSONValue = .object(["model":.object(["provider":.string("codex"),"model":.string("Modelo del Mac")])])
        let request=try CompanionLiveChatRequest(requestId:requestId,kind:.research,answerId:answer,edit:edit,generation:generation)
        let reopened=try JSONDecoder.nodus.decode(CompanionLiveChatRequest.self,from:JSONEncoder.nodus.encode(request))
        #expect(reopened == request);#expect(try reopened.value == request.value)
        #expect(DesktopBridgeClient.jobMethods.contains("streamMobileCompanionChat"))
        #expect(!DesktopBridgeClient.providerFreeJobMethods.contains("streamMobileCompanionChat"))
        #expect(throws:DesktopBridgeError.self) { try CompanionLiveChatRequest(requestId:UUID().uuidString,kind:.research,answerId:answer,edit:edit,generation:generation) }
        #expect(throws:DesktopBridgeError.self) { try CompanionLiveChatRequest(requestId:requestId,kind:.research,answerId:answer,edit:edit,generation:.object(["model":.object(["provider":.string("codex"),"model":.string("Modelo"),"apiKey":.string("forbidden")])])) }
        #expect(throws:DesktopBridgeError.self) { try CompanionLiveChatRequest(requestId:requestId,kind:.study,answerId:answer,edit:edit,generation:.object(["webSearch":.string("auto")])) }
    }
    @Test("Pending cancellation survives restart and prevents automatic generation")
    func cancellationAndRelease() async throws {
        let pairing=UUID().uuidString,directory=URL.temporaryDirectory.appendingPathComponent(UUID().uuidString),keychain=KeychainStore(service:"nodus.tests.native-live.\(pairing)")
        defer { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:pairing));try? FileManager.default.removeItem(at:directory) }
        let cache=try PrivateBridgeCache(pairingId:pairing,directory:directory,keychain:keychain),id=UUID().uuidString,args:[JSONValue]=[.string("Own frozen question")]
        let ledger=try DesktopJobLedger(cache:cache,vaultId:"vault",data:nil)
        _=try await ledger.prepare(id:id,method:"streamMobileCompanionChat",args:args);try await ledger.requestCancellation(id:id)
        let reopened=try DesktopJobLedger(cache:cache,vaultId:"vault",data:await cache.data(vaultId:"vault",domain:.researchGeneration,recordId:"job-ledger-v1"))
        #expect(await reopened.all().first?.cancellationRequested == true)
        try await reopened.synchronize(list:{[]},submit:{ _ in Issue.record("A cancelled pending request must not be generated");throw DesktopBridgeError.malformedResponse })
        #expect(await reopened.all().first?.jobId == nil)
        try await reopened.cancelUnsubmitted(id:id);try await reopened.releaseLivePayload(id:id)
        #expect(await reopened.all().first?.args.isEmpty == true)
        #expect(await reopened.all().first?.state == "cancelled")
        #expect(try await reopened.prepare(id:id,method:"streamMobileCompanionChat",args:args).state == "cancelled")
        await #expect(throws:DesktopBridgeError.self) { try await reopened.prepare(id:id,method:"streamMobileCompanionChat",args:[.string("Changed")]) }
    }
}
