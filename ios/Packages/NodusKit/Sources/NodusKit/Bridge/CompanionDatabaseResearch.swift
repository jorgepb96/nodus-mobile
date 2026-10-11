import CryptoKit
import Foundation

public enum CompanionDatabaseResearch {
    public struct Source: Codable, Sendable, Equatable {
        public let version: Int, sourceRevision: String
        public let report: JSONValue
        public var id: String { report.objectValue?["id"]?.stringValue ?? "" }
        public func validate(id expected: String) throws {
            guard version == 1, id == expected, !id.isEmpty, CompanionDatabaseResearch.validHash(sourceRevision),
                  let fields = report.objectValue, fields["runId"]?.stringValue?.isEmpty == false,
                  fields["title"]?.stringValue != nil, fields["markdown"]?.stringValue != nil,
                  fields["createdAt"]?.stringValue != nil, fields["structured"]?.objectValue != nil,
                  fields["metadata"]?.objectValue != nil, fields["quality"]?.objectValue != nil,
                  fields["provenance"]?.objectValue != nil, fields["bibliography"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        }
    }
    public struct Reading: Codable, Sendable, Equatable {
        public var readAt: String?
        public var annotations: [JSONValue]
        public init(readAt:String?,annotations:[JSONValue]) { self.readAt = readAt; self.annotations = annotations }
        public func validate(reportId: String) throws {
            guard annotations.count <= 10_000, readAt == nil || CompanionDatabaseResearch.validDate(readAt!) else { throw DesktopBridgeError.malformedResponse }
            var ids = Set<String>()
            for value in annotations {
                guard let item = value.objectValue,Set(item.keys).isSubset(of:["id","reportId","scope","kind","color","startOffset","endOffset","selectedText","prefix","suffix","comment","createdAt","updatedAt"]),let id = item["id"]?.stringValue, !id.isEmpty, id.utf16.count <= 256,
                      ids.insert(id).inserted, item["reportId"] == .string(reportId), let scope = item["scope"]?.stringValue,
                      !scope.isEmpty, scope.utf16.count <= 180, let kind = item["kind"]?.stringValue,
                      ["highlight","comment","bookmark"].contains(kind), let start = item["startOffset"]?.intValue, start >= 0,
                      let end = item["endOffset"]?.intValue, end > start, let text = item["selectedText"]?.stringValue,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count == end - start, text.utf16.count <= 20_000,
                      let prefix = item["prefix"]?.stringValue, prefix.utf16.count <= 64,
                      let suffix = item["suffix"]?.stringValue, suffix.utf16.count <= 64,
                      let created = item["createdAt"]?.stringValue, CompanionDatabaseResearch.validDate(created), let updated = item["updatedAt"]?.stringValue, CompanionDatabaseResearch.validDate(updated),
                      kind == "highlight" ? ["yellow","rose","blue","mint","lavender","peach"].contains(item["color"]?.stringValue ?? "") : item["color"] == .null,
                      kind == "comment" ? !(item["comment"]?.stringValue?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true) && (item["comment"]?.stringValue?.utf16.count ?? Int.max) <= 20_000 : item["comment"] == .null,
                      kind != "bookmark" || id == "database-research-bookmark:\(reportId):\(scope)" else { throw DesktopBridgeError.malformedResponse }
            }
            guard try JSONEncoder.nodus.encode(self).count <= 2 * 1024 * 1024 - 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        }
        private enum CodingKeys: String, CodingKey { case readAt, annotations }
        public func encode(to encoder: any Encoder) throws {
            var box = encoder.container(keyedBy:CodingKeys.self)
            try box.encode(readAt,forKey:.readAt); try box.encode(annotations,forKey:.annotations)
        }
    }
    public struct Snapshot: Codable, Sendable, Equatable {
        public let version: Int, reportId: String, reportTitle: String, sourceRevision: String, readingRevision: String
        public let reading: Reading
        public func validate(id: String) throws {
            guard version == 1, reportId == id, CompanionDatabaseResearch.validHash(sourceRevision), CompanionDatabaseResearch.validHash(readingRevision) else { throw DesktopBridgeError.malformedResponse }
            try reading.validate(reportId:id)
        }
    }
    public struct Request: Codable, Sendable, Equatable {
        public let version: Int, id: String, sourceRevision: String, expectedReadingRevision: String
        public let reading: Reading
    }
    public struct Receipt: Codable, Sendable { public let id: String, snapshot: Snapshot }
    static func validHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    static func validDate(_ value: String) -> Bool { ISO8601DateFormatter().date(from:value) != nil || fractionalDate(value) != nil }
    private static func fractionalDate(_ value:String) -> Date? {
        let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return format.date(from:value)
    }
}

/// Only annotations and read state are durable. Temporary report bodies remain
/// in bounded selected packs; expiring a pack cannot remove authored changes.
public actor CompanionDatabaseReadingOutbox {
    public enum State: String, Codable, Sendable { case saved, pending, conflict, blocked }
    public struct Entry: Codable, Sendable {
        public var sourceRevision: String, baselineRevision: String
        public var reportTitle: String
        public var draft: CompanionDatabaseResearch.Reading
        public var state: State
        public var remote: CompanionDatabaseResearch.Snapshot?
        public var issue: String?
        var generation: Int = 0
        var sending: Sending?
    }
    struct Sending: Codable, Sendable { let request: CompanionDatabaseResearch.Request, generation: Int }
    static let storageKey = "companion-database-reading-v1"
    private let cache: PrivateBridgeCache, vaultId: String
    private var records: [String:Entry]
    private var synchronizing = false
    public private(set) var revision = 0
    init(cache:PrivateBridgeCache,vaultId:String,data:Data?) throws {
        self.cache = cache; self.vaultId = vaultId
        records = try data.map { try JSONDecoder.nodus.decode([String:Entry].self,from:$0) } ?? [:]
        for (id,entry) in records {
            guard CompanionDatabaseResearch.validHash(entry.sourceRevision),CompanionDatabaseResearch.validHash(entry.baselineRevision) else { throw DesktopBridgeError.malformedResponse }
            try entry.draft.validate(reportId:id)
        }
    }
    public func all() -> [String:Entry] { records }
    public func entry(id:String,sourceRevision:String? = nil) throws -> Entry? {
        guard let entry = records[id] else { return nil }
        if let sourceRevision,entry.sourceRevision != sourceRevision { throw APIError(status:409,code:"database_report_changed",message:"El informe ha cambiado. Tus anotaciones anteriores se conservan en el móvil.") }
        return entry
    }
    public func seed(_ snapshot:CompanionDatabaseResearch.Snapshot) async throws {
        try snapshot.validate(id:snapshot.reportId)
        if let entry = records[snapshot.reportId],entry.state == .saved,entry.sourceRevision == snapshot.sourceRevision,
           entry.baselineRevision == snapshot.readingRevision,entry.draft == snapshot.reading { return }
        if var entry = records[snapshot.reportId],entry.state != .saved {
            if entry.sourceRevision != snapshot.sourceRevision {
                entry.state = .blocked; entry.remote = snapshot; entry.issue = "El informe ha cambiado. Tus anotaciones anteriores se conservan en el móvil."
                try await store(id:snapshot.reportId,entry:entry)
            }
            return
        }
        try await store(id:snapshot.reportId,entry:.init(sourceRevision:snapshot.sourceRevision,baselineRevision:snapshot.readingRevision,reportTitle:snapshot.reportTitle,draft:snapshot.reading,state:.saved))
    }
    public func edit(id:String,sourceRevision:String,reading:CompanionDatabaseResearch.Reading) async throws {
        guard var entry = try entry(id:id,sourceRevision:sourceRevision) else { throw DesktopBridgeError.malformedResponse }
        try reading.validate(reportId:id)
        entry.draft = reading; entry.generation += 1
        if ![.conflict,.blocked].contains(entry.state) { entry.state = .pending; entry.issue = nil }
        try await store(id:id,entry:entry)
    }
    public func resolve(id:String,useMac:Bool) async throws {
        guard var entry = records[id],[.conflict,.blocked].contains(entry.state),let remote = entry.remote,
              useMac || remote.sourceRevision == entry.sourceRevision else { throw DesktopBridgeError.malformedResponse }
        entry.baselineRevision = remote.readingRevision; entry.sending = nil; entry.remote = nil; entry.issue = nil; entry.generation += 1
        if useMac { entry.sourceRevision = remote.sourceRevision; entry.reportTitle = remote.reportTitle; entry.draft = remote.reading; entry.state = .saved } else { entry.state = .pending }
        try await store(id:id,entry:entry)
    }
    public func review(_ snapshot:CompanionDatabaseResearch.Snapshot) async throws {
        try snapshot.validate(id:snapshot.reportId)
        guard var entry = records[snapshot.reportId],entry.state != .saved else { return }
        entry.remote = snapshot
        entry.state = entry.sourceRevision == snapshot.sourceRevision ? .conflict:.blocked
        entry.issue = entry.state == .blocked ? "El informe cambió. Revisa tus anotaciones antes de usar la versión del Mac.":nil
        try await store(id:snapshot.reportId,entry:entry)
    }
    public func synchronize(send:@Sendable (String,CompanionDatabaseResearch.Request) async throws -> CompanionDatabaseResearch.Receipt) async throws {
        guard !synchronizing else { return }; synchronizing = true; defer { synchronizing = false }
        for id in records.keys.sorted() {
            while var entry = records[id],entry.state == .pending {
                if entry.sending == nil {
                    entry.sending = .init(request:.init(version:1,id:UUID().uuidString,sourceRevision:entry.sourceRevision,expectedReadingRevision:entry.baselineRevision,reading:entry.draft),generation:entry.generation)
                    try await store(id:id,entry:entry)
                }
                let sending = entry.sending!
                do {
                    let receipt = try await send(id,sending.request); try receipt.snapshot.validate(id:id)
                    guard receipt.id == sending.request.id,receipt.snapshot.sourceRevision == entry.sourceRevision,var latest = records[id] else { throw DesktopBridgeError.malformedResponse }
                    latest.baselineRevision = receipt.snapshot.readingRevision; latest.sending = nil; latest.remote = nil; latest.issue = nil
                    if latest.generation == sending.generation { latest.draft = receipt.snapshot.reading; latest.state = .saved }
                    try await store(id:id,entry:latest)
                } catch {
                    guard var latest = records[id] else { throw error }
                    if error is CancellationError || (error as? URLError).map({ [.notConnectedToInternet,.networkConnectionLost,.timedOut,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed].contains($0.code) }) == true { throw error }
                    if let api = error as? APIError,let code = api.code,["database_reading_conflict","database_report_changed"].contains(code),let value = api.details["remote"] {
                        let remote = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Snapshot.self,from:JSONEncoder.nodus.encode(value)); try remote.validate(id:id)
                        latest.remote = remote; latest.state = remote.sourceRevision == latest.sourceRevision ? .conflict:.blocked
                    } else { latest.state = .blocked }
                    latest.issue = error.localizedDescription; try await store(id:id,entry:latest); break
                }
            }
        }
    }
    private func store(id:String,entry:Entry) async throws {
        let previous = records, generation = revision + 1
        var next = records; next[id] = entry
        let bytes = try JSONEncoder.nodus.encode(next)
        records = next; revision = generation
        do { try await cache.store(bytes,vaultId:vaultId,domain:.writing,recordId:Self.storageKey) }
        catch { if revision == generation { records = previous; revision += 1 }; throw error }
    }
}

public actor CompanionDatabaseReadingOutboxes {
    public static let shared = CompanionDatabaseReadingOutboxes()
    private var stores: [String:Task<CompanionDatabaseReadingOutbox,any Error>] = [:]
    public func outbox(pairingId:String,vaultId:String) async throws -> CompanionDatabaseReadingOutbox {
        let key = "\(pairingId)|\(vaultId)"
        if let task = stores[key] { return try await task.value }
        let task = Task {
            let cache = try PrivateBridgeCache(pairingId:pairingId)
            return try await CompanionDatabaseReadingOutbox(cache:cache,vaultId:vaultId,data:cache.data(vaultId:vaultId,domain:.writing,recordId:CompanionDatabaseReadingOutbox.storageKey))
        }
        stores[key] = task
        do { return try await task.value } catch { stores[key] = nil; throw error }
    }
    public func forget(pairingId:String) { for key in stores.keys.filter({ $0.hasPrefix("\(pairingId)|") }) { stores[key] = nil } }
}
