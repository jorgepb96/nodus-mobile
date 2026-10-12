import Foundation
import Testing
@testable import NodusKit

@Suite("Selected citation reader boundaries")
struct CompanionReaderScopeTests {
    @Test("published mirror citations use canonical local dossiers without a transport")
    func publishedMirror() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-reader-mirror-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = JSONValue.object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "revision": .string("reader-revision"), "tables": .object([
            "works": .array([.object(["nodus_id": .string("w"), "title": .string("Local work"), "summary": .string("Exact published prose")])]),
            "notes": .array([.object(["id": .string("n"), "title": .string("Local note"), "content": .string("Published note body")])])])])
        let mirror = try await MirrorStore.open(spaceId: "reader-lab", directory: directory)
        try await mirror.replace(with: SnapshotDownload.read(JSONEncoder.nodus.encode(document)), revision: "reader-revision")
        let before = try await mirror.tableCounts()
        guard case .dossier(let work) = try await CompanionReaderScope.resolveMirror(path: "works", id: "w", spaceId: "reader-lab", mirror: mirror) else { Issue.record("Missing local dossier"); return }
        #expect(work.fromDevice); #expect(work.primary.string("summary") == "Exact published prose")
        guard case .literal(let note) = try await CompanionReaderScope.resolveMirror(path: "notes", id: "n", spaceId: "reader-lab", mirror: mirror) else { Issue.record("Missing local note"); return }
        #expect(note.objectValue?["note"]?.objectValue?["title"] == .string("Local note"))
        await #expect(throws: (any Error).self) { try await CompanionReaderScope.resolveMirror(path: "works", id: "absent", spaceId: "reader-lab", mirror: mirror) }
        #expect(try await mirror.tableCounts() == before)
    }
    private func copy(_ path: String, _ primary: String, _ row: Row, sections: [String: JSONValue] = [:]) throws -> CompanionCollectionCopy {
        var detail = sections; detail[primary] = .object(row.columns)
        return try CompanionCollectionCopy(path: path, copies: [.object(["version": .int(1), "path": .string(path), "entries": .array([.object(["summary": .object(row.columns), "detail": .object(detail)])])])])
    }
    @Test("real selected work, author and passage dossiers retain original prose without promoting linked summaries")
    func selectedDossiers() throws {
        let work = try copy("works", "work", Row(["nodus_id": .string("w"), "title": .string("Chosen work"), "summary": .string("Original source")]), sections: ["relatedWorks": .array([.object(["nodus_id": .string("neighbor"), "title": .string("Summary only")])])])
        let author = try copy("authors", "author", Row(["author_id": .string("a"), "name": .string("Chosen author")]))
        let passage = try copy("passages", "passage", Row(["passage_id": .string("p"), "text": .string("Exact literal quote"), "nodus_id": .string("w")]))
        for (path, id, key, expected) in [("works", "w", "summary", "Original source"), ("authors", "a", "name", "Chosen author"), ("passages", "p", "text", "Exact literal quote")] {
            guard case .dossier(let dossier) = try CompanionReaderScope.resolve(path: path, id: id, collections: [work, author, passage]) else { Issue.record("Missing actual dossier"); return }
            #expect(dossier.fromDevice); #expect(dossier.primary.string(key) == expected)
        }
        #expect(throws: CompanionReaderScope.ReadError.self) { try CompanionReaderScope.resolve(path: "works", id: "neighbor", collections: [work]) }
        #expect(throws: CompanionReaderScope.ReadError.self) { try CompanionReaderScope.resolve(path: "passages", id: "w", collections: [work]) }
    }
    @Test("chosen idea bodies and retained edge details are readable but graph neighbors are not independent selected ideas")
    func selectedIdeaAndEdge() throws {
        let ideas = try CompanionIdeaCopy(copies: [CompanionIdeaCopyTests.copy(ids: ["chosen"], edges: [("edge-a", "chosen", "neighbor")])])
        guard case .dossier(let idea) = try CompanionReaderScope.resolve(path: "ideas", id: "chosen", collections: [], ideas: ideas) else { Issue.record("Missing chosen idea"); return }
        #expect(idea.primary.string("statement") == "Private body\nsecond line")
        guard case .literal(let edge) = try CompanionReaderScope.resolve(path: "debates", id: "edge-a", collections: [], ideas: ideas) else { Issue.record("Missing retained edge"); return }
        #expect(edge.objectValue?["edge"]?.objectValue?["id"] == .string("edge-a"))
        #expect(throws: CompanionReaderScope.ReadError.self) { try CompanionReaderScope.resolve(path: "ideas", id: "neighbor", collections: [], ideas: ideas) }
        let independent = try copy("ideas", "idea", Row(["global_id": .string("independent"), "statement": .string("Separate chosen source")]))
        guard case .dossier(let dossier) = try CompanionReaderScope.resolve(path: "ideas", id: "independent", collections: [independent], ideas: ideas) else { Issue.record("Missing independently chosen idea"); return }
        #expect(dossier.primary.string("statement") == "Separate chosen source")
        #expect(throws: CompanionIdeaCopy.CopyError.self) { try CompanionReaderScope.resolve(path: "debates", id: "outside-edge", collections: [], ideas: ideas) }
    }

    @Test("owned or independently downloaded note editor data remains readable and missing notes never acquire a fallback")
    func selectedNotes() throws {
        let editor: JSONValue = .object(["documentTitle": .string("Owned note"), "contentMarkdown": .string("Private literal prose"), "revision": .int(-3), "nativeDocument": .array([])])
        guard case .literal(let retained) = try CompanionReaderScope.resolve(path: "notes", id: "note-a", collections: [], noteEditor: editor) else { Issue.record("Missing owned note"); return }
        #expect(retained == editor)
        #expect(throws: CompanionReaderScope.ReadError.self) { try CompanionReaderScope.resolve(path: "notes", id: "missing", collections: []) }
    }
    @Test("unsupported or absent collections fail explicitly without any transport capability")
    func noFallback() {
        #expect(throws: CompanionReaderScope.ReadError.self) { try CompanionReaderScope.resolve(path: "authors", id: "unknown", collections: []) }
        #expect(throws: CompanionReaderScope.ReadError.self) { try CompanionReaderScope.resolve(path: "debates", id: "unknown", collections: []) }
    }
}
