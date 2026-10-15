import CryptoKit
import Foundation
import Testing
import WebKit
import NodusKit
@testable import Nodus

@Suite("Scoped report figure reads", .serialized)
@MainActor struct CompanionResearchFigureReadTests {
    @Test("poster and embedded-file schemes keep their distinct manifest identities")
    func sourceKinds() {
        let owner = String(repeating: "a", count: 64)
        let poster = "10f1cf1a-6545-4704-8378-416035d55a01"
        let embedded = "10f1cf1a-6545-4704-8378-416035d55a02"
        let image = "nodus-image://chat/\(owner)/\(poster)"
        let file = "nodus-capability://chat/\(owner)/\(embedded)"
        let context: JSONValue = .object(["manifest": .object(["figures": .array([
            .object(["owner": .string(owner), "poster": .string(image),
                "view": .object(["nodes": .array([.object(["kind": .string("image"), "attachmentId": .string(embedded)])])])])
        ])])])
        #expect(CompanionResearchFigures.allows(image, context: context))
        #expect(CompanionResearchFigures.allows(file, context: context))
        #expect(!CompanionResearchFigures.allows("nodus-image://chat/\(owner)/\(embedded)", context: context))
        #expect(!CompanionResearchFigures.allows("nodus-capability://chat/\(owner)/\(poster)", context: context))
    }

