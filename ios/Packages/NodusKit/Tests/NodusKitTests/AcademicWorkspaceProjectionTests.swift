import Testing
@testable import NodusKit

/// Golden counterpart of `scripts/test-academic-workspace-parity.mjs`.
/// Both suites deliberately describe the same tiny vault so a projection change cannot make
/// the native offline surface disagree with Desktop or the server unnoticed.
@Suite("Academic workspace projection parity")
struct AcademicWorkspaceProjectionTests {
    private var fixture: [String: [Row]] {
        [
            "works": [
                row(["nodus_id": .string("w1"), "title": .string("Written work"), "authors_json": .string("[\"Ada Lovelace\"]"), "year": .int(1843), "archived": .int(0), "deep_status": .string("done"), "read_tag": .int(1)]),
                row(["nodus_id": .string("w2"), "title": .string("Edited volume"), "authors_json": .string("[\"Ada Lovelace\"]"), "year": .int(1844), "archived": .int(0), "deep_status": .string("done"), "read_tag": .int(0)]),
            ],
            "authors": [
                row(["author_id": .string("a1"), "name": .string("Lovelace, Ada"), "affiliation": .string("Analytical Society")]),
                row(["author_id": .string("a2"), "name": .string("Babbage, Charles"), "affiliation": .null]),
            ],
            "work_authors": [
                row(["nodus_id": .string("w1"), "author_id": .string("a1"), "role": .string("author")]),
                row(["nodus_id": .string("w2"), "author_id": .string("a1"), "role": .string("editor")]),
            ],
            "ideas": [
                row(["global_id": .string("i1"), "type": .string("claim"), "label": .string("Machines manipulate symbols"), "statement": .string("A machine can operate on more than quantities.")]),
                row(["global_id": .string("i2"), "type": .string("method"), "label": .string("Describe operations as a sequence"), "statement": .string("Programs make operations explicit.")]),
                row(["global_id": .string("i3"), "type": .string("claim"), "label": .string("Rejected neighbour"), "statement": .string("This edge is vetoed.")]),
            ],
            "idea_occurrences": [
                row(["global_id": .string("i1"), "nodus_id": .string("w1"), "role": .string("principal"), "development": .string("Central claim"), "confidence": .double(0.9)]),
                row(["global_id": .string("i2"), "nodus_id": .string("w2"), "role": .string("principal"), "development": .string("Editor-only attribution"), "confidence": .double(0.8)]),
                row(["global_id": .string("i3"), "nodus_id": .string("w1"), "role": .string("secondary"), "development": .string(""), "confidence": .double(0.4)]),
            ],
            "themes": [row(["theme_id": .string("t1"), "label": .string("Computation")])],
            "idea_theme_links": [
                row(["global_id": .string("i1"), "nodus_id": .string("w1"), "theme_id": .string("t1")]),
                row(["global_id": .string("i2"), "nodus_id": .string("w2"), "theme_id": .string("t1")]),
            ],
            "evidence": [row(["id": .string("ev1"), "global_id": .string("i1"), "nodus_id": .string("w1"), "quote": .string("The engine might act upon other things besides number."), "kind": .string("explicit")])],
            "edges": [
                row(["id": .string("e1"), "from_id": .string("i1"), "to_id": .string("i2"), "type": .string("supports"), "confidence": .double(0.8)]),
                row(["id": .string("e2"), "from_id": .string("i1"), "to_id": .string("i3"), "type": .string("contradicts"), "confidence": .double(0.95)]),
            ],
            "edge_feedback": [row(["type": .string("contradicts"), "from_id": .string("i1"), "to_id": .string("i3"), "verdict": .string("rejected")])],
            "author_relations": [row(["from_author": .string("a1"), "to_author": .string("a2"), "type": .string("supports"), "weight": .double(0.7)])],
            "author_dossier_synthesis": [row([
                "author_id": .string("a1"), "thesis": .string("Symbolic operations can be specified."),
                "remember_json": .string("[\"Programs are sequences\"]"), "positioning": .string("Extends the engine beyond arithmetic."),
                "model_json": .null, "fingerprint": .string("84d494bed00b897f"), "generated_at": .string("2026-08-22T00:00:00.000Z"),
            ])],
            "synthesis_matrix_cell": [row(["author_id": .string("a1"), "theme_id": .string("t1"), "stance": .string("Computation is symbolic."), "fingerprint": .string("2a4869786a5839b5")])],
            "zotero_tags": [],
            "work_zotero_tags": [],
        ]
    }

    @Test("Ideas applies Desktop aggregates and rejected-edge semantics")
    func ideas() throws {
        #expect(AcademicWorkspaceProjection.visibleEdges(in: fixture).count == 1)
        let page = AcademicWorkspaceProjection.ideaPage(
            in: fixture, query: "machine", type: "claim", sort: .connections, limit: 20
        )
        let item = try #require(page.items.first)
        #expect(page.total == 1)
        #expect(item.id == "i1")
        #expect(item.workCount == 1)
        #expect(item.themes == ["Computation"])
        #expect(item.maxConfidence == 0.9)
        #expect(item.connectionCount == 1)
    }

    @Test("Authors keeps editor-only attribution provisional")
    func authors() throws {
        let page = AcademicWorkspaceProjection.authorPage(in: fixture, synthesis: .with, limit: 20)
        let author = try #require(page.items.first)
        #expect(author.fullName == "Ada Lovelace")
        #expect(author.workCount == 1)
        #expect(author.editedCount == 1)
        #expect(author.ideaCount == 3)
        #expect(author.saved == false)

        let dossier = try #require(AcademicWorkspaceProjection.authorDossier(in: fixture, authorId: "a1"))
        #expect(dossier.works.map(\.nodusId) == ["w1"])
        #expect(dossier.editedWorks.map(\.nodusId) == ["w2"])
        #expect(dossier.ideas.first { $0.globalId == "i2" }?.provisional == true)
        #expect(dossier.synthesis?.stale == false)
    }

    @Test("Matrix and Argument routes are grounded in the same rows")
    func matrixAndRoutes() throws {
        let matrix = AcademicWorkspaceProjection.synthesisMatrix(in: fixture)
        #expect(matrix.authors.first?.authorId == "a1")
        #expect(matrix.themes.first?.themeId == "t1")
        #expect(matrix.cells.first?.ideaCount == 2)
        #expect(matrix.cells.first?.stance == "Computation is symbolic.")

        let routes = AcademicWorkspaceProjection.argumentRoutes(in: fixture)
        #expect(routes.map(\.ideaId) == ["i1", "i2"])
        #expect(routes.first?.degree == 1)
        #expect(routes.first?.debateCount == 0)
        #expect(routes.first?.neighborLabels == ["Describe operations as a sequence"])
    }

    private func row(_ columns: [String: JSONValue]) -> Row { Row(columns) }
}
