import Foundation

public struct LibraryRecordVersion: Sendable, Hashable, Codable, Identifiable {
    public var id: String { versionId }
    public let sequence: Int?
    public let recordId: String
    public let versionId: String
    public let baseVersionId: String?
    public let hlc: String
    public let deviceId: String?
    public let payload: [String: JSONValue]?
    public let deleted: Bool
    public let createdAt: Date?
    public let winner: Bool?
    public let conflicted: Bool?

    public init(
        recordId: String,
        versionId: String = UUID().uuidString,
        baseVersionId: String? = nil,
        hlc: String,
        deviceId: String? = nil,
        payload: [String: JSONValue]?,
        deleted: Bool = false
    ) {
        self.sequence = nil
        self.recordId = recordId
        self.versionId = versionId
        self.baseVersionId = baseVersionId
        self.hlc = hlc
        self.deviceId = deviceId
        self.payload = payload
        self.deleted = deleted
        self.createdAt = nil
        self.winner = nil
        self.conflicted = nil
    }
}

public struct LibraryChangePage: Sendable, Hashable, Decodable {
    public let changes: [LibraryRecordVersion]
    public let cursor: Int
    public let hasMore: Bool
}

public struct LibraryBatchReceipt: Sendable, Hashable, Decodable {
    public struct Conflict: Sendable, Hashable, Decodable {
        public let recordId: String
        public let versionId: String
        public let currentWinnerVersionId: String
    }
    public let accepted: [String]
    public let duplicate: [String]
    public let conflicts: [Conflict]
    public let cursor: Int
}

public enum LibraryCommandKind: String, Sendable, Hashable, Codable, CaseIterable {
    case `import`, extract, zoteroSync, merge, export
}

public struct LibraryCommand: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let sequence: Int
    public let idempotencyKey: String
    public let kind: LibraryCommandKind
    public let schemaVersion: Int
    public let payload: [String: JSONValue]
    public let status: RemoteWorkStatus
    public let claimedByDevice: String?
    public let result: JSONValue?
    public let errorCode: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let claimedAt: Date?
    public let finishedAt: Date?
}

public struct LibraryCommandPage: Sendable, Hashable, Decodable {
    public let commands: [LibraryCommand]
    public let cursor: Int
    public let hasMore: Bool
}

public struct LibraryCommandCreation: Sendable, Hashable, Decodable {
    public let command: LibraryCommand
    public let duplicate: Bool
}

public struct LibraryObjectReceipt: Sendable, Hashable, Decodable {
    public let hash: String
    public let bytes: Int
    public let duplicate: Bool
}

private struct LibraryRecordBatch: Encodable { let records: [LibraryRecordVersion] }
private struct LibraryCommandBody: Encodable {
    let id: String
    let idempotencyKey: String
    let kind: LibraryCommandKind
    let schemaVersion: Int
    let payload: [String: JSONValue]
}
private struct LibraryCommandEnvelope: Decodable { let command: LibraryCommand }

public extension NodusClient {
    func libraryChanges(since cursor: Int = 0, limit: Int = 50) async throws -> LibraryChangePage {
        let response = try await perform(.init(
            path: "/api/v1/library/changes",
            query: [
                URLQueryItem(name: "cursor", value: String(max(0, cursor))),
                URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
            ]
        ))
        return try decode(LibraryChangePage.self, from: response)
    }

    func sendLibraryVersions(_ versions: [LibraryRecordVersion]) async throws -> LibraryBatchReceipt {
        let response = try await perform(.init(
            method: "POST",
            path: "/api/v1/library/records/batch",
            body: try JSONEncoder.nodus.encode(LibraryRecordBatch(records: versions)),
            contentType: "application/json"
        ))
        return try decode(LibraryBatchReceipt.self, from: response)
    }

    func libraryObject(hash: String) async throws -> Data {
        try await perform(.init(path: "/api/v1/library/objects/\(escape(hash))")).data
    }

    @discardableResult
    func uploadLibraryObject(_ data: Data, mime: String = "application/octet-stream") async throws -> LibraryObjectReceipt {
        let hash = Self.sha256Hex(data)
        let response = try await perform(.init(
            method: "PUT",
            path: "/api/v1/library/objects/\(hash)",
            body: data,
            contentType: mime
        ))
        return try decode(LibraryObjectReceipt.self, from: response)
    }

    func createLibraryCommand(
        id: String = UUID().uuidString,
        idempotencyKey: String,
        kind: LibraryCommandKind,
        payload: [String: JSONValue]
    ) async throws -> LibraryCommandCreation {
        let response = try await perform(.init(
            method: "POST",
            path: "/api/v1/library/commands",
            body: try JSONEncoder.nodus.encode(LibraryCommandBody(
                id: id,
                idempotencyKey: idempotencyKey,
                kind: kind,
                schemaVersion: 1,
                payload: payload
            )),
            contentType: "application/json"
        ))
        return try decode(LibraryCommandCreation.self, from: response)
    }

    func libraryCommands(since: Int = 0, limit: Int = 50) async throws -> LibraryCommandPage {
        let response = try await perform(.init(
            path: "/api/v1/library/commands",
            query: [
                URLQueryItem(name: "since", value: String(max(0, since))),
                URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
            ]
        ))
        return try decode(LibraryCommandPage.self, from: response)
    }

    func cancelLibraryCommand(id: String) async throws -> LibraryCommand {
        let response = try await perform(.init(
            method: "POST",
            path: "/api/v1/library/commands/\(escape(id))/cancel",
            body: Data("{}".utf8),
            contentType: "application/json"
        ))
        return try decode(LibraryCommandEnvelope.self, from: response).command
    }
}
