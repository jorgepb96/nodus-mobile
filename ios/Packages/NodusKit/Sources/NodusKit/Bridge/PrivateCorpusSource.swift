import CryptoKit
import Foundation

/// Private Desktop citations retain their own identity and domain. A private
/// person identifier is never interpreted as a published population member.
public struct PrivateCorpusReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case recording = "study-recording", person = "prosop-person", source = "prosop-source"
        case factoid = "prosop-factoid", mention = "prosop-mention"
        case participant = "testimony-participant"
        public var domain: DesktopBridgeDomain {
            switch self { case .recording: .studyRecordings; case .participant: .testimonies; default: .prosopographyPrivate }
        }
        public var primaryKey: String {
            switch self { case .recording: "id"; case .person, .participant: "person_id"; case .source: "source_id"
            case .factoid: "factoid_id"; case .mention: "attestation_id" }
        }
        public var groups: [String] {
            switch self {
            case .recording: ["transcripts", "segments", "markers"]
            case .participant: ["profile", "participation"]
            case .person: ["profile", "mentions", "authorities", "factoids", "statements", "membership"]
            case .source: ["segments", "factoids", "mentions", "assessments"]
            case .factoid: ["source", "segments", "statements", "entities", "mentions"]
            case .mention: ["person", "source", "segments", "factoids"]
            }
        }
    }
    public let kind: Kind
    public let id: String
    public let timestamp: Double?
    public let transcriptId: String?
    public init(kind: Kind, id: String) throws {
        guard !id.isEmpty, id.count <= 256, id != ".", id != "..",
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw DesktopBridgeError.malformedResponse }
        self.kind = kind; self.id = id; timestamp = nil; transcriptId = nil
    }
    public init?(_ url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "nodus",
              parts.user == nil, parts.password == nil, parts.port == nil else { return nil }
        let encoded = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let segments = encoded.compactMap { String($0).removingPercentEncoding }
        guard segments.count == 2, segments.count == encoded.count,
              segments.allSatisfy({ !$0.isEmpty && $0.count <= 256 && $0 != "." && $0 != ".." && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else { return nil }
        let target: Kind?
        switch parts.host?.lowercased() {
        case "study" where segments[0] == "recording": target = .recording
        case "testimonios" where segments[0] == "participant": target = .participant
        case "prosop": target = ["person": .person, "source": .source, "factoid": .factoid, "mention": .mention][segments[0]]
        default: target = nil
        }
        guard let target else { return nil }
        let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        kind = target; id = segments[1]
        timestamp = query["t"].flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        transcriptId = query["transcript"].flatMap { !$0.isEmpty ? $0 : nil }
    }
    public var recordKey: String {
        let identity = Data("\(kind.rawValue.utf8.count):\(kind.rawValue)\(id.utf8.count):\(id)".utf8)
        return "companion:private-source:v1:" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
    public func path(vaultId: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let parts = [vaultId, kind.domain.rawValue, "sources", kind.rawValue, id]
        let encoded = try parts.map { part -> String in
            guard let value = part.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.malformedResponse }
            return value
        }
        return "/bridge/v2/vaults/" + encoded.joined(separator: "/")
    }
}

public struct PrivateCorpusSource: Codable, Sendable {
    public struct CatalogueItem: Codable, Sendable, Identifiable {
        public let id: String, title: String, detail: String, updatedAt: String
        public let state: String?
        public init(id: String, title: String, detail: String, updatedAt: String, state: String? = nil) {
            self.id = id; self.title = title; self.detail = detail; self.updatedAt = updatedAt
            self.state = state
        }
    }
    public struct Catalogue: Codable, Sendable {
        public let items: [CatalogueItem]
        public let total: Int, offset: Int, limit: Int
        public let hasMore: Bool
        public let revision: String
        public func validate(offset expected: Int) throws {
            guard offset == expected, offset >= 0, total >= 0, limit > 0, limit <= 100, Self.isRevision(revision),
                  Set(items.map(\.id)).count == items.count, items.allSatisfy({ !$0.id.isEmpty }),
                  items.count == min(limit, max(0, total - offset)), hasMore == (offset + items.count < total) else { throw DesktopBridgeError.malformedResponse }
        }
        private static func isRevision(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    }
    public struct Group: Codable, Sendable, Equatable, Identifiable {
        public let key: String, title: String, revision: String
        public let total: Int
        public var id: String { key }
    }
    public struct Page: Codable, Sendable {
        public let rows: [Row]
        public let cursor: Int, total: Int
        public let hasMore: Bool
        public let revision: String
    }
    public let version: Int
    public let kind: PrivateCorpusReference.Kind
    public let id: String
    public let root: Row
    public let groups: [Group]
    public let revision: String
    public func validate(for reference: PrivateCorpusReference) throws {
        guard version == 1, kind == reference.kind, id == reference.id, root.string(kind.primaryKey) == id,
              groups.map(\.key) == kind.groups, Self.isRevision(revision),
              groups.allSatisfy({ $0.total >= 0 && Self.isRevision($0.revision) }) else { throw DesktopBridgeError.malformedResponse }
        var total = 0
        for group in groups {
            let next = total.addingReportingOverflow(group.total)
            guard !next.overflow else { throw DesktopBridgeError.malformedResponse }
            total = next.partialValue
        }
    }
    private static func isRevision(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    public var title: String { root.text("title") ?? root.text("display_name") ?? root.text("literal_name") ?? root.text("summary") ?? id }
}

/// A complete, explicitly chosen dossier, kept in the source's encrypted grant.
public struct CompanionPrivateSourceCopy: Codable, Sendable {
    public static let catalogueKey = "companion:private-sources:catalogue:v1"
    public struct CatalogueEntry: Codable, Sendable {
        public let kind: PrivateCorpusReference.Kind
        public let item: PrivateCorpusSource.CatalogueItem
        public init(source: PrivateCorpusSource) {
            kind = source.kind
            item = .init(id: source.id, title: source.title,
                detail: source.root.text("date_display") ?? source.root.text("status") ?? "",
                updatedAt: source.root.text("updated_at") ?? "",
                state: source.kind == .recording ? (source.root.text("deleted_at") != nil ? "trash" : source.root.text("archived_at") != nil ? "archived" : "active") : nil)
        }
    }
    public let version: Int
    public let source: PrivateCorpusSource
    public let rows: [String: [Row]]
    public init(source: PrivateCorpusSource, rows: [String: [Row]], reference: PrivateCorpusReference) throws {
        version = 1; self.source = source; self.rows = rows
        try validate(for: reference)
    }
    public func validate(for reference: PrivateCorpusReference) throws {
        try source.validate(for: reference)
        guard version == 1, Set(rows.keys) == Set(source.groups.map(\.key)) else { throw DesktopBridgeError.malformedResponse }
        for group in source.groups {
            let items = rows[group.key] ?? []
            let cursors = items.compactMap { $0.int("_bridge_cursor") }
            guard items.count == group.total, cursors.count == items.count,
                  cursors.allSatisfy({ $0 > 0 }), Set(cursors).count == cursors.count else { throw DesktopBridgeError.malformedResponse }
        }
    }
    public static func downloaded(cache: PrivateBridgeCache, vaultId: String, reference: PrivateCorpusReference) async throws -> Self? {
        guard let bytes = try await cache.downloadedData(vaultId: vaultId, domain: reference.kind.domain, recordId: reference.recordKey).first else { return nil }
        let copy = try JSONDecoder.nodus.decode(Self.self, from: bytes)
        try copy.validate(for: reference)
        return copy
    }
    public static func downloadedCatalogue(cache: PrivateBridgeCache, vaultId: String, kind: PrivateCorpusReference.Kind) async throws -> [PrivateCorpusSource.CatalogueItem] {
        let entries = try await cache.downloadedData(vaultId: vaultId, domain: kind.domain, recordId: catalogueKey)
        var seen = Set<String>(), items: [PrivateCorpusSource.CatalogueItem] = []
        for bytes in entries {
            let entry = try JSONDecoder.nodus.decode(CatalogueEntry.self, from: bytes)
            guard entry.kind == kind else { continue }
            let reference = try PrivateCorpusReference(kind: kind, id: entry.item.id)
            guard try await cache.hasDownloadedData(vaultId: vaultId, domain: kind.domain, recordId: reference.recordKey) else { throw DesktopBridgeError.malformedResponse }
            if seen.insert(entry.item.id).inserted { items.append(entry.item) }
        }
        return items
    }
}
