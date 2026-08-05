import Foundation

// Debates, assembled on the device.
//
// `debates` is not a table anywhere: it is a projection over `contradicts` and `refutes` edges
// that the desktop computes in SQL and the server recomputes over a snapshot
// (`server/lib/core/debates.mjs`). A third implementation is not something to be pleased about,
// and it is what a demo with no server needs — the alternative is a Debates section that opens
// on an error in the one build most likely to be somebody's first look at the app.
//
// Ported field for field from the server's version, with one deliberate difference, marked
// below: the sentence that describes the tension is built where the app can translate it.
extension LocalCorpus {
    private static let debateRelations: Set<String> = ["contradicts", "refutes"]
    /// Lean mode keeps one quote per work; the list only ever renders the first.
    private static let listEvidencePerWork = 1
    private static let tensionClip = 180

    func debates(_ segments: [String], revision: String) async throws -> [String: JSONValue] {
        let visible = try await visibleEdges()
        let material = try await Material(corpus: self, edges: visible)

        guard segments.count > 1 else {
            let edges = visible.filter { Self.debateRelations.contains($0.string("type") ?? "") }
            let clusters = Self.cluster(edges)
            let assembled = edges
                .compactMap { edge -> (row: Row, size: Int, confidence: Double)? in
                    guard let id = edge.string("id"), let root = clusters.identity[id] else { return nil }
                    let size = clusters.size[root] ?? 1
                    guard let built = material.assemble(edge, clusterId: root, clusterSize: size, lean: true) else { return nil }
                    return (Row(built), size, edge.double("confidence") ?? 0)
                }
                // Multi-sided debates first, then by confidence — the richest disputes lead.
                .sorted { left, right in
                    left.size == right.size ? left.confidence > right.confidence : left.size > right.size
                }
                .map(\.row)
            return Self.page("debates", assembled, limit: 100, offset: 0, revision: revision)
        }

        let wanted = segments[1]
        guard
            let edge = visible.first(where: { $0.string("id") == wanted && Self.debateRelations.contains($0.string("type") ?? "") }),
            // A single-edge lookup does not run the clustering pass, so the cluster is the
            // edge's own origin and its size is one. `getDebate` is explicit about this and the
            // two answers would otherwise disagree about the same debate.
            let built = material.assemble(edge, clusterId: edge.string("from_id") ?? wanted, clusterSize: 1, lean: false)
        else {
            throw Self.notFound
        }
        return ["debate": .object(built), "revision": .string(revision)]
    }

    // MARK: - Everything a debate is assembled from

    /// Read once and shared across every debate in the answer.
    ///
    /// The server builds the same maps for the same reason: assembling a side costs one pass
    /// over four tables, and a corpus with forty debates would otherwise make forty of them.
    private struct Material {
        let ideas: [String: Row]
        let occurrencesByIdea: [String: [Row]]
        let evidenceByIdea: [String: [Row]]
        let works: [String: Row]
        let themesByIdea: [String: [String]]
        /// How many `supports` edges point *at* each idea, which is what tips a debate.
        let support: [String: Int]

        init(corpus: LocalCorpus, edges: [Row]) async throws {
            ideas = try await corpus.rows(of: "ideas").reduce(into: [:]) { result, row in
                if let id = row.string("global_id") { result[id] = row }
            }
            occurrencesByIdea = try await corpus.rows(of: "idea_occurrences").reduce(into: [:]) { result, row in
                if let id = row.string("global_id") { result[id, default: []].append(row) }
            }
            evidenceByIdea = try await corpus.rows(of: "evidence").reduce(into: [:]) { result, row in
                if let id = row.string("global_id") { result[id, default: []].append(row) }
            }
            works = try await corpus.rows(of: "works").reduce(into: [:]) { result, row in
                if let id = row.string("nodus_id") { result[id] = row }
            }

            let labels = try await corpus.rows(of: "themes").reduce(into: [String: String]()) { result, row in
                if let id = row.string("theme_id"), let label = row.text("label") { result[id] = label }
            }
            themesByIdea = try await corpus.rows(of: "idea_theme_links").reduce(into: [:]) { result, link in
                guard
                    let idea = link.string("global_id"),
                    let label = link.string("theme_id").flatMap({ labels[$0] })
                else { return }
                if !(result[idea]?.contains(label) ?? false) { result[idea, default: []].append(label) }
            }

            support = edges.reduce(into: [:]) { result, edge in
                guard edge.string("type") == "supports", let to = edge.string("to_id") else { return }
                result[to, default: 0] += 1
            }
        }

