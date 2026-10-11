import CryptoKit
import Foundation

/// Provider-free lexical retrieval over explicitly chosen primary records.
/// Graph neighbours, linked summaries and orientation profiles are not promoted
/// to citable records. No documents are extracted, indexed or derived on iOS.
public struct CompanionSelectedContext: Sendable {
    private static let academicPaths = ["ideas", "passages", "themes", "gaps", "works"]
    public static let paths = academicPaths + CorpusSourceMaterial.paths
    private static let sectionKinds = academicPaths + ["sources"]
    private let rows: [String: [Row]]
    private let revision: String

    public init(collections: [CompanionCollectionCopy], ideas: CompanionIdeaCopy? = nil) throws {
        var rows: [String: [Row]] = [:], ids: [String: Set<String>] = [:]
        if let ideas {
            rows["ideas"] = ideas.selectedRows
            ids["ideas"] = Set(ideas.selectedRows.compactMap { $0.string("global_id") })
        }
        for copy in collections {
            guard Self.paths.contains(copy.collection.path) else { throw DesktopBridgeError.permissionDenied }
            let path = copy.collection.path
            if !Self.academicPaths.contains(path) {
                for row in try CorpusSourceMaterial.selected(copy: copy) {
                    guard let token = row.string("citation") else { throw DesktopBridgeError.malformedResponse }
                    if ids["sources", default: []].insert(token).inserted { rows["sources", default: []].append(row) }
                }
                continue
            }
            for row in copy.selectedRows {
                guard let id = row.string(copy.collection.idField), !id.isEmpty else { throw DesktopBridgeError.malformedResponse }
                if ids[path, default: []].insert(id).inserted { rows[path, default: []].append(row) }
            }
        }
        self.rows = rows
        let value = JSONValue.object(rows.mapValues { .array($0.map { .object($0.columns) }) })
        revision = "companion:context:" + SHA256.hash(data: try JSONEncoder.nodus.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    public static func downloaded(cache: PrivateBridgeCache, vaultId: String) async throws -> Self? {
        var collections: [CompanionCollectionCopy] = []
        for path in paths {
            if let copy = try await CompanionCollectionCopy.downloaded(cache: cache, vaultId: vaultId, path: path) { collections.append(copy) }
        }
        let ideas = try await CompanionIdeaCopy.consultable(cache: cache, vaultId: vaultId)
        return collections.isEmpty && ideas == nil ? nil : try Self(collections: collections, ideas: ideas)
    }

    public static func hasSource(cache: PrivateBridgeCache, vaultId: String) async throws -> Bool {
        if try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: CompanionIdeaCopy.recordId) { return true }
        for path in paths {
            if try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: CompanionCollectionCopy.recordId(path: path)) { return true }
        }
        return try await cache.data(vaultId: vaultId, domain: .writing, recordId: CompanionDocumentOutbox.storageKey) != nil
    }

    public func response(body: JSONValue) throws -> DesktopBridgeResponse {
        guard let request = body.objectValue, request.keys.allSatisfy({ ["query", "budget", "include"].contains($0) }),
              let query = request["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              query.utf8.count <= 16_384,
              request["budget"] == nil || request["budget"]?.intValue != nil,
              request["include"] == nil || request["include"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        let requested = request["include"]?.arrayValue
        guard requested?.allSatisfy({ $0.stringValue.map(Self.sectionKinds.contains) ?? false }) != false else { throw DesktopBridgeError.malformedResponse }
        let wanted = Set(requested == nil || requested!.isEmpty ? Self.sectionKinds : requested!.map { $0.stringValue! })
        let budget = min(120_000, max(1000, request["budget"]?.intValue ?? 120_000))
        let tokens = Self.tokens(query)
        var sections: [JSONValue] = [], used = 0, matched = 0, truncated = false
        for path in Self.sectionKinds where wanted.contains(path) {
            let ranked = (rows[path] ?? []).enumerated().compactMap { ordinal, row -> (Int, Int, Row)? in
                let text = Self.fold(row.searchableText)
                let score = tokens.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
                return score == 0 ? nil : (score, ordinal, row)
            }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 > $1.0 }
            matched += ranked.count
            var kept: [JSONValue] = []
            for (_, _, row) in ranked {
                let value = JSONValue.object(row.columns), cost = try JSONEncoder.nodus.encode(value).count
                // Preserve literal text in full. A partial quote is never advertised
                // as the original passage just to fit the context budget.
                if cost > budget - used { truncated = true; continue }
                kept.append(value); used += cost
            }
            if !kept.isEmpty { sections.append(.object(["kind": .string(path), "items": .array(kept)])) }
        }
        let package: JSONValue = .object(["sections": .array(sections), "revision": .string(revision),
            "sourceScope": .string("device_downloads"),
            "stats": .object(["chars": .int(Int64(used)), "budget": .int(Int64(budget)), "truncated": .bool(truncated), "matched": .int(Int64(matched))]),
            "citationScheme": .object(["idea": .string("nodus://idea/<global_id>"), "passage": .string("nodus://passage/<passage_id>"), "work": .string("nodus://work/<nodus_id>"), "gap": .string("nodus://gap/<id>")])])
        return DesktopBridgeResponse(data: try JSONEncoder.nodus.encode(package), status: 200,
            headers: ["content-type": "application/json", "x-nodus-device-copy": "selected"])
    }

    private static func fold(_ value: String) -> String { value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es_ES")) }
    private static func tokens(_ query: String) -> Set<String> {
        let stop: Set<String> = ["de", "la", "el", "en", "al", "es", "un", "an", "of", "to", "on", "is", "in", "le", "et", "du", "que", "como", "cual", "cuales", "las", "los", "del", "con", "por", "para", "una", "unos", "unas", "entre", "sobre", "the", "and", "for", "from", "how", "what", "with", "this", "that", "are", "les", "des", "une", "dans", "der", "die", "das", "und"]
        return Set(fold(query).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 && !stop.contains($0) })
    }
}