    @Test("bounded chunk decoding rejects wrong offsets, fractional sizes and corrupt final hashes")
    func chunks() async throws {
        let bytes=Data(repeating:7,count:600_000),sha=hash(bytes)
        func response(_ offset:Int,_ data:Data)->JSONValue { .object(["offset":.int(Int64(offset)),"byteCount":.int(Int64(bytes.count)),"mimeType":.string("image/png"),"sha256":.string(sha),"base64":.string(data.base64EncodedString())]) }
        let first=try CompanionLiveDocumentVisualRead.decode(response(0,bytes.prefix(524288)),offset:0,count:524288)
        #expect(first.total == bytes.count)
        #expect(throws:DesktopBridgeError.self) { try CompanionLiveDocumentVisualRead.decode(response(1,bytes.prefix(10)),offset:0,count:524288) }
        var fractional=try #require(response(0,bytes.prefix(10)).objectValue);fractional["byteCount"] = .double(600000.5)
        #expect(throws:DesktopBridgeError.self) { try CompanionLiveDocumentVisualRead.decode(.object(fractional),offset:0,count:524288) }
        let actual=try await CompanionLiveDocumentVisualRead.assemble { offset,count in try CompanionLiveDocumentVisualRead.decode(response(Int(offset),bytes.subdata(in:Int(offset)..<min(bytes.count,Int(offset)+count))),offset:offset,count:count) }
        #expect(actual.data == bytes)
        await #expect(throws:DesktopBridgeError.self) {
            _ = try await CompanionLiveDocumentVisualRead.assemble { offset,count in
                let chunk=bytes.subdata(in:Int(offset)..<min(bytes.count,Int(offset)+count))
                return .init(data:chunk,total:bytes.count,mime:"image/png",sha256:String(repeating:"0",count:64))
            }
        }
    }
    @Test("selected report context and actual encrypted chunks feed the PDF scheme without a network or authoring session")
    func selectedPack() async throws {
        let fixture=try Fixture();defer { fixture.clean() }
        let bytes=Data((0..<700_000).map{UInt8(truncatingIfNeeded:$0)}),sha=hash(bytes),source="nodus-image://chat/\(fixture.owner)/\(fixture.asset)"
        let manifest:JSONValue = .object(["schemaVersion":.int(1),"vaultId":.string(fixture.vault),"target":.object(["kind":.string("deep-research"),"id":.string(fixture.report)]),"revision":.string(UUID().uuidString),"contentHash":.string(String(repeating:"a",count:64)),"figures":.array([.object(["id":.string(UUID().uuidString),"owner":.string(fixture.owner),"state":.string("ready"),"poster":.string(source)])])])
        let draft:JSONValue = .object(["title":.string("Chosen source"),"draftMarkdown":.string("Exact selected prose"),"abstract":.string("")])
        let keys=["companion:report-figure:v1:fixture:0","companion:report-figure:v1:fixture:1"]
        let context:JSONValue = .object(["origin":.string("downloaded-mac"),"vaultId":.string(fixture.vault),"reportId":.string(fixture.report),"manifest":manifest,"draftHash":.string(try CompanionDownloadedResearchFigures.draftHash(draft)),"assets":.array([.object(["source":.string(source),"mimeType":.string("image/png"),"byteCount":.int(Int64(bytes.count)),"sha256":.string(sha),"chunks":.array(keys.map(JSONValue.string))])])])
        let entry:JSONValue = .object(["detail":.object(["report":.object(["id":.string(fixture.report),"draft":draft]),"image":.null,"translations":.array([]),"annotations":.array([])]),"documentHTML":.string("<!doctype html><html><head></head><body>Exact selected prose</body></html>"),"figureContext":context])
        let copy:JSONValue = .object(["version":.int(1),"entries":.array([entry])])
        let records:[PrivateBridgeCache.ReadPackRecord] = [.init(domain:.corpus,recordId:CompanionResearchCorpusCopy.recordId,data:try JSONEncoder.nodus.encode(copy)),.init(domain:.corpus,recordId:keys[0],data:bytes.prefix(524288)),.init(domain:.corpus,recordId:keys[1],data:bytes.dropFirst(524288))]
        try await fixture.cache.store(Data("keep".utf8),vaultId:fixture.vault,domain:.researchGeneration,recordId:"fixture-authored")
        let pack=try await fixture.cache.saveReadPack(vaultId:fixture.vault,title:"Only the chosen report",expiresAt:Date().addingTimeInterval(3600),records:records)
        FigureReadNoNetwork.reset()
        let loaded=try #require(try await CompanionResearchFigures.context(session:fixture.session,reportID:fixture.report,downloadedOnly:true))
        #expect(loaded == context)
        let content=try await CompanionResearchFigures.load(source,context:loaded,session:fixture.session)
        #expect(content.data == bytes)
        let html=try await ReportDocument.html(session:fixture.session,reportId:fixture.report,downloadedOnly:true)
        #expect(html.contains("Exact selected prose"))
        let scheme=CompanionResearchFigureScheme(session:fixture.session,context:loaded),task=FigureReadSchemeTask(source),web=WKWebView()
        scheme.webView(web,start:task)
        for _ in 0..<300 where !task.finished && task.failure == nil { try await Task.sleep(for:.milliseconds(20)) }
        #expect(task.finished);#expect(task.failure == nil);#expect(task.bytes == bytes)
        #expect(FigureReadNoNetwork.count == 0)
        var corrupt=Data(bytes.prefix(524288));corrupt[0] ^= 255
        _ = try await fixture.cache.saveReadPack(id:pack.id,vaultId:fixture.vault,title:"Corrupt response fixture",expiresAt:Date().addingTimeInterval(3600),records:[records[0],.init(domain:.corpus,recordId:keys[0],data:corrupt),records[2]])
        let failedScheme=CompanionResearchFigureScheme(session:fixture.session,context:loaded),failedTask=FigureReadSchemeTask(source)
        failedScheme.webView(web,start:failedTask)
        for _ in 0..<300 where !failedTask.finished && failedTask.failure == nil { try await Task.sleep(for:.milliseconds(20)) }
        #expect(!failedTask.finished);#expect(failedTask.failure != nil,"the actual scheme rejects a corrupted full-asset hash")
        await #expect(throws:DesktopBridgeError.self) { _ = try await CompanionResearchFigures.load(source,context:loaded,session:fixture.session) }
        try await fixture.cache.removeReadPack(id:pack.id,vaultId:fixture.vault)
        await #expect(throws: (any Error).self) { _ = try await CompanionResearchFigures.load(source,context:loaded,session:fixture.session) }
        #expect(FigureReadNoNetwork.count == 0, "missing selected chunks never fall through to the Mac")
        #expect(try await fixture.cache.data(vaultId:fixture.vault,domain:.researchGeneration,recordId:"fixture-authored") == Data("keep".utf8))
    }
    @Test("a public or demo-style connection does not invent a private Mac bridge")
    func noPrivateFallback() async throws {
        let fixture=try Fixture(paired:false);defer { fixture.clean() };FigureReadNoNetwork.reset()
        fixture.session.aiExecutionMode = .live
        let context=try await CompanionResearchFigures.context(session:fixture.session,reportID:fixture.report)
        #expect(context == nil);#expect(try await CompanionResearchFigures.context(session:fixture.session,reportID:fixture.report,downloadedOnly:true) == nil);#expect(FigureReadNoNetwork.count == 0)
    }
    private func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    private struct Fixture {
        let session:SpaceSession,cache:PrivateBridgeCache,vault:String,cacheID:String,root:URL
        let report=UUID().uuidString,asset=UUID().uuidString.lowercased(),owner=String(repeating:"b",count:64)
        init(paired:Bool = true) throws {
            root=URL.temporaryDirectory.appendingPathComponent("figure-selected-"+UUID().uuidString)
            let connection=AppModel.Connection(origin:"https://figure-selected.invalid",spaceId:UUID().uuidString,spaceName:"Isolated source",serverName:"Fixture",role:.writer,vaultId:UUID().uuidString,desktopPairingId:paired ? "figure-fixture-"+UUID().uuidString : nil)
            let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[FigureReadNoNetwork.self]
            let client=NodusClient(address:ServerAddress(trusted:connection.origin),token:"fixture-only",session:URLSession(configuration:config),cache:ResponseCache(directory:root))
            session=SpaceSession(connection:connection,client:client,mirrorDirectory:root)
            let scope=try session.surfaceStorageScope();vault=scope.recordVaultId;cacheID=scope.cacheId;cache=try PrivateBridgeCache(pairingId:scope.cacheId)
        }
        func clean() { try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:PrivateBridgeCache.defaultDirectory.appendingPathComponent("bridge-"+cacheID));try? KeychainStore().remove(KeychainStore.desktopBridgeCacheKey(pairingId:cacheID));UserDefaults.standard.removeObject(forKey:"ai-execution-mode:\(session.connection.id)") }
    }
}
private nonisolated final class FigureReadNoNetwork:URLProtocol,@unchecked Sendable {
    private static let lock=NSLock();nonisolated(unsafe) private static var requests=0
    static var count:Int { lock.lock();defer{lock.unlock()};return requests }
    static func reset(){lock.lock();requests=0;lock.unlock()}
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading(){Self.lock.lock();Self.requests += 1;Self.lock.unlock();client?.urlProtocol(self,didFailWithError:URLError(.badServerResponse))}
    override func stopLoading(){}
}
@MainActor private final class FigureReadSchemeTask:NSObject,@preconcurrency WKURLSchemeTask {
    nonisolated let request:URLRequest
    var bytes=Data(),finished=false;var failure:Error?
    init(_ source:String){request=URLRequest(url:URL(string:source)!)}
    func didReceive(_ response:URLResponse){}
    func didReceive(_ data:Data){bytes.append(data)}
    func didFinish(){finished=true}
    func didFailWithError(_ error:Error){failure=error}
}
