import CryptoKit
import Foundation

/// Private Desktop citations retain their own identity and domain. A private
/// person identifier is never interpreted as a published population member.
public struct PrivateCorpusReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case recording = "study-recording", person = "prosop-person", source = "prosop-source"
        case factoid = "prosop-factoid", mention = "prosop-mention"
        public var domain: DesktopBridgeDomain { self == .recording ? .studyRecordings : .prosopographyPrivate }
        public var primaryKey: String {
            switch self { case .recording: "id"; case .person: "person_id"; case .source: "source_id"
            case .factoid: "factoid_id"; case .mention: "attestation_id" }
        }
        public var groups: [String] {
            switch self {
            case .recording: ["transcripts", "segments", "markers"]
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
    }
    private static func isRevision(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
    public var title: String { root.text("title") ?? root.text("display_name") ?? root.text("literal_name") ?? root.text("summary") ?? id }
}

/// A complete, explicitly chosen dossier, kept in the source's encrypted grant.
public struct CompanionPrivateSourceCopy: Codable, Sendable {
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
}
