import Foundation
import Testing
@testable import NodusKit

@Suite("Explicit downloaded study knowledge") struct CompanionStudyKnowledgeCopyTests {
    private func page(_ offset:Int,total:Int=161,revision:String=String(repeating:"a",count:64)) -> JSONValue {
        let subject:JSONValue = .object(["id":.string("subject"),"courseId":.string("course"),"name":.string("History")])
        let ideas=(offset..<min(offset+80,total)).map { i in JSONValue.object(["id":.string("idea-\(i)"),"subjectId":.string("subject"),"evidence":.array([]),"connections":.array([])]) }
        var value:[String:JSONValue] = ["version":.int(1),"vaultId":.string("vault"),"subjectId":.string("subject"),"revision":.string(revision),"offset":.int(Int64(offset)),"limit":.int(80),"total":.int(Int64(total)),"hasMore":.bool(offset+ideas.count<total),"workspace":.object(["subjects":.array([subject]),"courses":.array([.object(["id":.string("course")])])]),"ideas":.array(ideas),"details":.array(ideas)]
        if offset == 0 { value["graph"] = .object(["nodes":.array((0..<total).map{.object(["id":.string("idea-\($0)")])}),"edges":.array([])]) }
        return .object(value)
    }
    @Test("161 complete dossiers span three revision-bound pages; partial or mixed sources never complete")
    func pages() throws {
        var source=try CompanionStudyKnowledgeCopy(first:page(0),vaultId:"vault",subjectId:"subject")
        #expect(source.count == 80)
        #expect(throws:DesktopBridgeError.self){try source.completed()}
        let before=source.value
        #expect(throws:DesktopBridgeError.self){try source.append(page(80,revision:String(repeating:"b",count:64)))}
        #expect(source.value == before)
        #expect(throws:DesktopBridgeError.self){try source.append(page(160))}
        try source.append(page(80));try source.append(page(160))
        let saved = try source.completed()
        #expect(saved.objectValue?["details"]?.arrayValue?.count == 161)
        #expect(try CompanionStudyKnowledgeCopy(saved:saved,vaultId:"vault").completed() == saved)
        #expect(throws:DesktopBridgeError.self){try CompanionStudyKnowledgeCopy(first:page(0),vaultId:"other",subjectId:"subject")}
        #expect(throws:DesktopBridgeError.self){try CompanionStudyKnowledgeCopy(first:page(0),vaultId:"vault",subjectId:"other")}
    }
    @Test("Downloaded copies expire, delete exactly, and use the common encrypted-copy budget")
    func expiryDeletionBudget() async throws {
        let pairing=UUID().uuidString,directory=URL.temporaryDirectory.appendingPathComponent("study-copy-"+pairing)
        let keychain=KeychainStore(service:"nodus.tests.study-copy."+pairing)
        defer{try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:pairing));try? FileManager.default.removeItem(at:directory)}
        let cache=try PrivateBridgeCache(pairingId:pairing,directory:directory,keychain:keychain,readLimitBytes:2_000_000)
        let source=try CompanionStudyKnowledgeCopy(first:page(0,total:1),vaultId:"vault",subjectId:"subject")
        let bytes=try JSONEncoder.nodus.encode(source.completed())
        let record=PrivateBridgeCache.ReadPackRecord(domain:.corpus,recordId:CompanionStudyKnowledgeCopy.recordId,data:bytes)
        let keep=UUID(),remove=UUID()
        try await cache.saveReadPack(id:keep,vaultId:"vault",title:"Selected history",expiresAt:Date().addingTimeInterval(30*86400),records:[record])
        try await cache.saveReadPack(id:remove,vaultId:"vault",title:"Other selection",expiresAt:Date().addingTimeInterval(7*86400),records:[record])
        try await cache.removeReadPack(id:remove,vaultId:"vault")
        let retained=try await cache.downloadedData(vaultId:"vault",domain:.corpus,recordId:CompanionStudyKnowledgeCopy.recordId)
        #expect(retained == [bytes])
        try await cache.removeReadPack(id:keep,vaultId:"vault")
        let missing=try await cache.downloadedData(vaultId:"vault",domain:.corpus,recordId:CompanionStudyKnowledgeCopy.recordId)
        #expect(missing.isEmpty)
        try await cache.saveReadPack(id:UUID(),vaultId:"vault",title:"Expires",expiresAt:Date().addingTimeInterval(0.15),records:[record])
        try await Task.sleep(for:.milliseconds(250))
        let expired=try await cache.downloadedData(vaultId:"vault",domain:.corpus,recordId:CompanionStudyKnowledgeCopy.recordId)
        #expect(expired.isEmpty)
        let bounded=try PrivateBridgeCache(pairingId:pairing,directory:directory,keychain:keychain,readLimitBytes:1)
        await #expect(throws:PrivateBridgeCache.ReadPackError.self){try await bounded.saveReadPack(id:UUID(),vaultId:"vault",title:"Too large",expiresAt:Date().addingTimeInterval(60),records:[record])}
        let noPartial=try await bounded.downloadedData(vaultId:"vault",domain:.corpus,recordId:CompanionStudyKnowledgeCopy.recordId)
        #expect(noPartial.isEmpty)
    }
}
