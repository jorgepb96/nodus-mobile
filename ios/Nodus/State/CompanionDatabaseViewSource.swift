import Foundation
import NodusKit

/// A saved view is the Desktop query, including its filter, sort and attached
/// sources. Never substitute the unfiltered database when a view cannot load.
struct CompanionDatabaseViewSource {
    let definition: JSONValue
    let rows: [JSONValue]
    let revision: String
    @MainActor static func loadDownloaded(session: SpaceSession, viewId: String) async throws -> Self {
        let (vault, _, _) = try privateBridgeConnection(session, domain: .corpus)
        let reads = PrivateBridgeReadBatch(session: session, downloadedOnly: true)
        let response = try await reads.operation("getMobileLinkedDatabaseRead", [.object(["action": .string("definition"), "input": .string(viewId)])])
        guard response.objectValue?["version"] == .int(1), response.objectValue?["vaultId"] == .string(vault),
              response.objectValue?["action"] == .string("definition"), let definition = response.objectValue?["data"],
              definition.objectValue?["viewId"] == .string(viewId), let linked = definition.objectValue?["sources"]?.arrayValue,
              !linked.isEmpty, definition.objectValue?["properties"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        var sources: [String: JSONValue] = [:]
        for source in linked {
            try Task.checkCancellation()
            guard let id = source.objectValue?["databaseId"]?.stringValue, !id.isEmpty else { throw DesktopBridgeError.malformedResponse }
            if sources[id] == nil { sources[id] = try await CompanionDatabasePresentationSource.downloaded(session: session, database: id) }
        }
        let value = try await CompanionDatabaseQueryRuntime.query(.object(["version": .int(1), "vaultId": .string(vault),
            "viewId": .string(viewId), "definition": definition, "sources": .object(sources)]))
        guard value.objectValue?["version"] == .int(1), value.objectValue?["vaultId"] == .string(vault),
              value.objectValue?["viewId"] == .string(viewId), value.objectValue?["definition"] == definition,
              let rows = value.objectValue?["rows"]?.arrayValue, let revision = value.objectValue?["revision"]?.stringValue,
              revision.hasPrefix("offline:") else { throw DesktopBridgeError.malformedResponse }
        return .init(definition: definition, rows: rows, revision: revision)
    }
    @MainActor static func load(vault:String,viewId:String,
        fetch:(String,[JSONValue]) async throws -> JSONValue) async throws -> Self {
        let definitionArgs=[JSONValue.object(["action":.string("definition"),"input":.string(viewId)])]
        let response=try await fetch("getMobileLinkedDatabaseRead",definitionArgs)
        guard response.objectValue?["version"] == .int(1),response.objectValue?["vaultId"] == .string(vault),
            response.objectValue?["action"] == .string("definition"),let definition=response.objectValue?["data"],
            definition.objectValue?["viewId"] == .string(viewId),definition.objectValue?["sources"]?.arrayValue != nil,
            definition.objectValue?["properties"]?.arrayValue != nil else {throw DesktopBridgeError.malformedResponse}
        var firstArgs:[JSONValue]?,firstPage:JSONValue?
        var cursor=JSONValue.null,cursors=Set<String>(),ids=Set<String>(),rows:[JSONValue]=[],revision:String?,total:Int?,hash:String?
        repeat {
            try Task.checkCancellation()
            let query=JSONValue.object(["viewId":.string(viewId),"sourceId":.null,"localFilter":.null,"cursor":cursor,"limit":.int(30)])
            let args=[JSONValue.object(["action":.string("rows"),"input":query])]
            let page=try await fetch("getMobileLinkedDatabaseRead",args)
            if firstArgs == nil {firstArgs=args;firstPage=page}
            guard page.objectValue?["version"] == .int(1),page.objectValue?["vaultId"] == .string(vault),page.objectValue?["action"] == .string("rows"),let data=page.objectValue?["data"]?.objectValue,
                let current=data["revision"]?.stringValue,revision == nil || revision == current,
                let count=data["totalCount"]?.intValue,count >= 0,total == nil || total == count,
                let queryHash=data["queryHash"]?.stringValue,hash == nil || hash == queryHash,
                data["sources"] == definition.objectValue?["sources"],data["properties"] == definition.objectValue?["properties"],
                let part=data["rows"]?.arrayValue,part.count <= 30 else {throw DesktopBridgeError.malformedResponse}
            for row in part {guard let id=row.objectValue?["id"]?.stringValue,!id.isEmpty,ids.insert(id).inserted else {throw DesktopBridgeError.malformedResponse}}
            rows.append(contentsOf:part);revision=current;total=count;hash=queryHash;cursor=data["nextCursor"] ?? .null
            guard rows.count <= count,data["hasMore"]?.boolValue == (cursor != .null) else {throw DesktopBridgeError.malformedResponse}
            if let next=cursor.stringValue {guard !part.isEmpty,cursors.insert(next).inserted else {throw DesktopBridgeError.malformedResponse}}
            else {guard cursor == .null,rows.count == count else {throw DesktopBridgeError.malformedResponse}}
        }while cursor != .null
        let final=try await fetch("getMobileLinkedDatabaseRead",firstArgs!)
        guard final == firstPage else {throw APIError(status:409,code:"database_view_changed",message:"La vista cambió mientras se cargaba. Vuelve a intentarlo.")}
        return .init(definition:definition,rows:rows,revision:revision!)
    }
    @MainActor static func download(client:DesktopBridgeClient,vault:String,views:[JSONValue],maximumBytes:Int,existing:Set<String>,ownerDatabase:String,database:(String,Int) async throws -> JSONValue) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        var output:[PrivateBridgeCache.ReadPackRecord]=[],seen=existing,bytes=0,databases:[String:JSONValue]=[:]
        for view in views {
            guard let id=view.objectValue?["id"]?.stringValue,!id.isEmpty else {throw DesktopBridgeError.malformedResponse}
            let source = try await load(vault:vault,viewId:id){method,args in
                let value=try await client.operation(vaultId:vault,method:method,args:args)
                let key=try CompanionDocumentOutbox.operationKey(method,args)
                if seen.insert(key).inserted {
                    let data=try JSONEncoder.nodus.encode(value)
                    guard data.count <= maximumBytes - bytes else {throw PrivateBridgeCache.ReadPackError.tooLarge}
                    bytes += data.count;output.append(.init(domain:.corpus,recordId:key,data:data))
                }
                return value
            }
            for item in source.definition.objectValue!["sources"]!.arrayValue! {
                guard let id=item.objectValue?["databaseId"]?.stringValue else {throw DesktopBridgeError.malformedResponse}
                if id != ownerDatabase,databases[id] == nil {
                    let payload=try await database(id,maximumBytes - bytes)
                    guard payload.objectValue?["database"]?.objectValue?["id"] == .string(id) else {throw DesktopBridgeError.malformedResponse}
                    let count=try JSONEncoder.nodus.encode(payload).count
                    guard count <= maximumBytes - bytes else {throw PrivateBridgeCache.ReadPackError.tooLarge}
                    bytes += count;databases[id]=payload
                    if seen.insert(CompanionDatabasePresentationSource.key(id)).inserted {
                        let presentation = try await CompanionDatabasePresentationSource.download(client: client, vault: vault, database: id, maximumBytes: maximumBytes - bytes)
                        bytes += presentation.data.count; output.append(presentation)
                    }
                }
            }
        }
        if !databases.isEmpty {
            let data=try JSONEncoder.nodus.encode(JSONValue.object(["version":.int(1),"vaultId":.string(vault),"databases":.object(databases)]))
            let reserved=try databases.values.reduce(0){$0 + (try JSONEncoder.nodus.encode($1).count)}
            guard data.count - reserved <= maximumBytes - bytes else {throw PrivateBridgeCache.ReadPackError.tooLarge}
            output.append(.init(domain:.corpus,recordId:CompanionPageDownload.linkedDatabaseKey,data:data))
        }
        return output
    }
}
