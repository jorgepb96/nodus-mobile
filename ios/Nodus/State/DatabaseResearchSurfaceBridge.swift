import Foundation
import NodusKit

@MainActor
final class DatabaseResearchSurfaceBridge {
    static let methods:Set<String> = ["getDatabaseDeepResearchReport","getDatabaseResearchExportSource","listMobileDatabaseDeepResearchReports","listDatabaseDeepResearchReportAnnotations","createDatabaseDeepResearchReportAnnotation","updateDatabaseDeepResearchReportComment","deleteDatabaseDeepResearchReportAnnotation","setDatabaseDeepResearchReportRead"]
    private let session:SpaceSession
    private let localReader:(String) async throws -> JSONValue?
    private var sources:[String:CompanionDatabaseResearch.Source] = [:]
    init(session:SpaceSession,localReader:@escaping (String) async throws -> JSONValue? = { _ in nil }) { self.session = session;self.localReader = localReader }
    private func journal(_ pairing:DesktopBridgePairing,_ vault:String) async throws -> CompanionDatabaseReadingOutbox {
        guard !pairing.isExpired,pairing.vaultIds.contains(vault),pairing.domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
        return try await CompanionDatabaseReadingOutboxes.shared.outbox(pairingId:pairing.id,vaultId:vault)
    }
    func perform(_ method:String,args:[JSONValue],client:DesktopBridgeClient,pairing:DesktopBridgePairing,vaultId:String,onOffline:(Bool)->Void) async throws -> JSONValue {
        guard !pairing.isExpired,pairing.vaultIds.contains(vaultId),pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
        let cache = try PrivateBridgeCache(pairingId:pairing.id)
        if method == "getDatabaseDeepResearchReport",args.count == 1,let id = args[0].stringValue {
            return try await load(id,client:client,pairing:pairing,vault:vaultId,cache:cache,onOffline:onOffline).report
        }
        if method == "getDatabaseResearchExportSource",args.count == 1,let id = args[0].stringValue {
            let source = try await load(id,client:client,pairing:pairing,vault:vaultId,cache:cache,onOffline:onOffline)
            var value = try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(source)).objectValue!
            if let own = try await localReader(id),own.objectValue?["published"] == .bool(false),let packs = own.objectValue?["sourcePacks"] { value["sourcePacks"] = packs }
            return .object(value)
        }
        if method == "listMobileDatabaseDeepResearchReports" {
            let key = try CompanionDocumentOutbox.operationKey(method,args)
            let cached = try await cache.data(vaultId:vaultId,domain:.corpus,recordId:key)
            var value:JSONValue
            do {
                value = try await client.operation(vaultId:vaultId,method:method,args:args,timeout:4); onOffline(false)
                try await cache.store(JSONEncoder.nodus.encode(value),vaultId:vaultId,domain:.corpus,recordId:key)
            } catch {
                guard isPrivateBridgeOffline(error) else { throw error }
                if let copy = try await CompanionDatabaseResearchCopy.downloaded(cache:cache,vaultId:vaultId),let page = try copy.operation(method,args:args) { value = page }
                else if let cached { value = try JSONDecoder.nodus.decode(JSONValue.self,from:cached) }
                else { throw error }
                onOffline(true)
            }
            if pairing.domains.contains(.writing),var page = value.objectValue,let rows = page["items"]?.arrayValue {
                let store = try await journal(pairing,vaultId),entries = await store.all()
                page["items"] = .array(rows.map { row in
                    guard var item = row.objectValue,let id = item["id"]?.stringValue,let entry = entries[id],entry.state != .saved else { return row }
                    item["readAt"] = entry.draft.readAt.map(JSONValue.string) ?? .null; return .object(item)
                }); value = .object(page)
            }
            return value
        }
        guard let id = args.first?.stringValue ?? args.first?.objectValue?["reportId"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
        let reportId:String
        if ["updateDatabaseDeepResearchReportComment","deleteDatabaseDeepResearchReportAnnotation"].contains(method) {
            let store = try await journal(pairing,vaultId)
            guard let owner = await store.all().first(where:{$0.value.draft.annotations.contains(where:{$0.objectValue?["id"] == .string(id)})}) else { throw DesktopBridgeError.malformedResponse }
            reportId = owner.key
        } else { reportId = id }
        if method == "listDatabaseDeepResearchReportAnnotations",!pairing.domains.contains(.writing) {
            return try await client.operation(vaultId:vaultId,method:method,args:args)
        }
        let source:CompanionDatabaseResearch.Source
        if let known = sources[reportId] { source = known }
        else { source = try await load(reportId,client:client,pairing:pairing,vault:vaultId,cache:cache,onOffline:onOffline) }
        let store = try await journal(pairing,vaultId)
        guard let entry = try await store.entry(id:reportId,sourceRevision:source.sourceRevision) else { throw APIError(status:409,code:"database_reading_baseline_missing",message:"Conecta el Mac una vez para preparar las anotaciones de este informe.") }
        var reading = entry.draft
        if method == "listDatabaseDeepResearchReportAnnotations" { return .array(reading.annotations) }
        let result:JSONValue,now = ISO8601DateFormatter().string(from:Date())
        if method == "setDatabaseDeepResearchReportRead",args.count == 2,let read = args[1].boolValue {
            reading.readAt = read ? now:nil
            var report = source.report.objectValue!; report["readAt"] = reading.readAt.map(JSONValue.string) ?? .null; result = .object(report)
        } else if method == "createDatabaseDeepResearchReportAnnotation",args.count == 1,var annotation = args[0].objectValue,
                  let kind = annotation["kind"]?.stringValue {
            let scope = annotation["scope"]?.stringValue ?? "source"
            let identity = kind == "bookmark" ? "database-research-bookmark:\(reportId):\(scope)":"mobile-database-annotation:\(UUID().uuidString)"
            let old = reading.annotations.first { $0.objectValue?["id"] == .string(identity) }
            annotation["id"] = .string(identity); annotation["reportId"] = .string(reportId); annotation["scope"] = .string(scope)
            annotation["color"] = kind == "highlight" ? annotation["color"] ?? .null:.null
            annotation["comment"] = kind == "comment" ? .string(annotation["comment"]?.stringValue?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""):.null
            annotation["prefix"] = annotation["prefix"] ?? .string(""); annotation["suffix"] = annotation["suffix"] ?? .string("")
            annotation["createdAt"] = old?.objectValue?["createdAt"] ?? .string(now); annotation["updatedAt"] = .string(now)
            result = .object(annotation); reading.annotations.removeAll { $0.objectValue?["id"] == .string(identity) }; reading.annotations.append(result)
        } else if method == "updateDatabaseDeepResearchReportComment",args.count == 2,let comment = args[1].stringValue,
                  let index = reading.annotations.firstIndex(where:{$0.objectValue?["id"] == .string(id)}),var annotation = reading.annotations[index].objectValue,annotation["kind"] == .string("comment") {
            annotation["comment"] = .string(comment.trimmingCharacters(in:.whitespacesAndNewlines)); annotation["updatedAt"] = .string(now)
            result = .object(annotation); reading.annotations[index] = result
        } else if method == "deleteDatabaseDeepResearchReportAnnotation",args.count == 1 {
            reading.annotations.removeAll { $0.objectValue?["id"] == .string(id) }; result = .null
        } else { throw DesktopBridgeError.malformedResponse }
        try await store.edit(id:reportId,sourceRevision:source.sourceRevision,reading:reading)
        session.didChangeDatabaseReading()
        Task { await session.synchronizeCompanionChanges() }
        return result
    }
    private func load(_ id:String,client:DesktopBridgeClient,pairing:DesktopBridgePairing,vault:String,cache:PrivateBridgeCache,onOffline:(Bool)->Void) async throws -> CompanionDatabaseResearch.Source {
        let local = try await localReader(id)
        if let local,local.objectValue?["published"] == .bool(false),let value = local.objectValue?["source"],let reading = local.objectValue?["reading"] {
            var source = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Source.self,from:JSONEncoder.nodus.encode(value));try source.validate(id:id)
            if pairing.domains.contains(.writing) {
                let store = try await journal(pairing,vault),before = await store.revision
                try await store.seed(JSONDecoder.nodus.decode(CompanionDatabaseResearch.Snapshot.self,from:JSONEncoder.nodus.encode(reading)))
                if let entry = try await store.entry(id:id,sourceRevision:source.sourceRevision),var fields = source.report.objectValue,var wrapper = value.objectValue {
                    fields["readAt"] = entry.draft.readAt.map(JSONValue.string) ?? .null;wrapper["report"] = .object(fields)
                    source = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Source.self,from:JSONEncoder.nodus.encode(JSONValue.object(wrapper)))
                }
                if await store.revision != before { session.didChangeDatabaseReading() }
            }
            sources[id] = source;return source
        }
        let key = try CompanionDocumentOutbox.operationKey("getMobileDatabaseResearchReader",[.string(id)])
        let cached = try await cache.data(vaultId:vault,domain:.corpus,recordId:key) ?? local?.objectValue?["source"].map { try JSONEncoder.nodus.encode($0) }
        let selected = try await cache.hasDownloadedData(vaultId:vault,domain:.corpus,recordId:CompanionDatabaseResearchCopy.recordId)
        let value:JSONValue,online:Bool
        do {
            value = try await client.operation(vaultId:vault,method:"getMobileDatabaseResearchReader",args:[.string(id)],timeout:cached != nil || selected ? 4:nil); online = true
        } catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            if let cached { value = try JSONDecoder.nodus.decode(JSONValue.self,from:cached) }
            else if let copy = try await CompanionDatabaseResearchCopy.downloaded(cache:cache,vaultId:vault),let stored = try copy.operation("getMobileDatabaseResearchReader",args:[.string(id)]) { value = stored }
            else { throw error }
            online = false
        }
        var source = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Source.self,from:JSONEncoder.nodus.encode(value)); try source.validate(id:id)
        if online { try await cache.store(JSONEncoder.nodus.encode(value),vaultId:vault,domain:.corpus,recordId:key) }
        if pairing.domains.contains(.writing) {
            let store = try await journal(pairing,vault)
            if online {
                do { let remote = try await client.databaseResearchReading(vaultId:vault,reportId:id)
                    guard remote.sourceRevision == source.sourceRevision else { throw DesktopBridgeError.malformedResponse }
                    let before = await store.revision; try await store.seed(remote)
                    if await store.revision != before { session.didChangeDatabaseReading() }
                } catch { guard isPrivateBridgeOffline(error) else { throw error } }
            }
            if let entry = try? await store.entry(id:id,sourceRevision:source.sourceRevision),var report = source.report.objectValue {
                report["readAt"] = entry.draft.readAt.map(JSONValue.string) ?? .null
                var wrapper = value.objectValue!; wrapper["report"] = .object(report)
                source = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Source.self,from:JSONEncoder.nodus.encode(JSONValue.object(wrapper)))
            }
        }
        sources[id] = source; onOffline(!online); return source
    }
}
