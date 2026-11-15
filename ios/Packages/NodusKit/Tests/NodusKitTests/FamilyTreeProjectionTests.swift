import Testing
@testable import NodusKit

@Suite("Recorded family tree")
struct FamilyTreeProjectionTests {
    private func person(_ id: String, _ name: String? = nil, sex: String = "unknown") -> Row {
        Row(["person_id": .string(id), "display_name": .string(name ?? id), "sex": .string(sex)])
    }
    private func edge(_ from: String, _ to: String, _ type: String, adoptive: Bool = false, aliases: Bool = false) -> Row {
        Row([aliases ? "from_person_id" : "from_person": .string(from),
             aliases ? "to_person_id" : "to_person": .string(to),
             aliases ? "kind" : "type": .string(type), "subtype": .string(adoptive ? "adoptive" : "biological")])
    }
    @Test func explicitSiblingsWithoutParentsAreSymmetricAndDeduplicated() {
        let tree = FamilyTreeProjection(people: [person("a"), person("b"), person("c"), person("p")], relationships: [
            edge("a", "b", "sibling"), edge("b", "a", "sibling"), edge("p", "a", "parent"),
            edge("p", "c", "parent"), edge("c", "a", "sibling")])
        #expect(tree.siblings(of: "a") == ["b", "c"])
        #expect(tree.siblings(of: "b") == ["a"])
        #expect(tree.edges.filter { $0.kind == .sibling }.count == 2)
        #expect(tree.pedigree(focus: "b").first { $0.id == "a" }?.generation == 0)
    }
    @Test func adoptionSurvivesAliasesAndReverseChildDirection() {
        let tree = FamilyTreeProjection(people: [person("child"), person("adoptive"), person("biological")], relationships: [
            edge("child", "adoptive", "child", adoptive: true, aliases: true), edge("biological", "child", "parent")])
        #expect(tree.parents(of: "child") == ["adoptive", "biological"])
        #expect(tree.children(of: "adoptive") == ["child"])
        #expect(tree.isAdoptive(between: "child", and: "adoptive"))
        #expect(tree.isAdoptive(between: "adoptive", and: "child"))
        #expect(!tree.isAdoptive(between: "child", and: "biological"))
    }
    @Test func completeComponentSurvivesCyclesDanglingEdgesAndShuffledInput() {
        let people = [person("focus"), person("father", sex: "male"), person("grand"), person("great"), person("child"), person("sibling"), person("isolated")]
        let rows = [edge("father", "focus", "parent"), edge("grand", "father", "parent"),
                    edge("great", "grand", "parent"), edge("focus", "great", "parent"),
                    edge("focus", "child", "parent"), edge("focus", "sibling", "sibling"),
                    edge("missing", "focus", "parent"), edge("focus", "focus", "parent")]
        let tree = FamilyTreeProjection(people: people, relationships: rows)
        let first = tree.pedigree(focus: "focus")
        let shuffled = FamilyTreeProjection(people: people.reversed(), relationships: rows.reversed()).pedigree(focus: "focus")
        #expect(first.map(\.id) == shuffled.map(\.id))
        #expect(first.map(\.generation) == shuffled.map(\.generation))
        #expect(Set(first.map(\.id)) == ["focus", "father", "grand", "great", "child", "sibling"])
        #expect(first.count == 6)
        #expect(tree.edges.count == 6)
        #expect(tree.pedigree(focus: "missing").isEmpty)
    }
    @Test func branchControlsKeepSharedAncestorsAndNeutralRelatives() {
        let tree = FamilyTreeProjection(people: [person("f"), person("dad", sex: "male"), person("mom", sex: "female"), person("shared"), person("child"), person("sibling")], relationships: [
            edge("dad", "f", "parent"), edge("mom", "f", "parent", adoptive: true),
            edge("shared", "dad", "parent"), edge("shared", "mom", "parent"),
            edge("f", "child", "parent"), edge("sibling", "f", "sibling")])
        let nodes = tree.pedigree(focus: "f")
        #expect(nodes.first { $0.id == "dad" }?.branches == [.paternal])
        #expect(nodes.first { $0.id == "mom" }?.branches == [.maternal])
        #expect(nodes.first { $0.id == "shared" }?.branches == [.paternal, .maternal])
        #expect(Set(nodes.filter { $0.visible(paternal: false, maternal: true) }.map(\.id)) == ["f", "mom", "shared", "child", "sibling"])
        #expect(Set(nodes.filter { $0.visible(paternal: false, maternal: false) }.map(\.id)) == ["f", "child", "sibling"])
    }
    @Test func pedigreeUsesCanonicalCoupleGeometryAndRecordedSiblingEdges() {
        let tree = FamilyTreeProjection(people: [person("me"), person("dad", sex: "male"), person("mom", sex: "female"), person("sibling")], relationships: [
            edge("dad", "me", "parent"), edge("mom", "me", "parent", adoptive: true),
            edge("mom", "dad", "spouse"), edge("sibling", "me", "sibling")])
        let layout = tree.layout(focus: "me")
        #expect(Set(layout.nodes.map(\.id)) == ["me", "dad", "mom", "sibling"])
        #expect(layout.node("dad")?.coupleSide == .left)
        #expect(layout.node("mom")?.coupleSide == .right)
        #expect(layout.node("sibling")?.generation == 0)
        #expect(layout.edges.contains { $0.kind == .sibling && Set([$0.from, $0.to]) == ["me", "sibling"] })
        #expect(tree.layout(focus: "missing").nodes.isEmpty)
    }

    @Test func sameSexCouplesKeepRecordedHistoricalBirthOrder() {
        var older = person("z", sex: "female"), younger = person("a", sex: "female")
        older.columns["birth_date_sort"] = .string("1850-01-01")
        older.columns["birth_date"] = .string("c. 1850")
        younger.columns["birth_date_sort"] = .string("1860-01-01")
        let tree = FamilyTreeProjection(people: [younger, older], relationships: [edge("a", "z", "spouse")])
        let layout = tree.layout(focus: "a")
        #expect((layout.node("z")?.x ?? 0) < (layout.node("a")?.x ?? 0))
    }

    @Test func personSearchFindsDisconnectedPeopleAndStableFocus() {
        let tree = FamilyTreeProjection(people: [person("b", "Zoë"), person("a", "Ángela"), person("c", "Ángela")], relationships: [])
        #expect(tree.search("angela") == ["a", "c"])
        #expect(tree.search(" b ") == ["b"])
        #expect(tree.search("not recorded").isEmpty)
        #expect(tree.defaultFocus == "a")
        #expect(tree.pedigree(focus: "c").map(\.id) == ["c"])
    }
}
