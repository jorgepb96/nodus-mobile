import Foundation

public enum SpaceActionKind: String, Sendable, Hashable, Codable, CaseIterable {
    case deepResearchGenerate = "deepResearch.generate"
    case deepResearchSaveToNotes = "deepResearch.saveToNotes"
    case ideaDelete = "idea.delete"
    case ideaSaveToNotes = "idea.saveToNotes"
    case authorSynthesisGenerate = "author.synthesis.generate"
    case authorsMatrixGenerate = "authors.matrix.generate"
    case argumentMapGenerate = "argumentMap.generate"
    case libraryImportToSpace = "library.importToSpace"
    case academicRecompute = "academic.recompute"
    case hypothesisSaveToNotes = "hypothesis.saveToNotes"
    case writingGenerate = "writing.generate"
    case projectsCreate = "projects.create"
    case projectsUpdate = "projects.update"
    case projectsSectionUpdate = "projects.section.update"
    case projectsChapterImport = "projects.chapter.import"
    case worldbuildingContinuity = "worldbuilding.continuity"
    case worldbuildingEntityDelete = "worldbuilding.entityDelete"
    case worldbuildingProseReview = "worldbuilding.proseReview"
    case pageRestoreRevision = "pages.restoreRevision"
    case databaseImportCSV = "databases.importCSV"
    case pagesAutomationRun = "pages.automationRun"
    case toolkitDesktopRun = "toolkit.desktopRun"
}

public enum RemoteWorkStatus: String, Sendable, Hashable, Codable, CaseIterable {
    case queued, claimed, running, applied, refused, failed, cancelled

    public var isTerminal: Bool {
        switch self {
        case .applied, .refused, .failed, .cancelled: true
        case .queued, .claimed, .running: false
        }
    }
}

public struct SpaceAction: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let sequence: Int
    public let spaceId: String
    public let idempotencyKey: String
    public let kind: SpaceActionKind
    public let schemaVersion: Int
    public let payload: [String: JSONValue]
    public let actorUserId: String
    public let createdByDevice: String?
    public let inputRevision: String?
    public let inputFingerprint: String?
    public let status: RemoteWorkStatus
    public let claimedByDevice: String?
    public let result: JSONValue?
    public let errorCode: String?
    public let createdAt: Date
    public let updatedAt: Date
    public let claimedAt: Date?
    public let finishedAt: Date?
}

public struct SpaceActionPage: Sendable, Hashable, Decodable {
    public let actions: [SpaceAction]
    public let cursor: Int
    public let hasMore: Bool
}

public struct SpaceActionCreation: Sendable, Hashable, Decodable {
    public let action: SpaceAction
    public let duplicate: Bool
}

private struct SpaceActionEnvelope: Decodable { let action: SpaceAction }
private struct SpaceActionCreateBody: Encodable {
    let id: String
    let idempotencyKey: String
    let kind: SpaceActionKind
    let schemaVersion: Int
    let payload: [String: JSONValue]
    let inputRevision: String?
    let inputFingerprint: String?
    let executionMode:String?
}

public extension NodusClient {
    /// Queue one explicitly named operation for the owner Desktop. No IPC or method name can
    /// be represented by this API.
    func createSpaceAction(
        id: String = UUID().uuidString,
        idempotencyKey: String,
        kind: SpaceActionKind,
        payload: [String: JSONValue],
        inputRevision: String? = nil,
        inputFingerprint: String? = nil,
        executionMode:String? = nil,
        in spaceId: String
    ) async throws -> SpaceActionCreation {
        let body = SpaceActionCreateBody(
            id: id,
            idempotencyKey: idempotencyKey,
            kind: kind,
            schemaVersion: 1,
            payload: payload,
            inputRevision: inputRevision,
            inputFingerprint: inputFingerprint,
            executionMode:hasDesktopBridge ? executionMode:nil
        )
        if let bridge = companionBridge {
            return try await bridge.client.createCompanionAction(vaultId: bridge.vaultId,
                body: JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(body)))
        }
        let response = try await perform(.init(
            method: "POST",
            path: address.spacePath(spaceId, "/actions"),
            body: try JSONEncoder.nodus.encode(body),
            contentType: "application/json"
        ))
        return try decode(SpaceActionCreation.self, from: response)
    }

    func spaceActions(in spaceId: String, since: Int = 0, limit: Int = 50) async throws -> SpaceActionPage {
        if let bridge = companionBridge {
            return try await bridge.client.companionActions(vaultId: bridge.vaultId, since: since, limit: limit)
        }
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/actions"),
            query: [
                URLQueryItem(name: "since", value: String(max(0, since))),
                URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
            ]
        ))
        return try decode(SpaceActionPage.self, from: response)
    }

    func spaceAction(id: String, in spaceId: String) async throws -> SpaceAction {
        if let bridge = companionBridge {
            return try await bridge.client.companionAction(vaultId: bridge.vaultId, id: id)
        }
        let response = try await perform(.init(path: address.spacePath(spaceId, "/actions/\(escape(id))")))
        return try decode(SpaceActionEnvelope.self, from: response).action
    }

    func cancelSpaceAction(id: String, in spaceId: String) async throws -> SpaceAction {
        if let bridge = companionBridge {
            return try await bridge.client.cancelCompanionAction(vaultId: bridge.vaultId, id: id)
        }
        let response = try await perform(.init(
            method: "POST",
            path: address.spacePath(spaceId, "/actions/\(escape(id))/cancel"),
            body: Data("{}".utf8),
            contentType: "application/json"
        ))
        return try decode(SpaceActionEnvelope.self, from: response).action
    }
}
