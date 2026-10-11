import Foundation

/// One change on its way back to the owner's desktop.
///
/// A Cloud/Server relay stores the change in its ledger:
/// it stores the change, the owner's machine applies it to the canonical SQLite, and the
/// republication that follows is what everybody — including the author of the change — finally
/// reads. A live Desktop Bridge instead applies the change to the vault and returns an
/// explicit `applied` receipt. Acceptance alone never proves application.
public struct Mutation: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable {
        case upsert
        case delete
    }

    public let id: String
    public let clientId: String
    public let kind: Kind
    public let table: String
    /// The primary-key values, in the table's own key order.
    public let key: [String]
    /// The whole row for an upsert; must be absent for a delete.
    public let row: [String: JSONValue]?
    /// SHA-256 hashes of images this row refers to. The server rejects the batch with 409
    /// `missing_assets` until they have been uploaded.
    public let assets: [AssetReference]
    public let schemaVersion: Int
    public let createdAt: Date
    /// Local authoring provenance; the Mac independently confirms actual creation.
    public let companionCreation: Bool?

    public init(
        id: String = UUID().uuidString,
        clientId: String,
        kind: Kind,
        table: MutableTable,
        key: [String],
        row: [String: JSONValue]? = nil,
        assets: [AssetReference] = [],
        schemaVersion: Int,
        createdAt: Date = Date(),
        companionCreation: Bool = false
    ) {
        self.id = id
        self.clientId = clientId
        self.kind = kind
        self.table = table.rawValue
        self.key = key
        self.row = row
        self.assets = assets
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.companionCreation = companionCreation ? true : nil
    }

    public struct AssetReference: Sendable, Hashable, Codable {
        public let hash: String
        public init(hash: String) { self.hash = hash }
    }
}

public struct MutationReceipt: Sendable, Decodable {
    public struct Rejection: Sendable, Decodable {
        public let id: String
        /// `table_not_mutable`, `unknown_column:<col>`, `constraint`, `missing_asset`, …
        public let reason: String
        /// A sentence the server wrote, when it had numbers worth stating. Nil from any
        /// server that only sends the code, which is every server before 3.2.1.
        public let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case id
            case reason
            case errorDescription = "error_description"
        }
    }

    public let accepted: [String]
    /// Already in the ledger. Re-sending is safe and expected — this is how the client
    /// retries without needing to know whether the first attempt landed.
    public let duplicate: [String]
    public let rejected: [Rejection]
    public let cursor: Int?
    /// Canonical vault writes confirmed by Desktop Bridge. Absent from older bridges and
    /// relays; never inferred from `accepted`, `duplicate`, or a successful HTTP status.
    public let applied: [String]?

    /// A receipt may change only the submitted batch, and each ID has exactly one outcome.
    /// Validate before any local queue state changes, including legacy receipts.
    public func validate(submittedIDs: [String]) throws {
        let submitted = Set(submittedIDs)
        let outcomes = accepted + duplicate + rejected.map(\.id)
        let confirmed = applied ?? []
        guard submitted.count == submittedIDs.count,
              Set(outcomes).count == outcomes.count, Set(outcomes) == submitted,
              Set(confirmed).count == confirmed.count,
              Set(confirmed).isSubset(of: Set(accepted + duplicate)),
              cursor == nil || cursor! >= 0 else {
            throw TransportError.malformedResponse(expected: "a mutation receipt scoped to the submitted batch")
        }
    }
}

/// What the space at the other end will take in one change and in one request.
///
/// A queue of Deep Research reports is megabytes, because a report is a single row carrying its
/// whole markdown. Counting rows says nothing about the size of the request they make, and
/// counting rows is all this app used to do.
public struct MutationLimits: Sendable, Hashable {
    public let maxBatch: Int
    /// Nil when the server does not publish it. Never guess a value here: refusing a change
    /// locally against an invented ceiling throws away work the server would have taken.
    public let maxRowBytes: Int?
    public let maxBatchBytes: Int

    /// What to assume of a server that will not say.
    ///
    /// Servers before 3.2.1 accepted a 2 MiB body and published nothing about it, so this stays
    /// under that. Guessing low costs an extra request. Guessing high cost a 413 that marked
    /// nothing and re-sent the same batch forever.
    public static let unstated = MutationLimits(maxBatch: 200, maxRowBytes: nil, maxBatchBytes: 1_500_000)

