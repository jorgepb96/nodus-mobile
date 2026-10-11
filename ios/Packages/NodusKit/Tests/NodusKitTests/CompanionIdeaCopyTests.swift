import Foundation
import Testing
@testable import NodusKit

@Suite("Selected companion ideas")
struct CompanionIdeaCopyTests {
    static func copy(ids: [String], edges: [(String, String, String)] = []) -> JSONValue {
        let all = Set(ids + edges.flatMap { [$0.1, $0.2] }).sorted()
        let entries: [JSONValue] = ids.enumerated().map { index, id in
            let idea: JSONValue = .object(["global_id": .string(id), "label": .string(id), "statement": .string("Private body\nsecond line"), "type": .string(index.isMultiple(of: 2) ? "claim" : "finding")])
            let detail: JSONValue = .object(["idea": idea, "occurrences": .array([]), "evidence": .array([]), "themes": .array([.string("Topic")])])
            var native = detail.objectValue!; native["relations"] = .array([]); native["revision"] = .null
            return .object(["summary": .object(["id": .string(id), "label": .string(id), "statement": .string("Private body\nsecond line"), "type": .string(index.isMultiple(of: 2) ? "claim" : "finding"),
                "workCount": .int(Int64(ids.count - index)), "connectionCount": .int(0), "maxConfidence": .double(0.8), "themes": .array([.string("Topic")])]),
                "detail": detail, "nativeDetail": .object(native), "connections": .array([])])
        }
        return .object(["version": .int(1), "entries": .array(entries), "graph": .object([
            "nodes": .array(all.map { .object(["id": .string($0), "label": .string($0), "statement": .string("Private body"), "type": .string("claim"),
                "workCount": .int(0), "workIds": .array([]), "themes": .array([.string("Topic")]), "authors": .array([]), "years": .array([]), "read": .bool(false), "maxConfidence": .double(0.8)]) }),
            "edges": .array(edges.map { .object(["id": .string($0.0), "source": .string($0.1), "target": .string($0.2), "type": .string("supports"), "basis": .string("explicit"), "confidence": .double(0.8)]) })]),
            "themes": .array([.object(["id": .string("theme-id"), "label": .string("Topic"), "ideaCount": .int(99999), "workCount": .int(99999), "curated": .bool(true)])]),
            "edgeDetails": .array(edges.map { .object(["edge": .object(["id": .string($0.0), "from_id": .string($0.1), "to_id": .string($0.2)])]) })])
    }