        /// One side of a debate: the idea, the works it occurs in, and the quotations behind it.
        func side(_ ideaId: String, lean: Bool) -> [String: JSONValue]? {
            guard let idea = ideas[ideaId] else { return nil }

            // Grouped by work before the cap is applied, so lean mode keeps one quote per work
            // rather than the first few quotes overall — a global cap would keep a different set.
            var evidenceByWork: [String: [Row]] = [:]
            for item in evidenceByIdea[ideaId] ?? [] {
                let workId = item.string("nodus_id") ?? ""
                if lean, (evidenceByWork[workId]?.count ?? 0) >= LocalCorpus.listEvidencePerWork { continue }
                evidenceByWork[workId, default: []].append(item)
            }

            var sideWorks: [JSONValue] = []
            var authors: [JSONValue] = []
            var years: [Int] = []
            for occurrence in occurrencesByIdea[ideaId] ?? [] {
                // An occurrence whose work did not travel is dropped, matching the filter the
                // desktop applies over its own batched work lookup.
                guard let workId = occurrence.string("nodus_id"), let work = works[workId] else { continue }
                let workAuthors = work.embeddedJSON("authors_json")?.arrayValue ?? []
                for author in workAuthors where !authors.contains(author) { authors.append(author) }
                if let year = work.int("year") { years.append(year) }
                sideWorks.append(.object([
                    "nodus_id": .string(workId),
                    "title": work.text("title").map(JSONValue.string) ?? .null,
                    "zotero_key": work.string("zotero_key").map(JSONValue.string) ?? .null,
                    "authors": .array(workAuthors),
                    "year": work.int("year").map { .int(Int64($0)) } ?? .null,
                    "role": occurrence.string("role").map(JSONValue.string) ?? .null,
                    "development": lean ? .string("") : (occurrence.text("development").map(JSONValue.string) ?? .null),
                    "evidence": .array((evidenceByWork[workId] ?? []).map { .object($0.columns) }),
                ]))
            }

            return [
                "ideaId": .string(ideaId),
                "type": idea.string("type").map(JSONValue.string) ?? .null,
                "label": idea.text("label").map(JSONValue.string) ?? .null,
                "statement": idea.text("statement").map(JSONValue.string) ?? .null,
                "authors": .array(authors),
                "works": .array(sideWorks),
                "earliestYear": years.min().map { .int(Int64($0)) } ?? .null,
                "latestYear": years.max().map { .int(Int64($0)) } ?? .null,
            ]
        }

        func assemble(_ edge: Row, clusterId: String, clusterSize: Int, lean: Bool) -> [String: JSONValue]? {
            guard
                let from = edge.string("from_id"),
                let to = edge.string("to_id"),
                let sideA = side(from, lean: lean),
                let sideB = side(to, lean: lean)
            else { return nil }

            let themesA = themesByIdea[from] ?? []
            let themesB = Set(themesByIdea[to] ?? [])
            let shared = themesA.filter { themesB.contains($0) }

            let supportA = support[from] ?? 0
            let supportB = support[to] ?? 0
            let status = supportA == supportB ? "open" : "leaning"
            let leaning: JSONValue = supportA == supportB ? .null : .string(supportA > supportB ? "A" : "B")

            let worksA = Set((sideA["works"]?.arrayValue ?? []).compactMap { $0.objectValue?["nodus_id"]?.stringValue })
            let internalToOneWork = (sideB["works"]?.arrayValue ?? [])
                .compactMap { $0.objectValue?["nodus_id"]?.stringValue }
                .contains { worksA.contains($0) }

            return [
                "id": edge.string("id").map(JSONValue.string) ?? .null,
                "relation": edge.string("type").map(JSONValue.string) ?? .null,
                "basis": edge.string("basis").map(JSONValue.string) ?? .null,
                "confidence": edge.double("confidence").map(JSONValue.double) ?? .null,
                "clusterId": .string(clusterId),
                "clusterSize": .int(Int64(clusterSize)),
                "status": .string(status),
                "leaningSide": leaning,
                "sharedThemes": .array(shared.map(JSONValue.string)),
                "internal": .bool(internalToOneWork),
                "sideA": .object(sideA),
                "sideB": .object(sideB),
                "timeline": .array(LocalCorpus.timeline(sideA, sideB)),
                "tension": .string(LocalCorpus.tension(edge.string("type"), sideA, sideB)),
                // `edge_traces` is never published, so no client can have one. Null by contract
                // on the server too, rather than an omission here.
                "trace": .null,
            ]
        }
    }