    public init(maxBatch: Int, maxRowBytes: Int?, maxBatchBytes: Int) {
        self.maxBatch = max(1, maxBatch)
        self.maxRowBytes = maxRowBytes
        self.maxBatchBytes = max(1, maxBatchBytes)
    }

    public init(_ capabilities: ServerCapabilities) {
        self.init(
            maxBatch: capabilities.maxMutationBatch,
            maxRowBytes: capabilities.maxMutationBytes,
            maxBatchBytes: capabilities.maxMutationBatchBytes ?? MutationLimits.unstated.maxBatchBytes
        )
    }
}

public extension Mutation {
    /// The bytes this change occupies on the wire, measured the way the server measures it.
    var encodedSize: Int { (try? JSONEncoder.nodus.encode(self))?.count ?? 0 }

    /// What this row says it is, in the vocabulary the desktop's own inbox records.
    ///
    /// Two columns say it, because two tables spell it differently: `decorative_images` carries
    /// an `entity_kind` outright, and a saved writing draft declares itself inside `brief_json`
    /// — `kind: "deep_research"` is the exact value the corpus route filters a Deep Research
    /// report on, and the exact value `ReportDraft` writes.
    ///
    /// Nil for a note, a folder, a delete, or anything else that never claimed to be a kind of
    /// thing. Nil is the common case and means only "this row did not say".
    var entityKind: String? {
        guard let row else { return nil }
        if let declared = row["entity_kind"]?.stringValue { return declared }
        // Only `brief_json` is parsed, never the whole row: the draft beside it holds the entire
        // markdown of a report, and this is read while queueing one.
        guard
            let brief = row["brief_json"]?.stringValue,
            let data = brief.data(using: .utf8),
            let object = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else { return nil }
        return object["kind"]?.stringValue
    }
}

public extension NodusClient {
    /// Bridge applies at most 100 edits per atomic request. Relay defaults predate it.
    var maximumMutationBatch: Int { hasDesktopBridge ? 100 : MutationLimits.unstated.maxBatch }

    /// `POST /api/v1/spaces/:id/mutations` — needs `write`.
    ///
    /// At most `capabilities.maxMutationBatch` per request (200 by default). Idempotent by
    /// mutation id, so a retry after a timeout costs nothing.
    func send(mutations: [Mutation], in spaceId: String) async throws -> MutationReceipt {
        let body = try JSONEncoder.nodus.encode(["mutations": mutations])
        let response = try await perform(.init(
            method: "POST",
            path: address.spacePath(spaceId, "/mutations"),
            body: body,
            contentType: "application/json"
        ))
        let receipt = try decode(MutationReceipt.self, from: response)
        try receipt.validate(submittedIDs: mutations.map(\.id))
        return receipt
    }

    /// `GET /api/v1/spaces/:id/mutations?since=&limit=` — needs `own`.
    ///
    /// The owner's side of the relay. A writer must not be able to drain the queue that feeds
    /// the desktop, which is why this is `own` and the POST above is `write`.
    func pendingMutations(in spaceId: String, since cursor: Int = 0, limit: Int? = nil) async throws -> MutationLedgerPage {
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/mutations"),
            query: [
                URLQueryItem(name: "since", value: String(max(0, cursor))),
                URLQueryItem(name: "limit", value: String(PageBounds.clampedLimit(limit))),
            ]
        ))
        return try decode(MutationLedgerPage.self, from: response)
    }

    /// `POST /api/v1/spaces/:id/mutations/ack` — needs `own`.
    @discardableResult
    func acknowledgeMutations(upTo cursor: Int, in spaceId: String) async throws -> MutationAck {
        let body = try JSONEncoder.nodus.encode(["cursor": cursor])
        let response = try await perform(.init(
            method: "POST",
            path: address.spacePath(spaceId, "/mutations/ack"),
            body: body,
            contentType: "application/json"
        ))
        return try decode(MutationAck.self, from: response)
    }
}

public struct MutationLedgerPage: Sendable, Decodable {
    public let mutations: [Row]
    public let cursor: Int
    public let hasMore: Bool
    public let spaceSchemaVersion: Int?
}

public struct MutationAck: Sendable, Decodable {
    public let ok: Bool
    public let cursor: Int
    public let pending: Int
}
