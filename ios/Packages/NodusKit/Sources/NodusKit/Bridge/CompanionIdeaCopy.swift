import Foundation

/// Selected canonical dossiers and their direct graph neighbourhoods. This is a
/// bounded read copy; it never claims to contain the Mac's complete corpus.
public struct CompanionIdeaCopy: Sendable {
    public static let recordId = "companion:ideas:v1"
    public static let operationMethods: Set<String> = ["stellarPage", "stellarThemes", "getIdeaDetail", "getIdeaEdges", "getEdgeDetail", "listPickerIdeas"]
    private let entries: [JSONValue]
    private let nodes: [JSONValue]
    private let edges: [JSONValue]
    private let themes: [JSONValue]
    private let edgeDetails: [JSONValue]
    /// Actual chosen dossiers, excluding the summaries of graph neighbours.
    public var selectedRows: [Row] {
        entries.map { Row($0.objectValue!["nativeDetail"]!.objectValue!["idea"]!.objectValue!) }
    }

    public enum CopyError: Error, LocalizedError {
        case unavailable
        public var errorDescription: String? { String(localized: "Esta idea o conexión no está descargada. Conecta con tu Mac para consultarla.") }
    }

    public init(copies: [JSONValue]) throws {
        var entries: [JSONValue] = [], nodes: [JSONValue] = [], edges: [JSONValue] = [], themes: [JSONValue] = [], details: [JSONValue] = []
        var entryIds = Set<String>(), nodeIds = Set<String>(), edgeIds = Set<String>(), themeIds = Set<String>(), detailIds = Set<String>()
        var newestOwner: [String: Int] = [:]
        for (index, copy) in copies.enumerated() {
            for item in copy.objectValue?["entries"]?.arrayValue ?? [] {
                if let id = item.objectValue?["summary"]?.objectValue?["id"]?.stringValue, newestOwner[id] == nil { newestOwner[id] = index }
            }
        }
        for (index, copy) in copies.enumerated() {
            guard copy.objectValue?["version"]?.intValue == 1,
                  let items = copy.objectValue?["entries"]?.arrayValue, !items.isEmpty,
                  let graph = copy.objectValue?["graph"]?.objectValue,
                  let graphNodes = graph["nodes"]?.arrayValue, let graphEdges = graph["edges"]?.arrayValue,
                  let copyThemes = copy.objectValue?["themes"]?.arrayValue,
                  let edgeDetails = copy.objectValue?["edgeDetails"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            var ownEntries = Set<String>(), ownNodes = Set<String>(), ownEdges = Set<String>()
            for item in items {
                guard let summary = item.objectValue?["summary"],
                      let id = summary.objectValue?["id"]?.stringValue, !id.isEmpty, ownEntries.insert(id).inserted,
                      item.objectValue?["detail"]?.objectValue?["idea"]?.objectValue?["global_id"]?.stringValue == id,
                      let native = item.objectValue?["nativeDetail"], native.objectValue?["idea"]?.objectValue?["global_id"]?.stringValue == id,
                      item.objectValue?["connections"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
                _ = try JSONDecoder.nodus.decode(IdeaWorkspaceItem.self, from: JSONEncoder.nodus.encode(summary))
                _ = try JSONDecoder.nodus.decode(IdeaDetail.self, from: JSONEncoder.nodus.encode(native))
                if entryIds.insert(id).inserted { entries.append(item) }
            }
            for node in graphNodes {
                guard let id = node.objectValue?["id"]?.stringValue, !id.isEmpty, ownNodes.insert(id).inserted,
                      node.objectValue?["label"]?.stringValue != nil, node.objectValue?["themes"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
                if nodeIds.insert(id).inserted { nodes.append(node) }
            }
            guard ownEntries.isSubset(of: ownNodes) else { throw DesktopBridgeError.malformedResponse }
            for edge in graphEdges {
                guard let id = edge.objectValue?["id"]?.stringValue, !id.isEmpty, ownEdges.insert(id).inserted,
                      let source = edge.objectValue?["source"]?.stringValue, ownNodes.contains(source),
                      let target = edge.objectValue?["target"]?.stringValue, ownNodes.contains(target),
                      ownEntries.contains(source) || ownEntries.contains(target),
                      edge.objectValue?["verdict"]?.stringValue != "rejected" else { throw DesktopBridgeError.malformedResponse }
                // A newer complete neighbourhood owns absence as well as
                // presence. An older pack cannot resurrect its removed edge.
                if (newestOwner[source] ?? index) < index || (newestOwner[target] ?? index) < index { continue }
                if edgeIds.insert(id).inserted { edges.append(edge) }
            }
            for theme in copyThemes {
                guard let id = theme.objectValue?["id"]?.stringValue, !id.isEmpty,
                      theme.objectValue?["label"]?.stringValue != nil else { throw DesktopBridgeError.malformedResponse }
                if themeIds.insert(id).inserted { themes.append(theme) }
            }
            var ownDetailIds = Set<String>()
            for detail in edgeDetails {
                guard let id = detail.objectValue?["edge"]?.objectValue?["id"]?.stringValue, ownEdges.contains(id), ownDetailIds.insert(id).inserted else { throw DesktopBridgeError.malformedResponse }
                if edgeIds.contains(id), detailIds.insert(id).inserted { details.append(detail) }
            }
            guard ownDetailIds == ownEdges else { throw DesktopBridgeError.malformedResponse }
        }
        self.entries = entries; self.nodes = nodes; self.edges = edges; self.themes = themes; self.edgeDetails = details
    }

    public static func downloaded(cache: PrivateBridgeCache, vaultId: String) async throws -> Self? {
        let bytes = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: recordId)
        guard !bytes.isEmpty else { return nil }
        return try Self(copies: bytes.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) })
    }
    public static func authored(cache: PrivateBridgeCache, vaultId: String) async throws -> JSONValue? {
        guard let data = try await cache.data(vaultId: vaultId, domain: .writing, recordId: CompanionDocumentOutbox.storageKey) else { return nil }
        return try await CompanionDocumentOutbox(cache: cache, vaultId: vaultId, data: data).pendingIdeaCopy()
    }
    public static func consultable(cache: PrivateBridgeCache, vaultId: String) async throws -> Self? {
        var copies: [JSONValue] = []
        if let local = try await authored(cache: cache, vaultId: vaultId) { copies.append(local) }
        let downloaded = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: recordId)
        copies.append(contentsOf: try downloaded.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) })
        return copies.isEmpty ? nil : try Self(copies: copies)
    }
    public func containsFullIdea(_ id: String) -> Bool { entry(id) != nil }

    public func nativeResponse(path: String, query: [URLQueryItem], percentEncoded: Bool) throws -> DesktopBridgeResponse? {
        let parts = try path.split(separator: "/").map { part -> String in
            guard !percentEncoded || String(part).removingPercentEncoding != nil else { throw DesktopBridgeError.invalidOrigin }
            return percentEncoded ? String(part).removingPercentEncoding! : String(part)
        }
        let result: JSONValue
        if parts == ["ideas"], query.first(where: { $0.name == "surface" })?.value == "workspace" {
            func argument(_ name: String) -> String { query.first(where: { $0.name == name })?.value ?? "" }
            let offset = max(0, Int(argument("offset")) ?? 0), limit = min(200, max(1, Int(argument("limit")) ?? 80))
            let search = argument("q").trimmingCharacters(in: .whitespacesAndNewlines), type = argument("type"), sort = argument("sort")
            var items = entries.compactMap { $0.objectValue?["summary"] }
            items = items.filter { row in
                let item = row.objectValue!
                return (type.isEmpty || item["type"]?.stringValue == type) && (search.isEmpty || Self.like(item["label"]?.stringValue ?? "", search) || Self.like(item["statement"]?.stringValue ?? "", search))
            }
            items.sort { left, right in
                let a = left.objectValue!, b = right.objectValue!
                if sort == "type", a["type"] != b["type"] { return (a["type"]?.stringValue ?? "") < (b["type"]?.stringValue ?? "") }
                if let key = ["works": "workCount", "connections": "connectionCount", "confidence": "maxConfidence"][sort], a[key] != b[key] {
                    return (a[key]?.doubleValue ?? 0) > (b[key]?.doubleValue ?? 0)
                }
                let first = Self.asciiLower(a["label"]?.stringValue ?? ""), second = Self.asciiLower(b["label"]?.stringValue ?? "")
                return first == second ? (a["id"]?.stringValue ?? "") < (b["id"]?.stringValue ?? "") : first < second
            }
            let page = Self.page(items, offset: offset, limit: limit)
            result = .object(["ideas": .array(page), "total": .int(Int64(items.count)), "offset": .int(Int64(offset)), "limit": .int(Int64(limit)), "hasMore": .bool(offset < items.count && page.count < items.count - offset), "revision": .null])
        } else if parts.count == 2, parts[0] == "ideas", parts[1] != "routes" {
            guard let entry = entry(parts[1]), let detail = entry.objectValue?["nativeDetail"] else { throw CopyError.unavailable }
            result = detail
        } else { return nil }
        return DesktopBridgeResponse(data: try JSONEncoder.nodus.encode(result), status: 200, headers: ["x-nodus-device-copy": "selected"])
    }

    public func operation(_ method: String, args: [JSONValue]) throws -> JSONValue? {
        switch method {
        case "listPickerIdeas":
            return .array(entries.map { entry in
                let summary = entry.objectValue!["summary"]!.objectValue!
                return .object(["global_id": summary["id"]!, "label": summary["label"]!, "type": summary["type"]!, "statement": summary["statement"]!])
            })
        case "getIdeaDetail", "getIdeaEdges":
            guard let id = args.first?.stringValue, let entry = entry(id) else { throw CopyError.unavailable }
            return entry.objectValue?[method == "getIdeaDetail" ? "detail" : "connections"]
        case "getEdgeDetail":
            guard let id = args.first?.stringValue,
                  let detail = edgeDetails.first(where: { $0.objectValue?["edge"]?.objectValue?["id"]?.stringValue == id }) else { throw CopyError.unavailable }
            return detail
        case "stellarThemes": return .array(scopedThemes())
        case "stellarPage":
            guard args.count == 1, let request = args[0].objectValue,
                  let kind = request["kind"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            let offset = max(0, request["cursor"]?.intValue ?? 0), limit = min(200, max(1, request["limit"]?.intValue ?? 200))
            var ns = nodes, es = edges
            if kind == "neighbors" {
                guard let id = request["id"]?.stringValue, entry(id) != nil else { throw CopyError.unavailable }
                ns = []; es = es.filter { $0.objectValue?["source"]?.stringValue == id || $0.objectValue?["target"]?.stringValue == id }.sorted(by: Self.edgeBefore)
            } else if kind == "search" {
                let search = request["search"]?.stringValue ?? "", author = request["author"]?.stringValue ?? ""
                ns = ns.filter { node in
                    let value = node.objectValue!
                    return (search.isEmpty || Self.like(value["label"]?.stringValue ?? "", search) || Self.like(value["statement"]?.stringValue ?? "", search))
                        && (author.isEmpty || (value["authors"]?.arrayValue ?? []).contains { Self.like($0.stringValue ?? "", author) })
                }; es = []
            } else if kind == "theme" || kind == "work" {
                let id = request["id"]?.stringValue ?? ""
                let label = themes.first { $0.objectValue?["id"]?.stringValue == id }?.objectValue?["label"]?.stringValue ?? id
                ns = ns.filter { ($0.objectValue?[kind == "theme" ? "themes" : "workIds"]?.arrayValue ?? []).contains(.string(kind == "theme" ? label : id)) }
                let ids = Set(ns.compactMap { $0.objectValue?["id"]?.stringValue })
                es = es.filter { ids.contains($0.objectValue?["source"]?.stringValue ?? "") && ids.contains($0.objectValue?["target"]?.stringValue ?? "") }
            } else if kind == "elements" {
                ns = ns.filter { (request["nodeIds"]?.arrayValue ?? []).contains($0.objectValue!["id"]!) }
                es = es.filter { (request["edgeIds"]?.arrayValue ?? []).contains($0.objectValue!["id"]!) }
            } else if kind != "corpus" { throw DesktopBridgeError.malformedResponse }
            if kind != "neighbors" { ns.sort { ($0.objectValue?["id"]?.stringValue ?? "") < ($1.objectValue?["id"]?.stringValue ?? "") }; es.sort { ($0.objectValue?["id"]?.stringValue ?? "") < ($1.objectValue?["id"]?.stringValue ?? "") } }
            let total = max(ns.count, es.count)
            let pageNodes = Self.page(ns, offset: offset, limit: limit), pageEdges = Self.page(es, offset: offset, limit: limit)
            let ids = Set(pageNodes.compactMap { $0.objectValue?["id"]?.stringValue } + pageEdges.flatMap { [$0.objectValue?["source"]?.stringValue, $0.objectValue?["target"]?.stringValue].compactMap { $0 } })
            let next = offset < total && limit < total - offset ? JSONValue.int(Int64(offset + limit)) : .null
            return .object(["nodes": .array(nodes.filter { ids.contains($0.objectValue?["id"]?.stringValue ?? "") }), "edges": .array(pageEdges), "total": .int(Int64(total)), "next": next])
        default: return nil
        }
    }

    private func entry(_ id: String) -> JSONValue? { entries.first { $0.objectValue?["summary"]?.objectValue?["id"]?.stringValue == id } }
    private func scopedThemes() -> [JSONValue] {
        themes.compactMap { theme in
            var value = theme.objectValue!
            let label = value["label"]!.stringValue!
            let members = nodes.filter { ($0.objectValue?["themes"]?.arrayValue ?? []).contains(.string(label)) }
            guard !members.isEmpty else { return nil }
            value["ideaCount"] = .int(Int64(members.count))
            value["workCount"] = .int(Int64(Set(members.flatMap { $0.objectValue?["workIds"]?.arrayValue ?? [] }).count))
            return .object(value)
        }
    }
    private static func edgeBefore(_ left: JSONValue, _ right: JSONValue) -> Bool {
        func rank(_ value: JSONValue) -> Int { value.objectValue?["verdict"]?.stringValue == "confirmed" ? 0 : value.objectValue?["basis"]?.stringValue == "explicit" ? 1 : 2 }
        if rank(left) != rank(right) { return rank(left) < rank(right) }
        let a = left.objectValue?["confidence"]?.doubleValue ?? 0, b = right.objectValue?["confidence"]?.doubleValue ?? 0
        return a == b ? (left.objectValue?["id"]?.stringValue ?? "") < (right.objectValue?["id"]?.stringValue ?? "") : a > b
    }
    private static func page(_ values: [JSONValue], offset: Int, limit: Int) -> [JSONValue] {
        guard offset < values.count else { return [] }
        return Array(values[offset..<(offset + min(limit, values.count - offset))])
    }
    private static func asciiLower(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { (65...90).contains($0.value) ? UnicodeScalar($0.value + 32)! : $0 }))
    }
    private static func like(_ value: String, _ search: String) -> Bool {
        let pattern = asciiLower(search).map { $0 == "%" ? ".*" : $0 == "_" ? "." : NSRegularExpression.escapedPattern(for: String($0)) }.joined()
        return asciiLower(value).range(of: "(?s)" + pattern, options: .regularExpression) != nil
    }
}
