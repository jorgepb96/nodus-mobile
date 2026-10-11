import Foundation

public enum IdeaWorkspaceSort: String, Sendable, Hashable, Codable, CaseIterable {
    case label, type, works, connections, confidence
}

public struct IdeaWorkspaceItem: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let label: String
    public let type: String
    public let statement: String
    public let workCount: Int
    public let themes: [String]
    public let maxConfidence: Double
    public let connectionCount: Int
    public let mobileSourceScope: String?
}

public struct IdeaWorkspacePage: Sendable, Hashable, Codable {
    public let items: [IdeaWorkspaceItem]
    public let total: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let revision: String?
    public let fromDevice: Bool?

    public init(items: [IdeaWorkspaceItem], total: Int, offset: Int, limit: Int, hasMore: Bool, revision: String?, fromDevice: Bool? = nil) {
        self.items = items
        self.total = total
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
        self.revision = revision
        self.fromDevice = fromDevice
    }

    private enum CodingKeys: String, CodingKey { case items = "ideas", total, offset, limit, hasMore, revision, fromDevice }
}

public enum AuthorWorkspaceSort: String, Sendable, Hashable, Codable, CaseIterable {
    case name, surname, works, ideas, connections
}

public enum AuthorSynthesisFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case all, with, without
}

public struct AuthorWorkspaceItem: Sendable, Hashable, Codable, Identifiable {
    public var id: String { authorId }
    public let authorId: String
    public let name: String
    public let firstName: String
    public let lastName: String
    public let fullName: String
    public let affiliation: String?
    public let workCount: Int
    public let editedCount: Int
    public let ideaCount: Int
    public let relationCount: Int
    public let topTags: [String]
    public let topThemes: [String]
    public let read: Bool
    public let hasSynthesis: Bool
    public let saved: Bool

    private enum CodingKeys: String, CodingKey {
        case authorId = "author_id", name, firstName, lastName, fullName, affiliation
        case workCount, editedCount, ideaCount, relationCount, topTags, topThemes, read, hasSynthesis, saved
    }
}

public struct AuthorWorkspacePage: Sendable, Hashable, Codable {
    public let items: [AuthorWorkspaceItem]
    public let total: Int
    public let offset: Int
    public let limit: Int
    public let hasMore: Bool
    public let revision: String?

    public init(items: [AuthorWorkspaceItem], total: Int, offset: Int, limit: Int, hasMore: Bool, revision: String?) {
        self.items = items
        self.total = total
        self.offset = offset
        self.limit = limit
        self.hasMore = hasMore
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case items = "authors", total, offset, limit, hasMore, revision }
}

public struct AuthorDossierWork: Sendable, Hashable, Codable, Identifiable {
    public var id: String { nodusId }
    public let nodusId: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let itemType: String?
    public let doi: String?
    public let zoteroKey: String?
    public let sourceType: String?
    public let lightStatus: String
    public let deepStatus: String
    public let summaryStatus: String
    public let notes: String?
    public let read: Bool
    public let role: String
    public let attributed: Bool

    private enum CodingKeys: String, CodingKey {
        case nodusId = "nodus_id", title, authors, year, itemType, doi, zoteroKey, sourceType
        case lightStatus, deepStatus, summaryStatus, notes, read, role, attributed
    }
}

public struct AuthorDossierIdea: Sendable, Hashable, Codable, Identifiable {
    public var id: String { globalId }
    public let globalId: String
    public let type: String
    public let label: String
    public let statement: String
    public let development: String
    public let role: String
    public let confidence: Double
    public let workId: String
    public let workTitle: String
    public let year: Int?
    public let provisional: Bool
    public let themes: [String]
    public let evidence: [Row]

    private enum CodingKeys: String, CodingKey {
        case globalId = "global_id", type, label, statement, development, role, confidence
        case workId, workTitle, year, provisional, themes, evidence
    }
}

public struct AuthorDossierRelation: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(authorId):\(type)" }
    public let authorId: String
    public let name: String
    public let type: String
    public let weight: Double
    public let sharedThemes: [String]

    private enum CodingKeys: String, CodingKey { case authorId = "author_id", name, type, weight, sharedThemes }
}

public struct AuthorDossierSynthesis: Sendable, Hashable, Codable {
    public let thesis: String
    public let remember: [String]
    public let positioning: String
    public let model: JSONValue?
    public let generatedAt: String
    public let stale: Bool
}

public struct AuthorWorkspaceDossier: Sendable, Hashable, Codable {
    public let author: Row
    public let fullName: String
    public let firstName: String
    public let lastName: String
    public let works: [AuthorDossierWork]
    public let editedWorks: [AuthorDossierWork]
    public let ideas: [AuthorDossierIdea]
    public let relations: [AuthorDossierRelation]
    public let themes: [String]
    public let synthesis: AuthorDossierSynthesis?
}

