import CryptoKit
import Foundation
import GRDB

public struct AccountLibraryCreator: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(creatorType):\(name ?? ""):\(firstName ?? ""):\(lastName ?? "")" }
    public var creatorType: String
    public var firstName: String?
    public var lastName: String?
    public var name: String?

    public init(creatorType: String = "author", firstName: String? = nil, lastName: String? = nil, name: String? = nil) {
        self.creatorType = creatorType
        self.firstName = firstName
        self.lastName = lastName
        self.name = name
    }

    public var label: String {
        if let name, !name.isEmpty { return name }
        return [firstName, lastName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

public struct AccountLibraryMetadata: Sendable, Hashable, Codable {
    public var title: String
    public var itemType: String
    public var creators: [AccountLibraryCreator]
    public var abstract: String?
    public var date: String?
    public var year: Int?
    public var language: String?
    public var publisher: String?
    public var publicationTitle: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var edition: String?
    public var place: String?
    public var rights: String?
    public var url: String?
    public var doi: String?
    public var pmid: String?
    public var pmcid: String?
    public var arxiv: String?
    public var isbn: [String]
    public var issn: [String]
    public var tags: [String]

    public init(
        title: String,
        itemType: String = "document",
        creators: [AccountLibraryCreator] = [],
        abstract: String? = nil,
        date: String? = nil,
        year: Int? = nil,
        language: String? = nil,
        publisher: String? = nil,
        publicationTitle: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        edition: String? = nil,
        place: String? = nil,
        rights: String? = nil,
        url: String? = nil,
        doi: String? = nil,
        pmid: String? = nil,
        pmcid: String? = nil,
        arxiv: String? = nil,
        isbn: [String] = [],
        issn: [String] = [],
        tags: [String] = []
    ) {
        self.title = title
        self.itemType = itemType
        self.creators = creators
        self.abstract = abstract
        self.date = date
        self.year = year
        self.language = language
        self.publisher = publisher
        self.publicationTitle = publicationTitle
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.edition = edition
        self.place = place
        self.rights = rights
        self.url = url
        self.doi = doi
        self.pmid = pmid
        self.pmcid = pmcid
        self.arxiv = arxiv
        self.isbn = isbn
        self.issn = issn
        self.tags = tags
    }
}

public struct AccountLibraryAttachment: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var title: String
    public var fileName: String
    public var relativePath: String
    public var mimeType: String
    public var byteSize: Int
    public var sha256: String
    public var role: String
    public var position: Int

    public init(
        id: String = UUID().uuidString,
        title: String,
        fileName: String,
        relativePath: String? = nil,
        mimeType: String,
        byteSize: Int,
        sha256: String,
        role: String = "original",
        position: Int = 0
    ) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.relativePath = relativePath ?? "attachments/\(fileName)"
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.sha256 = sha256
        self.role = role
        self.position = position
    }
}

public struct AccountLibrarySourceIdentity: Sendable, Hashable, Codable {
    public var source: String
    public var libraryType: String
    public var libraryId: String
    public var itemKey: String
}

public struct AccountLibraryNote: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var title: String
    public var markdown: String
    public let source: String
    public let readOnly: Bool
    public let createdAt: String
    public var updatedAt: String

    public init(id: String = UUID().uuidString, title: String, markdown: String, now: Date = Date()) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.source = "nodus"
        self.readOnly = false
        self.createdAt = ISO8601DateFormatter.nodusFractional.string(from: now)
        self.updatedAt = self.createdAt
    }
}

public struct AccountLibraryRelation: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public var targetItemId: String
    public var relationType: String
    public let createdAt: String

    public init(id: String = UUID().uuidString, targetItemId: String, relationType: String = "related", now: Date = Date()) {
        self.id = id
        self.targetItemId = targetItemId
        self.relationType = relationType
        self.createdAt = ISO8601DateFormatter.nodusFractional.string(from: now)
    }
}

public struct AccountLibraryClock: Sendable, Hashable, Codable {
    public var deviceId: String
    public var revision: Int
    public var baseRevision: Int
    public var updatedAt: String
    public var contentHash: String
}

