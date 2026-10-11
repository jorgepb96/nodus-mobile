import CryptoKit
import Foundation

/// Complete selected reports only. A catalogue page or a viewed response does
/// not imply that all reports are available offline.
public struct CompanionDatabaseResearchCopy: Sendable {
    public static let recordId = "companion:database-research:v1"
    public let sources: [CompanionDatabaseResearch.Source]
    public let revision: String
    public init(copies:[JSONValue]) throws {
        var sources: [CompanionDatabaseResearch.Source] = [], seen = Set<String>()
        for copy in copies {
            guard let value = copy.objectValue,value["version"] == .int(1),let entries = value["reports"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            var own = Set<String>()
            for entry in entries {
                let source = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Source.self,from:JSONEncoder.nodus.encode(entry))
                try source.validate(id:source.id)
                guard own.insert(source.id).inserted else { throw DesktopBridgeError.malformedResponse }
                if seen.insert(source.id).inserted { sources.append(source) }
            }
        }
        self.sources = sources
        revision = SHA256.hash(data:try JSONEncoder.nodus.encode(JSONValue.array(sources.map { try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode($0)) }))).map { String(format:"%02x",$0) }.joined()
    }
    public static func downloaded(cache:PrivateBridgeCache,vaultId:String) async throws -> Self? {
        let copies = try await cache.downloadedData(vaultId:vaultId,domain:.corpus,recordId:recordId)
        return copies.isEmpty ? nil : try Self(copies:copies.map { try JSONDecoder.nodus.decode(JSONValue.self,from:$0) })
    }
    public func operation(_ method:String,args:[JSONValue]) throws -> JSONValue? {
        if method == "getMobileDatabaseResearchReader",args.count == 1,let id = args[0].stringValue {
            guard let source = sources.first(where:{$0.id == id}) else { throw CompanionCollectionCopy.CopyError.dossierNotDownloaded }
            return try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(source))
        }
        guard method == "listMobileDatabaseDeepResearchReports",args.count == 1,let query = args[0].objectValue,
              Set(query.keys).isSubset(of:["limit","offset"]) else { return nil }
        let limit = query["limit"]?.intValue ?? 100,offset = query["offset"]?.intValue ?? 0
        guard (1...100).contains(limit),offset >= 0 else { throw DesktopBridgeError.malformedResponse }
        let items = sources.map { source -> JSONValue in
            let report = source.report.objectValue!
            var summary = Dictionary(uniqueKeysWithValues:["id","runId","title","createdAt","updatedAt","readAt","reportType"].map { ($0,report[$0] ?? .null) })
            summary["summary"] = .string(report["summary"]?.stringValue ?? "")
            if let cost = report["metadata"]?.objectValue?["costUsd"] ?? report["metadata"]?.objectValue?["estimatedCostUsd"] { summary["costUsd"] = cost }
            if let quality = report["quality"]?.objectValue?["status"] { summary["qualityStatus"] = quality }
            return .object(summary)
        }
        let start = min(offset,items.count),end = min(start + limit,items.count)
        return .object(["version":.int(1),"revision":.string(revision),"total":.int(Int64(items.count)),"limit":.int(Int64(limit)),"offset":.int(Int64(offset)),"hasMore":.bool(end < items.count),"items":.array(Array(items[start..<end]))])
    }
    public static func catalogue(client:DesktopBridgeClient,vaultId:String) async throws -> (items:[JSONValue],revision:String) {
        var items: [JSONValue] = [],seen = Set<String>(),revision:String?,total:Int?,bytes = 0
        while true {
            try Task.checkCancellation()
            let page = try await client.operation(vaultId:vaultId,method:"listMobileDatabaseDeepResearchReports",args:[.object(["limit":.int(100),"offset":.int(Int64(items.count))])])
            bytes += try JSONEncoder.nodus.encode(page).count
            guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            guard let value = page.objectValue,value["version"] == .int(1),let next = value["revision"]?.stringValue,CompanionDatabaseResearch.validHash(next),
                  let count = value["total"]?.intValue,count >= 0,total == nil || total == count,revision == nil || revision == next,
                  value["offset"] == .int(Int64(items.count)),let rows = value["items"]?.arrayValue,rows.count <= 100,
                  let more = value["hasMore"]?.boolValue,!more || !rows.isEmpty,items.count + rows.count <= count else { throw DesktopBridgeError.malformedResponse }
            revision = next; total = count
            for row in rows {
                guard let id = row.objectValue?["id"]?.stringValue,!id.isEmpty,seen.insert(id).inserted else { throw DesktopBridgeError.malformedResponse }
                items.append(row)
            }
            if !more { guard items.count == count else { throw DesktopBridgeError.malformedResponse }; return (items,next) }
        }
    }
}
