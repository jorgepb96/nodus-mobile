import Foundation

/// A deterministic, cycle-safe projection of recorded genealogy edges. Unknown or
/// dangling records never become invented people, and adoption stays on the edge.
public struct FamilyTreeProjection: Sendable {
    public enum Kind: String, Sendable { case parent, spouse, sibling }
    public enum Branch: String, Sendable, Hashable { case paternal, maternal }
    public struct Edge: Sendable, Hashable, Identifiable {
        public let from: String
        public let to: String
        public let kind: Kind
        public let adoptive: Bool
        public var id: String { "\(kind.rawValue):\(from):\(to):\(adoptive)" }

        public init?(_ row: Row) {
            guard let from = row.string("from_person") ?? row.string("from_person_id"),
                  let to = row.string("to_person") ?? row.string("to_person_id"),
                  !from.isEmpty, !to.isEmpty, from != to else { return nil }
            let type = (row.string("type") ?? row.string("kind") ?? "").lowercased()
            let kind: Kind
            var a = from, b = to
            switch type {
            case "parent", "padre", "madre": kind = .parent
            case "child", "hijo", "hija": kind = .parent; a = to; b = from
            case "spouse", "partner", "conyuge", "cónyuge", "pareja": kind = .spouse
            case "sibling", "brother", "sister", "hermano", "hermana": kind = .sibling
            default: return nil
            }
            if kind != .parent, a > b { swap(&a, &b) }
            self.from = a; self.to = b; self.kind = kind
            self.adoptive = kind == .parent && row.string("subtype")?.lowercased() == "adoptive"
        }
    }
    public struct Node: Sendable, Identifiable {
        public let id: String
        /// Parents are above the focus (-1), children below (+1). Same-generation
        /// recorded spouse/sibling edges do not change the generation.
        public let generation: Int
        public let branches: Set<Branch>
        public func visible(paternal: Bool, maternal: Bool) -> Bool {
            branches.isEmpty || (paternal && branches.contains(.paternal)) || (maternal && branches.contains(.maternal))
        }
    }
    public let people: [String: Row]
    public let edges: [Edge]

    public init(people: [Row], relationships: [Row]) {
        self.people = Dictionary(people.compactMap { row in
            row.string("person_id").flatMap { $0.isEmpty ? nil : ($0, row) }
        }, uniquingKeysWith: { first, _ in first })
        let ids = Set(self.people.keys)
        self.edges = Set(relationships.compactMap(Edge.init).filter { ids.contains($0.from) && ids.contains($0.to) })
            .sorted { $0.id < $1.id }
    }

    public func parents(of id: String) -> [String] { sorted(edges.filter { $0.kind == .parent && $0.to == id }.map(\.from)) }
    public func children(of id: String) -> [String] { sorted(edges.filter { $0.kind == .parent && $0.from == id }.map(\.to)) }
    public func partners(of id: String) -> [String] { adjacent(id, kind: .spouse) }
    public func siblings(of id: String) -> [String] {
        let sharedParent = parents(of: id).flatMap { children(of: $0) }
        return sorted((sharedParent + adjacent(id, kind: .sibling)).filter { $0 != id })
    }
    public func isAdoptive(between a: String, and b: String) -> Bool {
        edges.contains { $0.adoptive && (($0.from == a && $0.to == b) || ($0.from == b && $0.to == a)) }
    }
    public func search(_ query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sorted(people.keys.filter { needle.isEmpty || (people[$0]?.text("display_name") ?? "").localizedStandardContains(needle) || $0.localizedStandardContains(needle) })
    }
    public var defaultFocus: String? {
        var degree: [String: Int] = [:]
        for edge in edges { degree[edge.from, default: 0] += 1; degree[edge.to, default: 0] += 1 }
        return sorted(Array(people.keys)).max { a, b in
            let left = degree[a, default: 0], right = degree[b, default: 0]
            return left == right ? a > b : left < right
        }
    }

    /// Walk the complete recorded component once, rather than truncating at the
    /// first three generations or recursing forever through a malformed cycle.
    public func pedigree(focus id: String) -> [Node] {
        guard people[id] != nil else { return [] }
        var generations = [id: 0], queue = [id], index = 0
        while index < queue.count {
            let current = queue[index]; index += 1
            let generation = generations[current] ?? 0
            let neighbors = parents(of: current).map { ($0, generation - 1) }
                + children(of: current).map { ($0, generation + 1) }
                + partners(of: current).map { ($0, generation) }
                + siblings(of: current).map { ($0, generation) }
            for (other, level) in neighbors where generations[other] == nil {
                generations[other] = level; queue.append(other)
            }
        }
        let roots = parents(of: id)
        let father = roots.first { people[$0]?.text("sex") == "male" }
        let mother = roots.first { people[$0]?.text("sex") == "female" }
        let remaining = roots.filter { $0 != father && $0 != mother }.sorted()
        let paternalRoot = father ?? remaining.first
        let maternalRoot = mother ?? remaining.first { $0 != paternalRoot }
        var branches: [String: Set<Branch>] = [:]
        for (root, branch) in [(paternalRoot, Branch.paternal), (maternalRoot, Branch.maternal)] {
            guard let root else { continue }
            var pending = [root], visited: Set<String> = [id], cursor = 0
            while cursor < pending.count {
                let current = pending[cursor]; cursor += 1
                guard visited.insert(current).inserted else { continue }
                branches[current, default: []].insert(branch)
                pending.append(contentsOf: parents(of: current))
            }
        }
        return sorted(Array(generations.keys)).map { Node(id: $0, generation: generations[$0] ?? 0, branches: branches[$0] ?? []) }
    }
    /// Use the existing Desktop-compatible geometry, including adjacent couples
    /// and one node per person through remarriage and pedigree collapse.
    public func layout(focus id: String, nodeWidth: Double = 156, nodeHeight: Double = 132) -> TreeLayout.Result {
        guard people[id] != nil else { return TreeLayout.compute(.init(focusId: "", parentEdges: [])) }
        return TreeLayout.compute(.init(focusId: id,
            parentEdges: edges.filter { $0.kind == .parent }.map { (parent: $0.from, child: $0.to) },
            spouseEdges: edges.filter { $0.kind == .spouse }.map { (a: $0.from, b: $0.to) },
            siblingEdges: edges.filter { $0.kind == .sibling }.map { (a: $0.from, b: $0.to) },
            persons: people.keys.sorted().map { .init(id: $0, sex: people[$0]?.text("sex"), birthYear: birthYear(people[$0])) },
            nodeWidth: nodeWidth, nodeHeight: nodeHeight, hGap: 28, vGap: 44))
    }

    private func birthYear(_ row: Row?) -> Int? {
        // Use the stored historical sort key, not a new guess at a fuzzy display date.
        guard let key = row?.text("birth_date_sort"), key.count >= 4,
              let year = Int(key.prefix(4)), (1...3000).contains(year) else { return nil }
        return year
    }

    private func adjacent(_ id: String, kind: Kind) -> [String] {
        sorted(edges.filter { $0.kind == kind }.compactMap { $0.from == id ? $0.to : $0.to == id ? $0.from : nil })
    }
    private func sorted(_ ids: [String]) -> [String] {
        Set(ids).sorted { a, b in
            let left = people[a]?.text("display_name") ?? a, right = people[b]?.text("display_name") ?? b
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
    }
}