public struct AccountLibraryItem: Sendable, Hashable, Codable, Identifiable {
    public var format = "nodus.library-item"
    public var formatVersion = 2
    public let id: String
    public let storageId: String
    public var aliases: [String]
    public var sourceIdentities: [AccountLibrarySourceIdentity]
    public var source: String
    public var citationKey: String?
    public var metadata: AccountLibraryMetadata
    public var localTags: [String]?
    public var collectionIds: [String]
    public var attachments: [AccountLibraryAttachment]
    public var notes: [AccountLibraryNote]?
    public var relations: [AccountLibraryRelation]?
    public let createdAt: String
    public var deletedAt: String?
    public var clock: AccountLibraryClock

    public init(
        id: String = "nodus:item:\(UUID().uuidString)",
        metadata: AccountLibraryMetadata,
        collectionIds: [String] = [],
        deviceId: String,
        now: Date = Date()
    ) {
        let timestamp = ISO8601DateFormatter.nodusFractional.string(from: now)
        self.id = id
        self.storageId = UUID().uuidString
        self.aliases = []
        self.sourceIdentities = []
        self.source = "nodus"
        self.metadata = metadata
        self.localTags = []
        self.collectionIds = collectionIds
        self.attachments = []
        self.notes = []
        self.relations = []
        self.createdAt = timestamp
        self.clock = AccountLibraryClock(deviceId: deviceId, revision: 1, baseRevision: 0, updatedAt: timestamp, contentHash: "")
    }

    public var searchableText: String {
        ([metadata.title, metadata.abstract ?? "", citationKey ?? ""]
         + metadata.creators.map(\.label) + metadata.tags + (localTags ?? []))
            .joined(separator: "\n").localizedLowercase
    }
}

public struct AccountLibraryCollection: Sendable, Hashable, Codable, Identifiable {
    public var format = "nodus.library-collection"
    public var formatVersion = 2
    public let id: String
    public var aliases: [String]
    public var name: String
    public var icon: String?
    public var color: String?
    public var parentId: String?
    public var position: Int
    public var source: String
    public let createdAt: String
    public var deletedAt: String?
    public var clock: AccountLibraryClock

    public init(
        id: String = "nodus:collection:\(UUID().uuidString)",
        name: String,
        parentId: String? = nil,
        position: Int = 0,
        deviceId: String,
        now: Date = Date()
    ) {
        let timestamp = ISO8601DateFormatter.nodusFractional.string(from: now)
        self.id = id
        self.aliases = []
        self.name = name
        self.parentId = parentId
        self.position = position
        self.source = "nodus"
        self.createdAt = timestamp
        self.clock = AccountLibraryClock(deviceId: deviceId, revision: 1, baseRevision: 0, updatedAt: timestamp, contentHash: "")
    }
}

public struct AccountLibrarySavedSearch: Sendable, Hashable, Codable, Identifiable {
    public var format = "nodus.library-saved-search"
    public var formatVersion = 1
    public let id: String
    public var name: String
    /// Desktop stores a recursive smart-search tree. Keeping the open JSON representation here
    /// preserves every current and future rule while the mobile editor progressively exposes them.
    public var query: JSONValue
    public var createdAt: String
    public var updatedAt: String

    public init(id: String = "saved-search:\(UUID().uuidString)", name: String, query: JSONValue, now: Date = Date()) {
        self.id = id
        self.name = name
        self.query = query
        self.createdAt = ISO8601DateFormatter.nodusFractional.string(from: now)
        self.updatedAt = self.createdAt
    }
}

public struct AccountLibrarySortRule: Sendable, Hashable, Codable {
    public var field: String
    public var direction: String

    public init(field: String, direction: String) {
        self.field = field
        self.direction = direction
    }
}

public struct AccountLibraryViewPreferences: Sendable, Hashable, Codable, Identifiable {
    public var format = "nodus.library-view-preferences"
    public var formatVersion = 1
    public let id: String
    public var visibleColumns: [String]
    public var columnWidths: [String: Double]
    public var sort: [AccountLibrarySortRule]
    public var updatedAt: String