    // MARK: - Pieces

    /// Union-find over idea ids, so a dispute with more than two sides surfaces as one cluster.
    private static func cluster(_ edges: [Row]) -> (identity: [String: String], size: [String: Int]) {
        var parent: [String: String] = [:]
        func find(_ node: String) -> String {
            var root = node
            while let next = parent[root], next != root { root = next }
            var current = node
            while let next = parent[current], next != root {
                parent[current] = root
                current = next
            }
            parent[node] = root
            return root
        }
        for edge in edges {
            guard let from = edge.string("from_id"), let to = edge.string("to_id") else { continue }
            if parent[from] == nil { parent[from] = from }
            if parent[to] == nil { parent[to] = to }
            parent[find(from)] = find(to)
        }

        var identity: [String: String] = [:]
        var size: [String: Int] = [:]
        for edge in edges {
            guard let id = edge.string("id"), let from = edge.string("from_id") else { continue }
            let root = find(from)
            identity[id] = root
            size[root, default: 0] += 1
        }
        return (identity, size)
    }

    /// Side A's works, then side B's, by year, with undated works sinking to the end.
    private static func timeline(_ sideA: [String: JSONValue], _ sideB: [String: JSONValue]) -> [JSONValue] {
        func entries(_ side: [String: JSONValue], _ label: String) -> [(year: Int?, value: JSONValue)] {
            (side["works"]?.arrayValue ?? []).compactMap { value in
                guard let work = value.objectValue else { return nil }
                let year = work["year"]?.intValue
                return (year, .object([
                    "year": work["year"] ?? .null,
                    "side": .string(label),
                    "nodus_id": work["nodus_id"] ?? .null,
                    "title": work["title"] ?? .null,
                    "authors": work["authors"] ?? .array([]),
                ]))
            }
        }
        return (entries(sideA, "A") + entries(sideB, "B"))
            .enumerated()
            .sorted { left, right in
                switch (left.element.year, right.element.year) {
                case (nil, nil): return left.offset < right.offset
                case (nil, _): return false
                case (_, nil): return true
                case (let a?, let b?): return a == b ? left.offset < right.offset : a < b
                }
            }
            .map(\.element.value)
    }

    /// The one sentence a reader gets before they open a debate.
    ///
    /// The server writes this in Spanish for every client, whatever language the client is in
    /// (`debates.mjs:34`). It is reproduced here in the reader's own language instead, through
    /// the app's catalogue — a demo is somebody's first look at the app, and a sentence in the
    /// wrong language is the sort of thing that reads as a broken build rather than as a quirk
    /// of a server they do not have.
    private static func tension(_ relation: String?, _ sideA: [String: JSONValue], _ sideB: [String: JSONValue]) -> String {
        let left = clip(sideA["statement"]?.stringValue ?? sideA["label"]?.stringValue ?? "")
        let right = clip(sideB["statement"]?.stringValue ?? sideB["label"]?.stringValue ?? "")
        if relation == "refutes" {
            return String(localized: "The refutation is that “\(left)” refuses “\(right)”.", bundle: .main)
        }
        return String(localized: "The contradiction is that “\(left)” is in tension with “\(right)”.", bundle: .main)
    }

    private static func clip(_ value: String) -> String {
        let clean = value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > tensionClip else { return clean }
        return "\(clean.prefix(tensionClip - 1).trimmingCharacters(in: .whitespaces))…"
    }
}
