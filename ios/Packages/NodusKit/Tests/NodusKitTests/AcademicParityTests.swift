import Foundation
import Testing
@testable import NodusKit

@Suite("Academic parity projections")
struct AcademicParityTests {
    private var tables: [String: [Row]] {
        [
            "works": [
                Row(["nodus_id": .string("w1"), "title": .string("Foundations"), "year": .int(1990), "read_tag": .bool(true), "deep_status": .string("done")]),
                Row(["nodus_id": .string("w2"), "title": .string("Recent tensions"), "year": .int(2024), "read_tag": .bool(false), "deep_status": .string("pending")]),
            ],
            "ideas": [
                Row(["global_id": .string("i1"), "label": .string("Structure"), "statement": .string("Structures constrain action"), "type": .string("claim")]),
                Row(["global_id": .string("i2"), "label": .string("Agency"), "statement": .string("Actors transform structures"), "type": .string("claim")]),
            ],
            "idea_occurrences": [
                Row(["global_id": .string("i1"), "nodus_id": .string("w1")]),
                Row(["global_id": .string("i2"), "nodus_id": .string("w2")]),
            ],
            "edges": [
                Row(["id": .string("e1"), "from_id": .string("i1"), "to_id": .string("i2"), "type": .string("contradicts"), "confidence": .double(0.9), "status": .string("accepted"), "source_work": .string("w2")]),
                Row(["id": .string("e2"), "from_id": .string("i2"), "to_id": .string("i1"), "type": .string("supports"), "confidence": .double(0.95), "status": .string("rejected")]),
            ],
            "edge_feedback": [
                Row(["from_id": .string("i2"), "to_id": .string("i1"), "type": .string("supports"), "verdict": .string("rejected")]),
            ],
            "gaps": [
                Row(["id": .string("g1"), "statement": .string("Negative cases remain untested"), "related_idea": .string("i2"), "nodus_id": .string("w2"), "confidence": .double(0.86)]),
            ],
            "authors": [Row(["author_id": .string("a1"), "name": .string("Ada Scholar")])],
            "work_authors": [Row(["author_id": .string("a1"), "nodus_id": .string("w1")])],
            "projects": [Row(["id": .string("p1"), "title": .string("Thesis"), "kind": .string("thesis"), "status": .string("active")])],
            "project_sections": [Row(["id": .string("s1"), "project_id": .string("p1"), "title": .string("Brief"), "role": .string("brief"), "status": .string("ready"), "order_idx": .int(0)])],
        ]
    }

    @Test("idea graph uses accepted grounded edges and a deterministic layout")
    func graphAndLayout() async {
        let graph = AcademicGraphProjection.build(from: tables, lens: .ideas)
        #expect(Set(graph.nodes.map(\.id)) == ["i1", "i2"])
        #expect(graph.edges.map(\.id) == ["e1"])
        let engine = AcademicGraphLayoutEngine()
        let first = await engine.layout(graph: graph, mode: .force, iterations: 40)
        let second = await engine.layout(graph: graph, mode: .force, iterations: 40)
        #expect(first == second)
        #expect(first.values.allSatisfy { (-1...1).contains($0.x) && (-1...1).contains($0.y) })
    }

    @Test("reading strategies preserve source IDs and exclude read works when requested")
    func readingPath() {
        let plan = AcademicReadingProjection.build(from: tables, strategy: .gaps, includeRead: false)
        #expect(plan.totalWorks == 2)
        #expect(plan.phases.flatMap(\.entries).map(\.id) == ["w2"])
        #expect(plan.phases.flatMap(\.entries).first?.gapCount == 1)
    }

    @Test("hypotheses remain attached to the published gap, idea and work")
    func hypotheses() {
        let candidates = AcademicHypothesisProjection.generate(from: tables, objective: "Explain change", mode: .causal)
        #expect(candidates.count == 1)
        #expect(Set(candidates[0].evidence.map(\.refId)).isSuperset(of: ["g1", "i2", "w2"]))
        #expect(candidates[0].hypothesis.contains("Explain change"))
    }

    @Test("projects project their canonical sections")
    func projects() {
        let result = AcademicAuthoredProjection.projects(from: tables)
        #expect(result.count == 1)
        #expect(result[0].sections.map(\.id) == ["s1"])
        #expect(result[0].sections[0].status == "ready")
    }
}
