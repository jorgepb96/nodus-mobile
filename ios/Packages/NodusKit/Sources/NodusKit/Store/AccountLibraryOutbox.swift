import Foundation
import GRDB

/// Durable account-scoped work that has not reached the global Library ledger yet.
///
/// Space mutations have their own outbox because they are eventually applied by the owner Mac.
/// Library versions instead become immutable as soon as the account ledger accepts them. Keeping
/// the queues separate prevents a collaborator's space membership from ever implying access to
/// the owner's global Library.
public actor AccountLibraryOutbox {
    public enum State: String, Sendable, Codable {
        case pending
        case sending
        case accepted
        case conflict
        case rejected
        case cancelled
    }

    public struct QueuedCommand: Sendable, Hashable, Codable, Identifiable {
        public let id: String
        public let idempotencyKey: String
        public let kind: LibraryCommandKind
        public let payload: [String: JSONValue]

        public init(
            id: String = UUID().uuidString,
            idempotencyKey: String,
            kind: LibraryCommandKind,
            payload: [String: JSONValue]
        ) {
            self.id = id
            self.idempotencyKey = idempotencyKey
            self.kind = kind
            self.payload = payload
        }
    }

    public enum Operation: Sendable, Hashable, Codable {
        case record(LibraryRecordVersion)
        case command(QueuedCommand)

        public var id: String {
            switch self {
            case .record(let value): value.versionId
            case .command(let value): value.id
            }
        }

        fileprivate var kind: String {
            switch self {
            case .record: "record"
            case .command: "command"
            }
        }
    }

    public struct Item: Sendable, Identifiable, Hashable {
        public let id: String
        public let title: String
        public let state: State
        public let detail: String?
        public let operation: Operation
        public let createdAt: Date
        public let acceptedAt: Date?
    }

    private let dbQueue: DatabaseQueue
    public let accountId: String

    public init(accountId: String, directory: URL) throws {
        self.accountId = accountId
        let accountKey = Self.safeAccountKey(accountId)
        let folder = directory.appendingPathComponent("account-\(accountKey)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("library-outbox.sqlite")
        dbQueue = try SerializedDatabaseOpen.queue(path: url.path)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUnlessOpen],
            ofItemAtPath: url.path
        )
        // Until the server accepts an operation this database can be its only copy.
        BackupPolicy.apply(.backedUp, to: url)
        try migrate()
    }

    public static func open(accountId: String, directory: URL) async throws -> AccountLibraryOutbox {
        try await Task.detached(priority: .userInitiated) {
            try AccountLibraryOutbox(accountId: accountId, directory: directory)
        }.value
    }

    private nonisolated func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS account_library_outbox (
                    id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    state TEXT NOT NULL,
                    detail TEXT,
                    payload BLOB NOT NULL,
                    created_at TEXT NOT NULL,
                    accepted_at TEXT
                );
                CREATE INDEX IF NOT EXISTS account_library_outbox_state
                    ON account_library_outbox (state, created_at);
                """)
            // A process killed after reserving a row must not strand it forever.
            try db.execute(
                sql: "UPDATE account_library_outbox SET state = ? WHERE state = ?",
                arguments: [State.pending.rawValue, State.sending.rawValue]
            )
        }
    }

    /// Enqueues once. Repeating the same immutable version or command ID is a no-op.
    @discardableResult
    public func enqueue(_ operation: Operation, title: String) throws -> Bool {
        let payload = try JSONEncoder.nodus.encode(operation)
        return try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO account_library_outbox
                    (id, kind, title, state, detail, payload, created_at, accepted_at)
                VALUES (?, ?, ?, ?, NULL, ?, ?, NULL)
                """, arguments: [
                    operation.id,
                    operation.kind,
                    title,
                    State.pending.rawValue,
                    payload,
                    ISO8601DateFormatter.nodusFractional.string(from: Date()),
                ])
            return db.changesCount == 1
        }
    }

    public func items(includeFinished: Bool = true) throws -> [Item] {
        try dbQueue.read { db in
            let sql = includeFinished
                ? "SELECT * FROM account_library_outbox ORDER BY created_at, rowid"
                : "SELECT * FROM account_library_outbox WHERE state IN (?, ?, ?) ORDER BY created_at, rowid"
            let arguments: StatementArguments = includeFinished
                ? []
                : [State.pending.rawValue, State.sending.rawValue, State.conflict.rawValue]
            return try GRDB.Row.fetchAll(db, sql: sql, arguments: arguments).map(Self.item(from:))
        }
    }

    public func pendingCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM account_library_outbox WHERE state = ?",
                arguments: [State.pending.rawValue]
            ) ?? 0
        }
    }

    public func retry(id: String) throws {
        try setState(id: id, state: .pending, detail: nil, acceptedAt: nil)
    }

    public func cancel(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE account_library_outbox SET state = ?, detail = NULL WHERE id = ? AND state IN (?, ?)",
                arguments: [State.cancelled.rawValue, id, State.pending.rawValue, State.conflict.rawValue]
            )
        }
    }

    /// Sends a bounded batch. Stable IDs and idempotency keys make retry after a lost response safe.
    @discardableResult
    public func flush(using client: NodusClient, limit: Int = 32) async throws -> Int {
        let operations = try reserve(limit: max(1, min(limit, 100)))
        guard !operations.isEmpty else { return 0 }
        var finished = 0
        do {
            let records = operations.compactMap { item -> LibraryRecordVersion? in
                if case .record(let value) = item.operation { return value }
                return nil
            }
            if !records.isEmpty {
                let receipt = try await client.sendLibraryVersions(records)
                let accepted = Set(receipt.accepted + receipt.duplicate)
                for id in accepted {
                    try setState(id: id, state: .accepted, detail: nil, acceptedAt: Date())
                    finished += 1
                }
                for conflict in receipt.conflicts {
                    try setState(
                        id: conflict.versionId,
                        state: .conflict,
                        detail: "winner:\(conflict.currentWinnerVersionId)",
                        acceptedAt: nil
                    )
                    finished += 1
                }
            }

            for item in operations {
                guard case .command(let command) = item.operation else { continue }
                _ = try await client.createLibraryCommand(
                    id: command.id,
                    idempotencyKey: command.idempotencyKey,
                    kind: command.kind,
                    payload: command.payload
                )
                try setState(id: item.id, state: .accepted, detail: nil, acceptedAt: Date())
                finished += 1
            }
        } catch {
            // The response may have been lost after the ledger committed. Put unfinished rows back;
            // their stable IDs make the next pass an idempotent duplicate rather than a second job.
            try restoreReserved(detail: String(describing: error))
            throw error
        }
        return finished
    }

    private func reserve(limit: Int) throws -> [Item] {
        try dbQueue.write { db in
            let rows = try GRDB.Row.fetchAll(
                db,
                sql: "SELECT * FROM account_library_outbox WHERE state = ? ORDER BY created_at, rowid LIMIT ?",
                arguments: [State.pending.rawValue, limit]
            )
            let items = try rows.map(Self.item(from:))
            guard !items.isEmpty else { return [] }
            let placeholders = Array(repeating: "?", count: items.count).joined(separator: ", ")
            try db.execute(
                sql: "UPDATE account_library_outbox SET state = ?, detail = NULL WHERE id IN (\(placeholders))",
                arguments: StatementArguments([State.sending.rawValue] + items.map(\.id))
            )
            return items.map {
                Item(id: $0.id, title: $0.title, state: .sending, detail: nil,
                     operation: $0.operation, createdAt: $0.createdAt, acceptedAt: nil)
            }
        }
    }

    private func restoreReserved(detail: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE account_library_outbox SET state = ?, detail = ? WHERE state = ?",
                arguments: [State.pending.rawValue, detail, State.sending.rawValue]
            )
        }
    }

    private func setState(id: String, state: State, detail: String?, acceptedAt: Date?) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                UPDATE account_library_outbox
                SET state = ?, detail = ?, accepted_at = ?
                WHERE id = ?
                """, arguments: [
                    state.rawValue,
                    detail,
                    acceptedAt.map { ISO8601DateFormatter.nodusFractional.string(from: $0) },
                    id,
                ])
        }
    }

    private nonisolated static func item(from row: GRDB.Row) throws -> Item {
        guard
            let state = State(rawValue: row["state"]),
            let createdAt = ISO8601DateFormatter.nodusFractional.date(from: row["created_at"])
        else { throw DatabaseError(message: "Invalid account Library outbox row") }
        let payload: Data = row["payload"]
        let acceptedText: String? = row["accepted_at"]
        return Item(
            id: row["id"],
            title: row["title"],
            state: state,
            detail: row["detail"],
            operation: try JSONDecoder.nodus.decode(Operation.self, from: payload),
            createdAt: createdAt,
            acceptedAt: acceptedText.flatMap(ISO8601DateFormatter.nodusFractional.date(from:))
        )
    }

    private nonisolated static func safeAccountKey(_ accountId: String) -> String {
        // Directory names disclose neither email addresses nor bearer identities.
        Data(accountId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