public struct SynthesisMatrixAuthor: Sendable, Hashable, Codable, Identifiable {
    public var id: String { authorId }
    public let authorId: String
    public let name: String
    public let workCount: Int
    private enum CodingKeys: String, CodingKey { case authorId = "author_id", name, workCount }
}

public struct SynthesisMatrixTheme: Sendable, Hashable, Codable, Identifiable {
    public var id: String { themeId }
    public let themeId: String
    public let label: String
    private enum CodingKeys: String, CodingKey { case themeId = "theme_id", label }
}

public struct SynthesisMatrixCellIdea: Sendable, Hashable, Codable, Identifiable {
    public var id: String { globalId }
    public let globalId: String
    public let label: String
    public let type: String
    private enum CodingKeys: String, CodingKey { case globalId = "global_id", label, type }
}

public struct SynthesisMatrixCell: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(authorId):\(themeId)" }
    public let authorId: String
    public let themeId: String
    public let ideaCount: Int
    public let ideas: [SynthesisMatrixCellIdea]
    public let stance: String?
}

public struct SynthesisMatrix: Sendable, Hashable, Codable {
    public let authors: [SynthesisMatrixAuthor]
    public let themes: [SynthesisMatrixTheme]
    public let cells: [SynthesisMatrixCell]
}

public struct ArgumentRouteRelation: Sendable, Hashable, Codable, Identifiable {
    public var id: String { type }
    public let type: String
    public let count: Int
}

public struct ArgumentRouteSuggestion: Sendable, Hashable, Codable, Identifiable {
    public var id: String { ideaId }
    public let ideaId: String
    public let label: String
    public let statement: String
    public let type: String
    public let degree: Int
    public let debateCount: Int
    public let avgConfidence: Double
    public let topRelations: [ArgumentRouteRelation]
    public let neighborLabels: [String]
}

private struct AuthorDossierEnvelope: Decodable { let dossier: AuthorWorkspaceDossier }
private struct SynthesisMatrixEnvelope: Decodable { let matrix: SynthesisMatrix }
private struct ArgumentRoutesEnvelope: Decodable { let routes: [ArgumentRouteSuggestion] }

public extension NodusClient {
    func workspaceIdeas(
        in spaceId: String,
        query: String = "",
        type: String = "",
        sort: IdeaWorkspaceSort = .label,
        limit: Int = 80,
        offset: Int = 0
    ) async throws -> IdeaWorkspacePage {
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/ideas"),
            query: [
                URLQueryItem(name: "surface", value: "workspace"),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "sort", value: sort.rawValue),
                URLQueryItem(name: "limit", value: String(min(max(1, limit), 200))),
                URLQueryItem(name: "offset", value: String(max(0, offset))),
            ],
            cacheable: true
        ))
        let page = try decode(IdeaWorkspacePage.self, from: response)
        return IdeaWorkspacePage(items: page.items, total: page.total, offset: page.offset, limit: page.limit,
            hasMore: page.hasMore, revision: page.revision, fromDevice: response.fromCache)
    }

    func workspaceAuthors(
        in spaceId: String,
        query: String = "",
        sort: AuthorWorkspaceSort = .surname,
        synthesis: AuthorSynthesisFilter = .all,
        limit: Int = 80,
        offset: Int = 0
    ) async throws -> AuthorWorkspacePage {
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/authors"),
            query: [
                URLQueryItem(name: "surface", value: "workspace"),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "sort", value: sort.rawValue),
                URLQueryItem(name: "synthesis", value: synthesis.rawValue),
                URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
                URLQueryItem(name: "offset", value: String(max(0, offset))),
            ],
            cacheable: true
        ))
        return try decode(AuthorWorkspacePage.self, from: response)
    }

    func authorWorkspaceDossier(_ authorId: String, in spaceId: String) async throws -> AuthorWorkspaceDossier {
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/authors/\(escape(authorId))/dossier"),
            cacheable: true
        ))
        return try decode(AuthorDossierEnvelope.self, from: response).dossier
    }

    func synthesisMatrix(in spaceId: String) async throws -> SynthesisMatrix {
        try await synthesisMatrixSnapshot(in: spaceId).matrix
    }

    func synthesisMatrixSnapshot(in spaceId: String) async throws -> (matrix: SynthesisMatrix, fromCache: Bool) {
        let response = try await perform(.init(path: address.spacePath(spaceId, "/authors/matrix"), cacheable: true))
        return (try decode(SynthesisMatrixEnvelope.self, from: response).matrix, response.fromCache)
    }

    func argumentRoutes(in spaceId: String) async throws -> [ArgumentRouteSuggestion] {
        let response = try await perform(.init(path: address.spacePath(spaceId, "/ideas/routes"), cacheable: true))
        return try decode(ArgumentRoutesEnvelope.self, from: response).routes
    }
}