    @Test("selected native catalogues paginate, filter and sort without consulting an incidental cached page")
    func nativeCatalogue() throws {
        let ids = (0..<241).map { String(format: "idea-%03d", $0) }
        let copy = try CompanionIdeaCopy(copies: [Self.copy(ids: ids)])
        let query = [URLQueryItem(name: "surface", value: "workspace"), URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "offset", value: "200"), URLQueryItem(name: "sort", value: "works")]
        let response = try #require(try copy.nativeResponse(path: "ideas", query: query, percentEncoded: true))
        let page = try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: response.data)
        #expect(page.total == 241); #expect(page.items.count == 41); #expect(!page.hasMore)
        #expect(page.items.first?.id == "idea-200")
        let filtered = try #require(try copy.nativeResponse(path: "ideas", query: [URLQueryItem(name: "surface", value: "workspace"), URLQueryItem(name: "q", value: "idea-0_1"), URLQueryItem(name: "type", value: "finding")], percentEncoded: true))
        let items = try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: filtered.data)
        #expect(items.total == 10); #expect(items.items.allSatisfy { $0.type == "finding" })
        let multiline = try #require(try copy.nativeResponse(path: "ideas", query: [URLQueryItem(name: "surface", value: "workspace"), URLQueryItem(name: "q", value: "body%second")], percentEncoded: false))
        #expect(try JSONDecoder.nodus.decode(IdeaWorkspacePage.self, from: multiline.data).total == 241)
        let detail = try #require(try copy.nativeResponse(path: "ideas/idea-240", query: [], percentEncoded: true))
        #expect(try JSONDecoder.nodus.decode(IdeaDetail.self, from: detail.data).idea.string("global_id") == "idea-240")
    }

    @Test("confirmed authored text cannot erase a selected canonical dossier or claim its absent neighbourhood")
    func authoredTextScope() throws {
        var partial = Self.copy(ids: ["own"]).objectValue!, entry = partial["entries"]!.arrayValue![0].objectValue!
        var summary = entry["summary"]!.objectValue!; summary["mobileSourceScope"] = .string("authoredText")
        summary["label"] = .string("Own retained text"); entry["summary"] = .object(summary)
        for key in ["detail", "nativeDetail"] {
            var detail = entry[key]!.objectValue!, idea = detail["idea"]!.objectValue!
            idea["mobileSourceScope"] = .string("authoredText"); detail["idea"] = .object(idea)
            entry[key] = .object(detail)
        }
        partial["entries"] = .array([.object(entry)])
        var graph = partial["graph"]!.objectValue!, node = graph["nodes"]!.arrayValue![0].objectValue!
        node["mobileSourceScope"] = .string("authoredText"); graph["nodes"] = .array([.object(node)]); partial["graph"] = .object(graph)
        let text = try CompanionIdeaCopy(copies: [.object(partial)])
        #expect(!text.containsFullIdea("own"))
        #expect(throws: CompanionIdeaCopy.CopyError.self) { try text.operation("getIdeaEdges", args: [.string("own")]) }
        #expect(throws: CompanionIdeaCopy.CopyError.self) { try text.operation("stellarPage", args: [.object(["kind": .string("neighbors"), "id": .string("own")])]) }
        let selected = Self.copy(ids: ["own"], edges: [("real-edge", "own", "other")])
        for copies in [[.object(partial), selected], [selected, .object(partial)]] {
            let merged = try CompanionIdeaCopy(copies: copies)
            #expect(merged.containsFullIdea("own"))
            #expect(try merged.operation("getIdeaDetail", args: [.string("own")])?.objectValue?["idea"]?.objectValue?["mobileSourceScope"] == nil)
            let neighbors = try #require(try merged.operation("stellarPage", args: [.object(["kind": .string("neighbors"), "id": .string("own")])]))
            #expect(neighbors.objectValue?["total"] == .int(1))
        }
        var broken = entry, native = entry["nativeDetail"]!.objectValue!
        native["evidence"] = .array([.object(["id": .string("invented")])]); broken["nativeDetail"] = .object(native)
        partial["entries"] = .array([.object(broken)])
        #expect(throws: DesktopBridgeError.self) { try CompanionIdeaCopy(copies: [.object(partial)]) }
    }

    @Test("all 503 direct connections are available, while an undownloaded neighbour cannot impersonate a complete dossier")
    func completeNeighbourhood() throws {
        let edges = (0..<503).map { (String(format: "e-%03d", $0), "seed", "neighbour-\($0)") }
        let copy = try CompanionIdeaCopy(copies: [Self.copy(ids: ["seed"], edges: edges)])
        var cursor = 0, seen = Set<String>()
        repeat {
            let page = try #require(try copy.operation("stellarPage", args: [.object(["kind": .string("neighbors"), "id": .string("seed"), "cursor": .int(Int64(cursor)), "limit": .int(200)])]))
            let object = try #require(page.objectValue)
            #expect(object["total"]?.intValue == 503)
            for edge in object["edges"]!.arrayValue! { #expect(seen.insert(edge.objectValue!["id"]!.stringValue!).inserted) }
            guard let next = object["next"]?.intValue else { break }
            #expect(next > cursor); cursor = next
        } while true
        #expect(seen.count == 503)
        #expect(throws: CompanionIdeaCopy.CopyError.self) { try copy.operation("getIdeaDetail", args: [.string("neighbour-0")]) }
        #expect(throws: CompanionIdeaCopy.CopyError.self) { try copy.operation("stellarPage", args: [.object(["kind": .string("neighbors"), "id": .string("neighbour-0")])]) }
        let themes = try #require(copy.operation("stellarThemes", args: [])?.arrayValue)
        #expect(themes.first?.objectValue?["ideaCount"]?.intValue == 504)
        #expect(themes.first?.objectValue?["workCount"]?.intValue == 0)
    }

    @Test("a newer empty neighbourhood suppresses an older pack's removed relation")
    func removedRelations() throws {
        let old = Self.copy(ids: ["a", "b"], edges: [("ab", "a", "b")])
        let current = Self.copy(ids: ["a"])
        let copy = try CompanionIdeaCopy(copies: [current, old])
        let page = try #require(try copy.operation("stellarPage", args: [.object(["kind": .string("corpus")])]))
        #expect(page.objectValue?["nodes"]?.arrayValue?.count == 2)
        #expect(page.objectValue?["edges"]?.arrayValue?.isEmpty == true)
        #expect(throws: CompanionIdeaCopy.CopyError.self) { try copy.operation("getEdgeDetail", args: [.string("ab")]) }
        var broken = current.objectValue!
        broken["graph"] = .object(["nodes": .array([]), "edges": .array([])])
        #expect(throws: DesktopBridgeError.self) { try CompanionIdeaCopy(copies: [.object(broken)]) }
    }
}
