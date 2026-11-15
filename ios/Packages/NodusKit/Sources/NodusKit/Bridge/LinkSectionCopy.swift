import CryptoKit
import Foundation

public enum LinkDownloadSection: String, CaseIterable, Codable, Sendable {
    case ideas, authors, dictionary, deepResearch, graph, argument, library, podcast
    public var recordId: String { "link:section:v1:\(rawValue)" }
    public func packId(vaultId: String) throws -> UUID {
        try PrivateBridgeCache.readPackSelectionId(vaultId: vaultId, recordIds: [recordId])
    }
}

/// Consults only complete, explicitly selected read packs. Every read revalidates the
/// grant/cache scope and live manifest; removal, expiry and revocation cannot be bypassed
/// by the bounded in-memory query runtime. No decrypted SQLite file is persisted.
public actor LinkSectionCopies {
    public static let shared = LinkSectionCopies()
    public nonisolated static let operationMethods: Set<String> = ["getSettings", "podcastEpisodes", "podcastEpisode", "podcastImageData", "podcastImages",
        "stellarPage", "stellarThemes", "getIdeaDetail", "getIdeaEdges", "getEdgeDetail", "listPickerIdeas", "discoverArgumentRoutes", "getMobileStructuralArgumentMap"]
    private struct Loaded {
        let envelopes: [JSONValue]
        let document: [String: JSONValue]
        let corpus: LocalCorpus
    }
    private var resident: [String: Loaded] = [:]
    private var order: [String] = []

    private func load(cache: PrivateBridgeCache, vaultId: String, sections: [LinkDownloadSection]) async throws -> Loaded? {
        let packs = try await cache.readPacks(vaultId: vaultId)
        let chosen = try sections.compactMap { section -> (LinkDownloadSection, PrivateBridgeCache.ReadPack)? in
            let id = try section.packId(vaultId: vaultId)
            return packs.first(where: { $0.id == id }).map { (section, $0) }
        }.sorted { $0.1.createdAt > $1.1.createdAt }
        guard !chosen.isEmpty else { return nil }
        let key = cache.storageIdentity + "|" + vaultId + "|" + chosen.map { "\($0.1.id):\($0.1.createdAt.timeIntervalSince1970)" }.joined(separator: "|")
        if let value = resident[key] { return value }
        var envelopes: [JSONValue] = []
        var tables: [String: [JSONValue]] = [:], seen: [String: Set<String>] = [:]
        var document: [String: JSONValue]?
        var authoritativeTables = Set<String>()
        for (section, _) in chosen {
            guard let data = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: section.recordId).first else { continue }
            let envelope = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
            guard envelope.objectValue?["version"] == .int(1), envelope.objectValue?["section"] == .string(section.rawValue),
                  let snapshot = envelope.objectValue?["snapshot"]?.objectValue,
                  snapshot["vault"]?.objectValue?["id"] == .string(vaultId),
                  snapshot["vault"]?.objectValue?["type"] == .string("academic"),
                  let source = snapshot["tables"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
            if document == nil { document = snapshot }
            envelopes.append(envelope)
            for (name, values) in source {
                // Non-dictionary projections contain complete tables. The newest complete
                // table owns deletions too; an older section must not resurrect removed rows.
                // Dictionary context is intentionally partial and only fills tables for which
                // no complete selected source exists.
                if authoritativeTables.contains(name) { continue }
                if section != .dictionary {
                    authoritativeTables.insert(name); tables[name] = []; seen[name] = []
                }
                guard let rows = values.arrayValue else { throw DesktopBridgeError.malformedResponse }
                for row in rows {
                    let fields = row.objectValue ?? [:]
                    let primary = Collections.byTable[name]?.idField
                    let composite: [String]
                    switch name {
                    case "work_authors": composite = ["nodus_id","author_id","role"]
                    case "work_themes": composite = ["nodus_id","theme_id"]
                    case "idea_occurrences": composite = ["global_id","nodus_id"]
                    case "idea_theme_links": composite = ["global_id","nodus_id","theme_id"]
                    default: composite = [primary ?? "id"]
                    }
                    let identity = composite.compactMap { fields[$0].map { String(describing: $0) } }.joined(separator: "\u{1F}")
                    let fallback = SHA256.hash(data: try JSONEncoder.nodus.encode(row)).map { String(format: "%02x", $0) }.joined()
                    if seen[name, default: []].insert(identity.isEmpty ? fallback : identity).inserted { tables[name, default: []].append(row) }
                }
            }
        }
        guard var document, !envelopes.isEmpty else { return nil }
        document["tables"] = .object(tables.mapValues(JSONValue.array))
        document["revision"] = .string("download:" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined())
        let archive = try JSONEncoder.nodus.encode(JSONValue.object(document))
        let snapshot = try SnapshotDownload.read(archive)
        let mirror = try MirrorStore(inMemorySpaceId: "downloaded")
        _ = try await mirror.replace(with: snapshot, revision: snapshot.revision ?? "downloaded")
        let value = Loaded(envelopes: envelopes, document: document,
            corpus: LocalCorpus(space: .init(id: "downloaded", name: document["vault"]?.objectValue?["name"]?.stringValue ?? "Nodus"), mirror: mirror, archive: archive))
        resident[key] = value; order.removeAll { $0 == key }; order.append(key)
        while order.count > 2 { resident[order.removeFirst()] = nil }
        return value
    }

    public func invalidate() { resident = [:]; order = [] }

    public func hasCopy(cache: PrivateBridgeCache, vaultId: String) async throws -> Bool {
        let packs = try await cache.readPacks(vaultId: vaultId)
        return try LinkDownloadSection.allCases.contains { section in
            let id = try section.packId(vaultId: vaultId)
            return packs.contains { $0.id == id }
        }
    }

    public func response(cache: PrivateBridgeCache, vaultId: String, path: String, query: [URLQueryItem], percentEncoded: Bool) async throws -> DesktopBridgeResponse? {
        let first = path.split(separator: "/").first.map(String.init) ?? ""
        let sections: [LinkDownloadSection]
        switch first {
        case "ideas": sections = [.ideas,.graph,.argument]
        case "authors": sections = [.authors]
        case "works", "work-summaries": sections = [.library]
        case "deep-research": sections = [.deepResearch]
        case "snapshot": sections = query.first(where: { $0.name == "projection" })?.value == "dictionary" ? [.dictionary] : LinkDownloadSection.allCases
        case "", "assets", "search", "themes": sections = LinkDownloadSection.allCases
        default: return nil
        }
        guard let loaded = try await load(cache: cache, vaultId: vaultId, sections: sections) else { return nil }
        if first == "assets", let hash = path.split(separator: "/").last.map(String.init) {
            for envelope in loaded.envelopes {
                for asset in envelope.objectValue?["assets"]?.arrayValue ?? [] where asset.objectValue?["hash"] == .string(hash) {
                    guard let encoded = asset.objectValue?["base64"]?.stringValue, let data = Data(base64Encoded: encoded),
                          SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else { throw DesktopBridgeError.malformedResponse }
                    return .init(data: data, status: 200, headers: ["content-type": asset.objectValue?["mime"]?.stringValue ?? "application/octet-stream", "x-nodus-device-copy": "selected"])
                }
            }
            return nil
        }
        let encodedPath = percentEncoded ? path : path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))) ?? ""
        }.joined(separator: "/")
        let response = try await loaded.corpus.answer(.init(path: "/api/v1/spaces/downloaded/" + encodedPath, query: query))
        var headers = response.headers; headers["x-nodus-device-copy"] = "selected"
        return .init(data: response.data, status: response.status, headers: headers)
    }

    public func operation(cache: PrivateBridgeCache, vaultId: String, method: String, args: [JSONValue]) async throws -> JSONValue? {
        let podcastMethods = ["podcastEpisodes","podcastEpisode","podcastImageData","podcastImages"]
        let graphMethods = ["stellarPage","stellarThemes","getIdeaDetail","getIdeaEdges","getEdgeDetail","listPickerIdeas","discoverArgumentRoutes","getMobileStructuralArgumentMap"]
        guard method == "getSettings" || podcastMethods.contains(method) || graphMethods.contains(method) else { return nil }
        let sections: [LinkDownloadSection] = podcastMethods.contains(method) ? [.podcast] : graphMethods.contains(method) ? [.ideas,.graph,.argument] : LinkDownloadSection.allCases
        guard let loaded = try await load(cache: cache, vaultId: vaultId, sections: sections) else {
            if podcastMethods.contains(method) {
                if method == "podcastEpisodes" {
                    var episodes: [JSONValue] = [], seen = Set<String>()
                    for pack in try await cache.readPacks(vaultId: vaultId) where pack.primaryFile?.kind == .podcastAudio {
                        guard let id = pack.primaryFile?.id, seen.insert(id).inserted,
                              let data = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: CompanionDocumentOutbox.operationKey("podcastEpisode", [.string(id)])).first else { continue }
                        episodes.append(try JSONDecoder.nodus.decode(JSONValue.self, from: data))
                    }
                    return episodes.isEmpty ? nil : .array(episodes)
                }
                let key = try CompanionDocumentOutbox.operationKey(method, args)
                if let data = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: key).first { return try JSONDecoder.nodus.decode(JSONValue.self, from: data) }
            }
            return nil
        }
        if method == "getSettings" { return loaded.envelopes.compactMap { $0.objectValue?["settings"] }.first }
        if podcastMethods.contains(method) {
            let episodes = loaded.envelopes.flatMap { $0.objectValue?["episodes"]?.arrayValue ?? [] }
            let id = args.first?.stringValue ?? ""
            if method == "podcastEpisodes" { return .array(episodes) }
            if method == "podcastEpisode" { return episodes.first { $0.objectValue?["id"] == .string(id) } }
            if method == "podcastImages" { return .array([]) }
            return loaded.envelopes.flatMap { $0.objectValue?["podcastImages"]?.arrayValue ?? [] }
                .first { $0.objectValue?["id"] == .string(id) }?.objectValue?["dataURL"] ?? .null
        }
        guard let graph = loaded.envelopes.compactMap({ $0.objectValue?["graph"]?.objectValue }).first,
              let nodes = graph["nodes"]?.arrayValue, let edges = graph["edges"]?.arrayValue else { return nil }
        let tables = loaded.document["tables"]?.objectValue ?? [:]
        func rows(_ table: String) -> [JSONValue] { tables[table]?.arrayValue ?? [] }
        func idea(_ id: String) -> JSONValue? { rows("ideas").first { $0.objectValue?["global_id"] == .string(id) } }
        if method == "stellarThemes" { return graph["themes"] ?? .array([]) }
        if method == "discoverArgumentRoutes" { return loaded.envelopes.compactMap { $0.objectValue?["argumentRoutes"] }.first ?? .array([]) }
        if method == "listPickerIdeas" { return .array(rows("ideas")) }
        if method == "getMobileStructuralArgumentMap", let id = args.first?.objectValue?["seedIdeaId"]?.stringValue {
            let visibleIds = Set(edges.compactMap { $0.objectValue?["id"]?.stringValue })
            let graphValue: JSONValue = .object(["seedId": .string(id), "depth": .int(3), "truncated": .bool(false),
                "ideas": .array(rows("ideas")), "edges": .array(rows("edges").filter { visibleIds.contains($0.objectValue?["id"]?.stringValue ?? "") }), "revision": loaded.document["revision"] ?? .null])
            let native = try JSONDecoder.nodus.decode(IdeaGraph.self, from: JSONEncoder.nodus.encode(graphValue))
            guard let map = ArgumentMapBuilder.structural(from: native) else { return .null }
            func block(_ item: ArgumentBlock) -> JSONValue {
                .object(["id": .string(item.id), "ideaId": .string(item.ideaId), "label": .string(item.label), "statement": .string(item.statement),
                    "type": .string(item.type), "relation": .string(item.relation.rawValue), "summary": .string(""),
                    "hiddenChildren": .int(Int64(item.hiddenChildren)), "children": .array(item.children.map(block))])
            }
            return .object(["seedIdeaId": .string(map.seedIdeaId), "seedLabel": .string(map.seedLabel), "overview": .string(""),
                "root": block(map.root), "truncated": .bool(map.truncated), "ideaCount": .int(Int64(map.ideaCount)), "generatedAt": .string(ISO8601DateFormatter().string(from: Date()))])
        }
        if method == "getIdeaDetail", let id = args.first?.stringValue {
            let response = try await loaded.corpus.answer(.init(path: "/api/v1/spaces/downloaded/ideas/" + id))
            var value = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data).objectValue ?? [:]
            value["occurrences"] = .array((value["occurrences"]?.arrayValue ?? []).map { entry in
                var occurrence = entry.objectValue ?? [:]
                occurrence["work"] = rows("works").first { $0.objectValue?["nodus_id"] == occurrence["nodus_id"] } ?? .null
                return .object(occurrence)
            })
            return .object(value)
        }
        if method == "getIdeaEdges", let id = args.first?.stringValue {
            return .array(rows("edges").filter { $0.objectValue?["from_id"] == .string(id) || $0.objectValue?["to_id"] == .string(id) })
        }
        if method == "getEdgeDetail", let id = args.first?.stringValue,
           let edge = rows("edges").first(where: { $0.objectValue?["id"] == .string(id) }) {
            let from = edge.objectValue?["from_id"]?.stringValue ?? "", to = edge.objectValue?["to_id"]?.stringValue ?? ""
            return .object(["edge": edge, "fromLabel": idea(from)?.objectValue?["label"] ?? .string(from),
                "toLabel": idea(to)?.objectValue?["label"] ?? .string(to), "evidence": .array(rows("evidence").filter { $0.objectValue?["edge_id"] == .string(id) }),
                "trace": rows("edge_traces").first { $0.objectValue?["edge_id"] == .string(id) } ?? .null])
        }
        if method == "stellarPage", let request = args.first?.objectValue, let kind = request["kind"]?.stringValue {
            let offset = max(0, request["cursor"]?.intValue ?? 0), limit = min(200, max(1, request["limit"]?.intValue ?? 200))
            var ns = nodes, es = edges
            let id = request["id"]?.stringValue ?? ""
            if kind == "search" {
                let q = request["search"]?.stringValue ?? "", author = request["author"]?.stringValue ?? ""
                ns = ns.filter { node in
                    let row = node.objectValue ?? [:]
                    return (q.isEmpty || ((row["label"]?.stringValue ?? "") + " " + (row["statement"]?.stringValue ?? "")).localizedStandardContains(q))
                        && (author.isEmpty || (row["authors"]?.arrayValue ?? []).contains { ($0.stringValue ?? "").localizedStandardContains(author) })
                }; es = []
            } else if kind == "neighbors" {
                ns = []; es = es.filter { $0.objectValue?["source"] == .string(id) || $0.objectValue?["target"] == .string(id) }
            } else if kind == "theme" || kind == "work" {
                let label = (graph["themes"]?.arrayValue ?? []).first { $0.objectValue?["id"] == .string(id) }?.objectValue?["label"]?.stringValue ?? id
                ns = ns.filter { ($0.objectValue?[kind == "theme" ? "themes" : "workIds"]?.arrayValue ?? []).contains(.string(kind == "theme" ? label : id)) }
                let ids = Set(ns.compactMap { $0.objectValue?["id"]?.stringValue })
                es = es.filter { ids.contains($0.objectValue?["source"]?.stringValue ?? "") && ids.contains($0.objectValue?["target"]?.stringValue ?? "") }
            } else if kind == "elements" {
                ns = ns.filter { (request["nodeIds"]?.arrayValue ?? []).contains($0.objectValue?["id"] ?? .null) }
                es = es.filter { (request["edgeIds"]?.arrayValue ?? []).contains($0.objectValue?["id"] ?? .null) }
            }
            func page(_ values: [JSONValue]) -> [JSONValue] { Array(values.dropFirst(offset).prefix(limit)) }
            let total = max(ns.count, es.count), keptEdges = page(es)
            var ids = Set(page(ns).compactMap { $0.objectValue?["id"]?.stringValue })
            for edge in keptEdges { for key in ["source","target"] { if let id = edge.objectValue?[key]?.stringValue { ids.insert(id) } } }
            return .object(["nodes": .array(nodes.filter { ids.contains($0.objectValue?["id"]?.stringValue ?? "") }), "edges": .array(keptEdges),
                "total": .int(Int64(total)), "next": offset + limit < total ? .int(Int64(offset + limit)) : .null])
        }
        return nil
    }
}
