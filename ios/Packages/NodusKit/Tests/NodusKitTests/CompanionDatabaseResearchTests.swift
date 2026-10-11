import Foundation
import Testing
@testable import NodusKit

@Suite("Companion database research reading")
struct CompanionDatabaseResearchTests {
    private let sourceRevision = String(repeating:"a",count:64)
    private func snapshot(reading:CompanionDatabaseResearch.Reading = .init(readAt:nil,annotations:[]),revision:String = String(repeating:"b",count:64)) -> CompanionDatabaseResearch.Snapshot {
        .init(version:1,reportId:"report",reportTitle:"Informe de datos",sourceRevision:sourceRevision,readingRevision:revision,reading:reading)
    }
    private func annotation(comment:String = "Lectura propia") -> JSONValue {
        .object(["id":.string("comment"),"reportId":.string("report"),"scope":.string("source"),"kind":.string("comment"),"color":.null,
            "startOffset":.int(0),"endOffset":.int(2),"selectedText":.string("🌊"),"prefix":.string(""),"suffix":.string(" contexto"),
            "comment":.string(comment),"createdAt":.string("2026-10-11T00:00:00Z"),"updatedAt":.string("2026-10-11T00:00:00Z")])
    }
    private func setup() throws -> (PrivateBridgeCache,URL,KeychainStore,String) {
        let id = UUID().uuidString,directory = FileManager.default.temporaryDirectory.appendingPathComponent(id),keychain = KeychainStore(service:"nodus.tests.database-reading.\(id)")
        return (try PrivateBridgeCache(pairingId:id,directory:directory,keychain:keychain,readLimitBytes:1),directory,keychain,id)
    }
    private func outbox(_ cache:PrivateBridgeCache) async throws -> CompanionDatabaseReadingOutbox {
        try await .init(cache:cache,vaultId:"vault",data:cache.data(vaultId:"vault",domain:.writing,recordId:CompanionDatabaseReadingOutbox.storageKey))
    }
    @Test("Own annotations reopen outside the reusable download budget and nullable read state stays explicit")
    func durability() async throws {
        let (cache,directory,keychain,id) = try setup()
        defer { try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id)) }
        let store = try await outbox(cache);try await store.seed(snapshot())
        let reading = CompanionDatabaseResearch.Reading(readAt:nil,annotations:[annotation()]);try reading.validate(reportId:"report")
        try await store.edit(id:"report",sourceRevision:sourceRevision,reading:reading)
        let reopened = try await outbox(cache)
        #expect(try await reopened.entry(id:"report")?.draft == reading)
        #expect(try await reopened.entry(id:"report")?.state == .pending)
        let wire = try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(reading))
        #expect(wire.objectValue?["readAt"] == .null)
    }
    @Test("Lost acknowledgements retain the exact request identity after reopening")
    func lostAcknowledgement() async throws {
        let (cache,directory,keychain,id) = try setup()
        defer { try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id)) }
        let store = try await outbox(cache);try await store.seed(snapshot())
        try await store.edit(id:"report",sourceRevision:sourceRevision,reading:.init(readAt:nil,annotations:[annotation()]))
        actor Requests { var first:CompanionDatabaseResearch.Request?;func set(_ value:CompanionDatabaseResearch.Request) { first = value };func get()->CompanionDatabaseResearch.Request? { first } }
        let captured = Requests()
        await #expect(throws:URLError.self) { try await store.synchronize { _,request in await captured.set(request);throw URLError(.networkConnectionLost) } }
        let reopened = try await outbox(cache),expected = await captured.get()
        try await reopened.synchronize { id,request in
            #expect(id == "report");#expect(request == expected)
            return .init(id:request.id,snapshot:snapshot(reading:request.reading,revision:String(repeating:"c",count:64)))
        }
        #expect(try await reopened.entry(id:"report")?.state == .saved)
    }
    @Test("New edits made while a reply is in flight survive the older acknowledgement")
    func editsDuringSave() async throws {
        let (cache,directory,keychain,id) = try setup()
        defer { try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id)) }
        let store = try await outbox(cache);try await store.seed(snapshot())
        try await store.edit(id:"report",sourceRevision:sourceRevision,reading:.init(readAt:nil,annotations:[annotation()]))
        try await store.synchronize { _,request in
            if request.expectedReadingRevision == String(repeating:"b",count:64) {
                try await store.edit(id:"report",sourceRevision:sourceRevision,reading:.init(readAt:nil,annotations:[annotation(comment:"Edición posterior")]))
            }
            return .init(id:request.id,snapshot:snapshot(reading:request.reading,revision:request.expectedReadingRevision == String(repeating:"b",count:64) ? String(repeating:"c",count:64):String(repeating:"d",count:64)))
        }
        let saved = try await store.entry(id:"report")
        #expect(saved?.state == .saved);#expect(saved?.draft.annotations[0].objectValue?["comment"] == .string("Edición posterior"))
    }
    @Test("Annotations wait for their own report without losing edits or request identity")
    func publicationDependency() async throws {
        let (cache,directory,keychain,id) = try setup()
        defer { try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id)) }
        let store = try await outbox(cache);try await store.seed(snapshot())
        let own = CompanionDatabaseResearch.Reading(readAt:nil,annotations:[annotation()])
        try await store.edit(id:"report",sourceRevision:sourceRevision,reading:own)
        actor Requests {
            var value:CompanionDatabaseResearch.Request?
            func capture(_ request:CompanionDatabaseResearch.Request) { value = request }
            func get() -> CompanionDatabaseResearch.Request? { value }
        }
        let requests = Requests()
        try await store.synchronize { _,request in
            await requests.capture(request)
            throw CompanionDatabaseResearch.Dependency.waitingForReportPublication
        }
        let reopened = try await outbox(cache),expected = await requests.get()
        #expect(try await reopened.entry(id:"report")?.state == .pending)
        #expect(try await reopened.entry(id:"report")?.draft == own)
        try await reopened.synchronize { _,request in
            #expect(request == expected)
            return .init(id:request.id,snapshot:snapshot(reading:request.reading,revision:String(repeating:"c",count:64)))
        }
        #expect(try await reopened.entry(id:"report")?.state == .saved)
        #expect(try await reopened.entry(id:"report")?.draft == own)
    }
    @Test("A remote conflict preserves own work until an explicit choice")
    func conflicts() async throws {
        let (cache,directory,keychain,id) = try setup()
        defer { try? FileManager.default.removeItem(at:directory);try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id)) }
        let store = try await outbox(cache);try await store.seed(snapshot())
        let own = CompanionDatabaseResearch.Reading(readAt:nil,annotations:[annotation()])
        try await store.edit(id:"report",sourceRevision:sourceRevision,reading:own)
        let remote = snapshot(reading:.init(readAt:"2026-10-11T00:00:00Z",annotations:[]),revision:String(repeating:"c",count:64))
        let wire = try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(remote))
        try await store.synchronize { _,_ in throw APIError(status:409,code:"database_reading_conflict",message:"Cambios en Nodus",details:["remote":wire]) }
        #expect(try await store.entry(id:"report")?.state == .conflict);#expect(try await store.entry(id:"report")?.draft == own)
        try await store.resolve(id:"report",useMac:false)
        #expect(try await store.entry(id:"report")?.baselineRevision == remote.readingRevision)
        #expect(try await store.entry(id:"report")?.draft == own)
    }
    @Test("Chosen report packs retain whole bodies; the gallery returns metadata only")
    func selectedCopy() throws {
        let reports = (0..<241).map { index -> JSONValue in
            let report:JSONValue = .object(["id":.string("report-\(index)"),"runId":.string("run-\(index)"),"title":.string("Datos \(index)"),"markdown":.string("Texto íntegro \(index)"),"summary":.null,
                "reportType":.string("general"),"createdAt":.string("2026-10-11T00:00:00Z"),"updatedAt":.string("2026-10-11T00:00:00Z"),"readAt":.null,"metadata":.object([:]),"structured":.object([:]),"quality":.object([:]),"provenance":.object([:]),"bibliography":.array([])])
            return .object(["version":.int(1),"sourceRevision":.string(sourceRevision),"report":report])
        }
        let copy = try CompanionDatabaseResearchCopy(copies:[.object(["version":.int(1),"reports":.array(reports)])])
        let page = try copy.operation("listMobileDatabaseDeepResearchReports",args:[.object(["offset":.int(200),"limit":.int(100)])])
        #expect(page?.objectValue?["total"] == .int(241));#expect(page?.objectValue?["items"]?.arrayValue?.count == 41)
        #expect(page?.objectValue?["items"]?.arrayValue?.first?.objectValue?["markdown"] == nil)
        let detail = try copy.operation("getMobileDatabaseResearchReader",args:[.string("report-240")])
        #expect(detail?.objectValue?["report"]?.objectValue?["markdown"] == .string("Texto íntegro 240"))
        #expect(throws:(any Error).self) { try copy.operation("getMobileDatabaseResearchReader",args:[.string("missing")]) }
    }
}