    public init(
        id: String = "nodus:library-view-preferences:default",
        visibleColumns: [String] = ["title", "creator", "year", "source", "status"],
        columnWidths: [String: Double] = [:],
        sort: [AccountLibrarySortRule] = [.init(field: "updatedAt", direction: "desc"), .init(field: "title", direction: "asc")],
        now: Date = Date()
    ) {
        self.id = id
        self.visibleColumns = visibleColumns
        self.columnWidths = columnWidths
        self.sort = sort
        self.updatedAt = ISO8601DateFormatter.nodusFractional.string(from: now)
    }
}

/// Account-global, encrypted-at-rest materialization of the immutable Library ledger.
///
/// This is deliberately not keyed by a space. A user opening a collaborator's vault therefore
/// sees their own account catalogue, while the collaborator never gains a path to it.
public actor AccountLibraryCatalog {
    public struct Conflict: Sendable, Hashable, Identifiable {
        public var id: String { "\(recordId):\(versionId)" }
        public let recordId: String
        public let versionId: String
        public let winnerVersionId: String?
        public let createdAt: Date?
    }

    private let dbQueue: DatabaseQueue
    private let objectDirectory: URL
    public let accountId: String

    public init(accountId: String, directory: URL) throws {
        self.accountId = accountId
        let key = Self.safeAccountKey(accountId)
        let folder = directory.appendingPathComponent("account-\(key)", isDirectory: true)
        objectDirectory = folder.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objectDirectory, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library-catalog.sqlite")
        dbQueue = try DatabaseQueue(path: url.path)
#if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: url.path)
#endif
        BackupPolicy.apply(.backedUp, to: url)
        try migrate()
    }

    public static func open(accountId: String, directory: URL) async throws -> AccountLibraryCatalog {
        try await Task.detached(priority: .userInitiated) { try AccountLibraryCatalog(accountId: accountId, directory: directory) }.value
    }

    private nonisolated func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS account_library_records (
                    record_id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    winner_version_id TEXT NOT NULL,
                    winner_hlc TEXT NOT NULL,
                    payload BLOB,
                    deleted INTEGER NOT NULL,
                    conflicted INTEGER NOT NULL DEFAULT 0,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS account_library_versions (
                    version_id TEXT PRIMARY KEY,
                    record_id TEXT NOT NULL,
                    base_version_id TEXT,
                    hlc TEXT NOT NULL,
                    version BLOB NOT NULL,
                    is_winner INTEGER NOT NULL,
                    conflicted INTEGER NOT NULL,
                    created_at TEXT,
                    FOREIGN KEY(record_id) REFERENCES account_library_records(record_id)
                );
                CREATE INDEX IF NOT EXISTS account_library_versions_record
                    ON account_library_versions(record_id, hlc DESC);
                CREATE TABLE IF NOT EXISTS account_library_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS account_library_objects (
                    hash TEXT PRIMARY KEY,
                    mime TEXT NOT NULL,
                    bytes INTEGER NOT NULL,
                    local_path TEXT NOT NULL,
                    state TEXT NOT NULL,
                    last_error TEXT
                );
                """)
        }
    }

    public func cursor() throws -> Int {
        try dbQueue.read { db in Int(try String.fetchOne(db, sql: "SELECT value FROM account_library_metadata WHERE key='cursor'") ?? "0") ?? 0 }
    }

    public func apply(_ page: LibraryChangePage) throws {
        try dbQueue.write { db in
            for version in page.changes { try Self.apply(version, db: db, forceWinner: version.winner == true) }
            try db.execute(sql: "INSERT INTO account_library_metadata(key,value) VALUES('cursor',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [String(page.cursor)])
        }
    }

    public func items(includeDeleted: Bool = false) throws -> [AccountLibraryItem] {
        try records(kind: "item", includeDeleted: includeDeleted).map { try JSONDecoder.nodus.decode(AccountLibraryItem.self, from: $0) }
    }

    public func collections(includeDeleted: Bool = false) throws -> [AccountLibraryCollection] {
        try records(kind: "collection", includeDeleted: includeDeleted)
            .map { try JSONDecoder.nodus.decode(AccountLibraryCollection.self, from: $0) }
            .sorted { $0.position == $1.position ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.position < $1.position }
    }

    public func savedSearches() throws -> [AccountLibrarySavedSearch] {
        try records(kind: "saved-search", includeDeleted: false).map { try JSONDecoder.nodus.decode(AccountLibrarySavedSearch.self, from: $0) }
    }

    public func viewPreferences() throws -> AccountLibraryViewPreferences? {
        try records(kind: "preferences", includeDeleted: false).first.map { try JSONDecoder.nodus.decode(AccountLibraryViewPreferences.self, from: $0) }
    }

    public func upsertItem(_ item: AccountLibraryItem, deviceId: String) throws -> LibraryRecordVersion {
        var item = item
        let previous = try current(recordId: item.id)
        let revision = (previous?.revision ?? item.clock.revision - 1) + 1
        item.clock = try nextClock(existing: item.clock, revision: revision, deviceId: deviceId, value: item)
        return try save(recordId: item.id, payload: item, deleted: item.deletedAt != nil, baseVersionId: previous?.versionId, deviceId: deviceId)
    }

    public func upsertCollection(_ collection: AccountLibraryCollection, deviceId: String) throws -> LibraryRecordVersion {
        var collection = collection
        let previous = try current(recordId: collection.id)
        collection.clock = try nextClock(existing: collection.clock, revision: (previous?.revision ?? 0) + 1, deviceId: deviceId, value: collection)
        return try save(recordId: collection.id, payload: collection, deleted: collection.deletedAt != nil, baseVersionId: previous?.versionId, deviceId: deviceId)
    }

    public func upsertSavedSearch(_ search: AccountLibrarySavedSearch, deviceId: String) throws -> LibraryRecordVersion {
        try save(recordId: search.id, payload: search, deleted: false, baseVersionId: try current(recordId: search.id)?.versionId, deviceId: deviceId)
    }

    public func upsertViewPreferences(_ preferences: AccountLibraryViewPreferences, deviceId: String) throws -> LibraryRecordVersion {
        try save(recordId: preferences.id, payload: preferences, deleted: false, baseVersionId: try current(recordId: preferences.id)?.versionId, deviceId: deviceId)
    }

    public func setDeleted(recordId: String, deleted: Bool, deviceId: String) throws -> LibraryRecordVersion? {
        guard let record = try recordPayload(recordId: recordId) else { return nil }
        if let item = try? JSONDecoder.nodus.decode(AccountLibraryItem.self, from: record) {
            var copy = item
            copy.deletedAt = deleted ? ISO8601DateFormatter.nodusFractional.string(from: Date()) : nil
            return try upsertItem(copy, deviceId: deviceId)
        }
        if let collection = try? JSONDecoder.nodus.decode(AccountLibraryCollection.self, from: record) {
            var copy = collection
            copy.deletedAt = deleted ? ISO8601DateFormatter.nodusFractional.string(from: Date()) : nil
            return try upsertCollection(copy, deviceId: deviceId)
        }
        return nil
    }

    public func conflicts() throws -> [Conflict] {
        try dbQueue.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT v.record_id,v.version_id,r.winner_version_id,v.created_at
                FROM account_library_versions v JOIN account_library_records r ON r.record_id=v.record_id
                WHERE v.conflicted=1 OR r.conflicted=1 ORDER BY COALESCE(v.created_at,'') DESC
                """).map { row in
                    Conflict(
                        recordId: row["record_id"], versionId: row["version_id"], winnerVersionId: row["winner_version_id"],
                        createdAt: (row["created_at"] as String?).flatMap(ISO8601DateFormatter.nodusFractional.date(from:))
                    )
                }
        }
    }

    public func history(recordId: String) throws -> [LibraryRecordVersion] {
        try dbQueue.read { db in
            try GRDB.Row.fetchAll(db, sql: "SELECT version FROM account_library_versions WHERE record_id=? ORDER BY hlc DESC", arguments: [recordId])
                .map { try JSONDecoder.nodus.decode(LibraryRecordVersion.self, from: $0["version"] as Data) }
        }
    }

    @discardableResult
    public func stageObject(_ data: Data, mime: String) throws -> String {
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = objectDirectory.appendingPathComponent(hash, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO account_library_objects(hash,mime,bytes,local_path,state,last_error)
                VALUES(?,?,?,?, 'pending', NULL)
                ON CONFLICT(hash) DO UPDATE SET local_path=excluded.local_path,mime=excluded.mime,bytes=excluded.bytes
                """, arguments: [hash, mime, data.count, url.path])
        }
        return hash
    }

    public func objectURL(hash: String) throws -> URL? {
        try dbQueue.read { db in
            guard let path = try String.fetchOne(db, sql: "SELECT local_path FROM account_library_objects WHERE hash=?", arguments: [hash]), FileManager.default.fileExists(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    @discardableResult
    public func flushObjects(using client: NodusClient, limit: Int = 4) async throws -> Int {
        let objects: [(String, String, String)] = try await dbQueue.read { db in
            try GRDB.Row.fetchAll(db, sql: "SELECT hash,mime,local_path FROM account_library_objects WHERE state='pending' ORDER BY rowid LIMIT ?", arguments: [max(1, min(limit, 8))])
                .map { ($0["hash"], $0["mime"], $0["local_path"]) }
        }
        var uploaded = 0
        for (hash, mime, path) in objects {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                let receipt = try await client.uploadLibraryObject(data, mime: mime)
                guard receipt.hash == hash else { throw CocoaError(.fileReadCorruptFile) }
                try await dbQueue.write { db in try db.execute(sql: "UPDATE account_library_objects SET state='available',last_error=NULL WHERE hash=?", arguments: [hash]) }
                uploaded += 1
            } catch {
                try? await dbQueue.write { db in try db.execute(sql: "UPDATE account_library_objects SET last_error=? WHERE hash=?", arguments: [error.localizedDescription, hash]) }
                throw error
            }
        }
        return uploaded
    }

    public func fetchObject(hash: String, mime: String, using client: NodusClient) async throws -> URL {
        if let local = try objectURL(hash: hash) { return local }
        let data = try await client.libraryObject(hash: hash)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw CocoaError(.fileReadCorruptFile) }
        _ = try stageObject(data, mime: mime)
        try await dbQueue.write { db in try db.execute(sql: "UPDATE account_library_objects SET state='available' WHERE hash=?", arguments: [hash]) }
        return objectDirectory.appendingPathComponent(hash)
    }

    private func records(kind: String, includeDeleted: Bool) throws -> [Data] {
        try dbQueue.read { db in
            let suffix = includeDeleted ? "" : " AND deleted=0"
            return try Data.fetchAll(db, sql: "SELECT payload FROM account_library_records WHERE kind=?\(suffix) AND payload IS NOT NULL ORDER BY updated_at DESC", arguments: [kind])
        }
    }

    private func recordPayload(recordId: String) throws -> Data? {
        try dbQueue.read { db in try Data.fetchOne(db, sql: "SELECT payload FROM account_library_records WHERE record_id=?", arguments: [recordId]) }
    }

    private struct Current { let versionId: String; let revision: Int }
    private func current(recordId: String) throws -> Current? {
        try dbQueue.read { db in
            guard let row = try GRDB.Row.fetchOne(db, sql: "SELECT winner_version_id,payload FROM account_library_records WHERE record_id=?", arguments: [recordId]) else { return nil }
            let payload: Data? = row["payload"]
            let revision = payload.flatMap { try? JSONDecoder.nodus.decode(AccountLibraryItem.self, from: $0).clock.revision }
                ?? payload.flatMap { try? JSONDecoder.nodus.decode(AccountLibraryCollection.self, from: $0).clock.revision }
                ?? 0
            return Current(versionId: row["winner_version_id"], revision: revision)
        }
    }

    private func nextClock<T: Encodable>(existing: AccountLibraryClock, revision: Int, deviceId: String, value: T) throws -> AccountLibraryClock {
        var copy = existing
        copy.deviceId = deviceId
        copy.baseRevision = existing.revision
        copy.revision = revision
        copy.updatedAt = ISO8601DateFormatter.nodusFractional.string(from: Date())
        copy.contentHash = SHA256.hash(data: try JSONEncoder.nodus.encode(value)).map { String(format: "%02x", $0) }.joined()
        return copy
    }

    private func save<T: Encodable>(recordId: String, payload: T, deleted: Bool, baseVersionId: String?, deviceId: String) throws -> LibraryRecordVersion {
        let object = try JSONDecoder.nodus.decode([String: JSONValue].self, from: JSONEncoder.nodus.encode(payload))
        let version = LibraryRecordVersion(recordId: recordId, baseVersionId: baseVersionId, hlc: try nextHLC(deviceId: deviceId), deviceId: deviceId, payload: object, deleted: deleted)
        try dbQueue.write { db in try Self.apply(version, db: db, forceWinner: true) }
        return version
    }

    private func nextHLC(deviceId: String) throws -> String {
        try dbQueue.write { db in
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let previousMs = Int64(try String.fetchOne(db, sql: "SELECT value FROM account_library_metadata WHERE key='hlc_ms'") ?? "0") ?? 0
            let previousCounter = Int(try String.fetchOne(db, sql: "SELECT value FROM account_library_metadata WHERE key='hlc_counter'") ?? "0") ?? 0
            let millis = max(now, previousMs)
            let counter = millis == previousMs ? previousCounter + 1 : 0
            for (key, value) in [("hlc_ms", String(millis)), ("hlc_counter", String(counter))] {
                try db.execute(sql: "INSERT INTO account_library_metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [key, value])
            }
            let safeDevice = deviceId.replacingOccurrences(of: "[^A-Za-z0-9._:~-]", with: "-", options: .regularExpression)
            return String(format: "%013lld-%06d-%@", millis, counter, String(safeDevice.prefix(128)))
        }
    }

    private nonisolated static func apply(_ version: LibraryRecordVersion, db: Database, forceWinner: Bool) throws {
        let encodedVersion = try JSONEncoder.nodus.encode(version)
        let payloadData = try version.payload.map { try JSONEncoder.nodus.encode($0) }
        let format = version.payload?["format"]?.stringValue ?? "unknown"
        let kind: String
        switch format {
        case "nodus.library-item": kind = "item"
        case "nodus.library-collection": kind = "collection"
        case "nodus.library-saved-search": kind = "saved-search"
        case "nodus.library-view-preferences": kind = "preferences"
        default: kind = "unknown"
        }
        let existing = try GRDB.Row.fetchOne(db, sql: "SELECT winner_version_id,winner_hlc FROM account_library_records WHERE record_id=?", arguments: [version.recordId])
        // A cloud page explicitly marks its materialized winner. A historical loser may be the
        // first version in an initial page, but must never flash as the current record while the
        // real winner is still in a later page. Local saves always pass `forceWinner`.
        let wins = forceWinner
        let conflict = version.conflicted == true || (existing != nil && version.baseVersionId != (existing?["winner_version_id"] as String?))
        if wins {
            try db.execute(sql: """
                INSERT INTO account_library_records(record_id,kind,winner_version_id,winner_hlc,payload,deleted,conflicted,updated_at)
                VALUES(?,?,?,?,?,?,?,?)
                ON CONFLICT(record_id) DO UPDATE SET kind=excluded.kind,winner_version_id=excluded.winner_version_id,
                    winner_hlc=excluded.winner_hlc,payload=excluded.payload,deleted=excluded.deleted,
                    conflicted=MAX(account_library_records.conflicted,excluded.conflicted),updated_at=excluded.updated_at
                """, arguments: [version.recordId, kind, version.versionId, version.hlc, payloadData, version.deleted ? 1 : 0, conflict ? 1 : 0,
                                   version.createdAt.map(ISO8601DateFormatter.nodusFractional.string(from:)) ?? ISO8601DateFormatter.nodusFractional.string(from: Date())])
        }
        try db.execute(sql: """
            INSERT OR IGNORE INTO account_library_versions(version_id,record_id,base_version_id,hlc,version,is_winner,conflicted,created_at)
            VALUES(?,?,?,?,?,?,?,?)
            """, arguments: [version.versionId, version.recordId, version.baseVersionId, version.hlc, encodedVersion, wins ? 1 : 0, conflict ? 1 : 0,
                              version.createdAt.map(ISO8601DateFormatter.nodusFractional.string(from:))])
        if wins { try db.execute(sql: "UPDATE account_library_versions SET is_winner=(version_id=?) WHERE record_id=?", arguments: [version.versionId, version.recordId]) }
    }

    private nonisolated static func safeAccountKey(_ accountId: String) -> String {
        Data(accountId.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }
}
