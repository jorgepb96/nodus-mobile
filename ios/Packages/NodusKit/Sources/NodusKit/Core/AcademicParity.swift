import Foundation

// MARK: - Shared academic graph

public enum AcademicGraphLens: String, Sendable, Codable, CaseIterable {
    case ideas, authors
}

public struct AcademicGraphNode: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let label: String
    public let subtitle: String
    public let kind: String
    public let weight: Double
    public let group: String?
    public let read: Bool
}

public struct AcademicGraphEdge: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let source: String
    public let target: String
    public let kind: String
    public let weight: Double
}

public struct AcademicGraph: Sendable, Hashable, Codable {
    public let lens: AcademicGraphLens
    public let nodes: [AcademicGraphNode]
    public let edges: [AcademicGraphEdge]

    public init(lens: AcademicGraphLens, nodes: [AcademicGraphNode], edges: [AcademicGraphEdge]) {
        self.lens = lens
        self.nodes = nodes
        self.edges = edges
    }
}

public enum AcademicGraphProjection {
    public static func build(
        from tables: [String: [Row]],
        lens: AcademicGraphLens,
        minimumWeight: Double = 0,
        query: String = "",
        limit: Int = 650
    ) -> AcademicGraph {
        switch lens {
        case .ideas: ideaGraph(from: tables, minimumWeight: minimumWeight, query: query, limit: limit)
        case .authors: authorGraph(from: tables, minimumWeight: minimumWeight, query: query, limit: limit)
        }
    }

    private static func ideaGraph(
        from tables: [String: [Row]], minimumWeight: Double, query: String, limit: Int
    ) -> AcademicGraph {
        let ideas = Dictionary(uniqueKeysWithValues: (tables["ideas"] ?? []).compactMap { row -> (String, Row)? in
            guard let id = row.string("global_id") else { return nil }; return (id, row)
        })
        let themeLabels = Dictionary(uniqueKeysWithValues: (tables["themes"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("theme_id"), let label = row.text("label") else { return nil }; return (id, label)
        })
        var themesByIdea: [String: [String]] = [:]
        for row in tables["idea_theme_links"] ?? [] {
            guard let idea = row.string("global_id"), let theme = row.string("theme_id").flatMap({ themeLabels[$0] }) else { continue }
            if !(themesByIdea[idea] ?? []).contains(theme) { themesByIdea[idea, default: []].append(theme) }
        }
        var worksByIdea: [String: Set<String>] = [:]
        for row in tables["idea_occurrences"] ?? [] {
            guard let idea = row.string("global_id"), let work = row.string("nodus_id") else { continue }
            worksByIdea[idea, default: []].insert(work)
        }
        let readWorks = Set((tables["works"] ?? []).filter { $0.bool("read_tag") == true }.compactMap { $0.string("nodus_id") })
        let visible = AcademicWorkspaceProjection.visibleEdges(in: tables).compactMap { row -> AcademicGraphEdge? in
            guard let source = row.string("from_id"), let target = row.string("to_id"), ideas[source] != nil, ideas[target] != nil else { return nil }
            let weight = row.double("confidence") ?? 0
            guard weight >= minimumWeight else { return nil }
            return AcademicGraphEdge(
                id: row.string("id") ?? "\(source):\(target):\(row.string("type") ?? "related")",
                source: source, target: target, kind: row.string("type") ?? "related", weight: weight
            )
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var degree: [String: Int] = [:]
        for edge in visible { degree[edge.source, default: 0] += 1; degree[edge.target, default: 0] += 1 }
        let ranked = ideas.compactMap { id, row -> AcademicGraphNode? in
            let label = row.text("label") ?? id, statement = row.text("statement") ?? ""
            guard needle.isEmpty || "\(label)\n\(statement)".lowercased().contains(needle) else { return nil }
            let works = worksByIdea[id] ?? []
            return AcademicGraphNode(
                id: id, label: label, subtitle: statement, kind: row.string("type") ?? "claim",
                weight: Double(max(1, degree[id, default: 0])) + Double(works.count) * 0.35,
                group: themesByIdea[id]?.first,
                read: !works.isEmpty && works.isSubset(of: readWorks)
            )
        }.sorted { $0.weight == $1.weight ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.weight > $1.weight }
        let kept = Array(ranked.prefix(max(1, limit))), ids = Set(kept.map(\.id))
        return AcademicGraph(lens: .ideas, nodes: kept, edges: visible.filter { ids.contains($0.source) && ids.contains($0.target) })
    }

    private static func authorGraph(
        from tables: [String: [Row]], minimumWeight: Double, query: String, limit: Int
    ) -> AcademicGraph {
        let authors = Dictionary(uniqueKeysWithValues: (tables["authors"] ?? []).compactMap { row -> (String, Row)? in
            guard let id = row.string("author_id") else { return nil }; return (id, row)
        })
        var worksByAuthor: [String: Set<String>] = [:]
        for row in tables["work_authors"] ?? [] {
            guard let author = row.string("author_id"), let work = row.string("nodus_id") else { continue }
            worksByAuthor[author, default: []].insert(work)
        }
        let readWorks = Set((tables["works"] ?? []).filter { $0.bool("read_tag") == true }.compactMap { $0.string("nodus_id") })
        let edges = (tables["author_relations"] ?? []).compactMap { row -> AcademicGraphEdge? in
            guard let source = row.string("from_author"), let target = row.string("to_author"), authors[source] != nil, authors[target] != nil else { return nil }
            let weight = min(1, row.double("weight") ?? 0)
            guard weight >= minimumWeight else { return nil }
            return AcademicGraphEdge(
                id: "\(source):\(target):\(row.string("type") ?? "related")", source: source, target: target,
                kind: row.string("type") ?? "related", weight: weight
            )
        }
        var degree: [String: Int] = [:]
        for edge in edges { degree[edge.source, default: 0] += 1; degree[edge.target, default: 0] += 1 }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ranked = authors.compactMap { id, row -> AcademicGraphNode? in
            let label = row.text("name") ?? row.text("display_name") ?? id
            guard needle.isEmpty || label.lowercased().contains(needle) else { return nil }
            let works = worksByAuthor[id] ?? []
            return AcademicGraphNode(
                id: id, label: label, subtitle: row.text("affiliation") ?? "\(works.count) works", kind: "author",
                weight: Double(max(1, degree[id, default: 0])) + Double(works.count) * 0.2, group: nil,
                read: !works.isEmpty && works.isSubset(of: readWorks)
            )
        }.sorted { $0.weight == $1.weight ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.weight > $1.weight }
        let kept = Array(ranked.prefix(max(1, limit))), ids = Set(kept.map(\.id))
        return AcademicGraph(lens: .authors, nodes: kept, edges: edges.filter { ids.contains($0.source) && ids.contains($0.target) })
    }
}

// MARK: - Portable reading path

public enum AcademicReadingStrategy: String, Sendable, Codable, CaseIterable, Identifiable {
    case researchRelevance = "research_relevance"
    case gaps, foundational, recent
    case connectedAuthors = "connected_authors"
    case bridges
    public var id: String { rawValue }
}

public struct AcademicReadingEntry: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let authors: [String]
    public let year: Int?
    public let themes: [String]
    public let read: Bool
    public let analyzed: Bool
    public let ideaCount: Int
    public let gapCount: Int
    public let contradictionCount: Int
    public let priority: Int
    public let reason: String
    public let phase: String
}

public struct AcademicReadingPhase: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let objective: String
    public let entries: [AcademicReadingEntry]
}

public struct AcademicReadingPlan: Sendable, Hashable, Codable {
    public let strategy: AcademicReadingStrategy
    public let totalWorks: Int
    public let shownWorks: Int
    public let readCount: Int
    public let analyzedCount: Int
    public let phases: [AcademicReadingPhase]
}

public enum AcademicReadingProjection {
    public static func build(
        from tables: [String: [Row]], strategy: AcademicReadingStrategy,
        researchBrief: String = "", includeRead: Bool = true, limit: Int = 72
    ) -> AcademicReadingPlan {
        let works = (tables["works"] ?? []).filter { $0.bool("archived") != true }
        let themeLabels = Dictionary(uniqueKeysWithValues: (tables["themes"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("theme_id"), let label = row.text("label") else { return nil }; return (id, label)
        })
        var themesByWork: [String: Set<String>] = [:]
        for row in tables["work_themes"] ?? [] {
            guard let work = row.string("nodus_id"), let theme = row.string("theme_id").flatMap({ themeLabels[$0] }) else { continue }
            themesByWork[work, default: []].insert(theme)
        }
        var ideasByWork: [String: Set<String>] = [:]
        for row in tables["idea_occurrences"] ?? [] {
            guard let work = row.string("nodus_id"), let idea = row.string("global_id") else { continue }
            ideasByWork[work, default: []].insert(idea)
        }
        var gapsByWork: [String: [String]] = [:]
        for row in tables["gaps"] ?? [] where row.string("nodus_id") != nil {
            gapsByWork[row.string("nodus_id")!, default: []].append(row.text("statement") ?? "")
        }
        var relationsByWork: [String: (all: Int, contradictions: Int)] = [:]
        for row in AcademicWorkspaceProjection.visibleEdges(in: tables) {
            guard let work = row.string("source_work") else { continue }
            relationsByWork[work, default: (all: 0, contradictions: 0)].all += 1
            if ["contradicts", "refutes"].contains(row.string("type") ?? "") {
                relationsByWork[work, default: (all: 0, contradictions: 0)].contradictions += 1
            }
        }
        var authorsByWork: [String: [String]] = [:]
        let authorNames = Dictionary(uniqueKeysWithValues: (tables["authors"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("author_id") else { return nil }; return (id, row.text("name") ?? id)
        })
        for row in tables["work_authors"] ?? [] {
            guard let work = row.string("nodus_id"), let author = row.string("author_id").flatMap({ authorNames[$0] }) else { continue }
            authorsByWork[work, default: []].append(author)
        }
        let years = works.compactMap { $0.int("year") }, minYear = years.min() ?? 0, maxYear = years.max() ?? max(minYear, 1)
        let briefTokens = Set(researchBrief.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 })
        var scored: [(AcademicReadingEntry, Double, Double, Double, Double)] = works.compactMap { row in
            guard let id = row.string("nodus_id") else { return nil }
            let title = row.text("title") ?? id, themes = Array(themesByWork[id] ?? []).sorted()
            let ideas = ideasByWork[id]?.count ?? 0, gaps = gapsByWork[id]?.count ?? 0
            let relation = relationsByWork[id] ?? (0, 0), year = row.int("year")
            let read = row.bool("read_tag") == true
            guard includeRead || !read else { return nil }
            let recency = year.map { Double($0 - minYear) / Double(max(1, maxYear - minYear)) } ?? 0.2
            let foundational = min(1, Double(ideas) * 0.08 + Double(relation.all) * 0.04 + (1 - recency) * 0.34)
            let gap = min(1, Double(gaps) * 0.3 + Double(relation.contradictions) * 0.12)
            let bridge = min(1, Double(themes.count) * 0.16 + Double(relation.all) * 0.045)
            let haystack = "\(title) \(themes.joined(separator: " ")) \((authorsByWork[id] ?? []).joined(separator: " "))".lowercased()
            let interest = briefTokens.isEmpty ? min(1, Double(themes.count) * 0.15) : Double(briefTokens.filter(haystack.contains).count) / Double(max(1, briefTokens.count))
            let authorConnected = min(1, Double(authorsByWork[id]?.count ?? 0) * 0.22 + Double(relation.all) * 0.025)
            let score: Double = switch strategy {
            case .gaps: gap * 0.62 + interest * 0.18 + bridge * 0.2
            case .foundational: foundational * 0.7 + interest * 0.2 + bridge * 0.1
            case .recent: recency * 0.7 + interest * 0.2 + gap * 0.1
            case .connectedAuthors: authorConnected * 0.62 + bridge * 0.23 + interest * 0.15
            case .bridges: bridge * 0.62 + interest * 0.23 + gap * 0.15
            case .researchRelevance: interest * 0.34 + gap * 0.24 + foundational * 0.2 + bridge * 0.14 + (read ? 0 : 0.08)
            }
            let analyzed = (row.string("deep_status") == "done") && ideas > 0
            var reasons: [String] = [read ? "Already read." : "Pending reading."]
            if ideas > 0 { reasons.append("\(ideas) grounded ideas.") }
            if gaps > 0 { reasons.append("\(gaps) research gaps.") }
            if relation.contradictions > 0 { reasons.append("\(relation.contradictions) contradictions.") }
            if bridge >= 0.45 { reasons.append("Connects several graph regions.") }
            let phase = foundational >= 0.45 ? "foundational" : gap >= 0.3 ? "gaps" : relation.contradictions > 0 ? "contrasts" : analyzed ? "secondary" : "pending"
            return (AcademicReadingEntry(
                id: id, title: title, authors: authorsByWork[id] ?? Self.authors(row), year: year,
                themes: themes, read: read, analyzed: analyzed, ideaCount: ideas, gapCount: gaps,
                contradictionCount: relation.contradictions, priority: Int((score * 100).rounded()),
                reason: reasons.joined(separator: " "), phase: phase
            ), score, foundational, gap, bridge)
        }
        scored.sort { $0.1 == $1.1 ? $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending : $0.1 > $1.1 }
        let kept = Array(scored.prefix(min(max(18, limit), 180))).map(\.0)
        let definitions: [(String, String, String)] = [
            ("foundational", "Foundational readings", "Conceptual bases and intellectual dependencies to read first."),
            ("gaps", "Research gaps", "Works most useful for delimiting gaps in the corpus."),
            ("contrasts", "Contrasts and contradictions", "Positions that put existing claims under pressure."),
            ("secondary", "Secondary themes", "Readings that broaden the map without saturating one line."),
            ("pending", "Pending analysis", "Works that need deeper processing before their role is settled."),
        ]
        let phases = definitions.compactMap { id, title, objective -> AcademicReadingPhase? in
            let entries = kept.filter { $0.phase == id }
            return entries.isEmpty ? nil : AcademicReadingPhase(id: id, title: title, objective: objective, entries: entries)
        }
        return AcademicReadingPlan(
            strategy: strategy, totalWorks: works.count, shownWorks: kept.count,
            readCount: works.filter { $0.bool("read_tag") == true }.count,
            analyzedCount: works.filter { $0.string("deep_status") == "done" }.count, phases: phases
        )
    }

    private static func authors(_ row: Row) -> [String] {
        guard let raw = row.string("authors_json"), let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        return value.arrayValue?.compactMap(\.stringValue) ?? []
    }
}

// MARK: - Hypothesis dossiers

public enum AcademicHypothesisMode: String, Sendable, Codable, CaseIterable, Identifiable {
    case exploratory, causal, comparative, methodological, intervention
    public var id: String { rawValue }
}

public struct AcademicHypothesisEvidence: Sendable, Hashable, Codable, Identifiable {
    public var id: String { "\(kind):\(refId)" }
    public let kind: String
    public let refId: String
    public let label: String
    public let role: String
}

public struct AcademicHypothesisCandidate: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let hypothesis: String
    public let rationale: String
    public let maturity: String
    public let score: Int
    public let variables: [String]
    public let methods: [String]
    public let predictions: [String]
    public let counterArguments: [String]
    public let nextSteps: [String]
    public let evidence: [AcademicHypothesisEvidence]
}

public enum AcademicHypothesisProjection {
    public static func generate(
        from tables: [String: [Row]], objective: String, mode: AcademicHypothesisMode, maxCandidates: Int = 5
    ) -> [AcademicHypothesisCandidate] {
        let ideas = Dictionary(uniqueKeysWithValues: (tables["ideas"] ?? []).compactMap { row -> (String, Row)? in
            guard let id = row.string("global_id") else { return nil }; return (id, row)
        })
        let works = Dictionary(uniqueKeysWithValues: (tables["works"] ?? []).compactMap { row -> (String, Row)? in
            guard let id = row.string("nodus_id") else { return nil }; return (id, row)
        })
        let gaps = (tables["gaps"] ?? []).sorted { ($0.double("confidence") ?? 0) > ($1.double("confidence") ?? 0) }
        let contradictions = AcademicWorkspaceProjection.visibleEdges(in: tables).filter { ["contradicts", "refutes"].contains($0.string("type") ?? "") }
        let count = min(max(1, maxCandidates), 8)
        return gaps.prefix(count).enumerated().map { index, gap in
            let gapId = gap.string("id") ?? "gap-\(index)", ideaId = gap.string("related_idea")
            let idea = ideaId.flatMap { ideas[$0] }, workId = gap.string("nodus_id"), work = workId.flatMap { works[$0] }
            let statement = gap.text("statement") ?? "Unresolved boundary in the corpus"
            let ideaLabel = idea?.text("label") ?? "the observed mechanism"
            let modeVerb: String = switch mode {
            case .causal: "causally changes"
            case .comparative: "differs across cases in"
            case .methodological: "becomes observable when measuring"
            case .intervention: "can be altered by intervening on"
            case .exploratory: "is systematically associated with"
            }
            var evidence = [AcademicHypothesisEvidence(kind: "gap", refId: gapId, label: statement, role: "gap")]
            if let ideaId, let idea { evidence.append(.init(kind: "idea", refId: ideaId, label: idea.text("label") ?? ideaId, role: "support")) }
            if let workId, let work { evidence.append(.init(kind: "work", refId: workId, label: work.text("title") ?? workId, role: "source")) }
            if let edge = contradictions.first(where: { $0.string("from_id") == ideaId || $0.string("to_id") == ideaId }), let edgeId = edge.string("id") {
                evidence.append(.init(kind: "debate", refId: edgeId, label: edge.string("type") ?? "contradiction", role: "contrast"))
            }
            let support = evidence.count, score = min(96, 46 + support * 10 + Int((gap.double("confidence") ?? 0) * 20))
            return AcademicHypothesisCandidate(
                id: "hypothesis:\(gapId):\(mode.rawValue)", title: "\(ideaLabel): testable boundary \(index + 1)",
                hypothesis: "Within \(objective.isEmpty ? "the target corpus" : objective), \(ideaLabel) \(modeVerb) the outcome delimited by: \(statement)",
                rationale: "This candidate starts from a published gap and keeps every supporting or contrasting reference attached.",
                maturity: support >= 3 ? "testable" : support == 2 ? "promising" : "seed", score: score,
                variables: [ideaLabel, statement],
                methods: mode == .comparative ? ["Comparative case design", "Matched evidence matrix"] : ["Operationalise variables", "Triangulate corpus evidence"],
                predictions: ["The relationship should recur in at least two independent sources.", "Contrasting cases should weaken or reverse the expected pattern."],
                counterArguments: ["The observed association may be an artefact of source selection.", "The corpus may not yet represent the relevant negative cases."],
                nextSteps: ["Define inclusion and falsification criteria.", "Collect a contrasting passage and one independent supporting work."],
                evidence: evidence
            )
        }
    }
}

// MARK: - Published writing and projects

public struct AcademicWritingDraftSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let kind: String
    public let objective: String
    public let abstract: String
    public let markdown: String
    public let createdAt: String?
    public let updatedAt: String?
}

public struct AcademicProjectSummary: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let kind: String
    public let status: String
    public let brief: String
    public let targetWords: Int?
    public let updatedAt: String?
    public let sections: [AcademicProjectSection]
    public let chapters: [AcademicProjectChapter]
    public let links: [AcademicProjectLink]
}

public struct AcademicProjectSection: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let role: String
    public let status: String
    public let targetWords: Int?
    public let order: Int
}

public struct AcademicProjectChapter: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let markdown: String
    public let wordCount: Int
    public let updatedAt: String?
}

public struct AcademicProjectLink: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let sectionId: String?
    public let kind: String
    public let refId: String
    public let label: String
    public let role: String
}

public enum AcademicAuthoredProjection {
    public static func writingDrafts(from tables: [String: [Row]]) -> [AcademicWritingDraftSummary] {
        (tables["writing_saved_drafts"] ?? []).compactMap { row in
            guard let id = row.string("id"), let draft = object(row, "draft_json") else { return nil }
            let brief = object(row, "brief_json") ?? draft["brief"]?.objectValue ?? [:]
            let kind = brief["kind"]?.stringValue ?? "literature_review"
            guard kind != "deep_research" else { return nil }
            return AcademicWritingDraftSummary(
                id: id, title: row.text("title") ?? draft["title"]?.stringValue ?? id, kind: kind,
                objective: brief["objective"]?.stringValue ?? "", abstract: draft["abstract"]?.stringValue ?? "",
                markdown: draft["draftMarkdown"]?.stringValue ?? "", createdAt: row.string("created_at"), updatedAt: row.string("updated_at")
            )
        }.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    public static func projects(from tables: [String: [Row]]) -> [AcademicProjectSummary] {
        let sections = Dictionary(grouping: tables["project_sections"] ?? []) { $0.string("project_id") ?? "" }
        let chapters = Dictionary(grouping: tables["project_chapters"] ?? []) { $0.string("project_id") ?? "" }
        let links = Dictionary(grouping: tables["project_links"] ?? []) { $0.string("project_id") ?? "" }
        return (tables["projects"] ?? []).compactMap { row -> AcademicProjectSummary? in
            guard let id = row.string("id") else { return nil }
            return AcademicProjectSummary(
                id: id, title: row.text("title") ?? id, kind: row.string("kind") ?? "other", status: row.string("status") ?? "active",
                brief: row.text("brief") ?? "", targetWords: row.int("target_words"), updatedAt: row.string("updated_at"),
                sections: (sections[id] ?? []).map { section in
                    AcademicProjectSection(
                        id: section.string("id") ?? UUID().uuidString, title: section.text("title") ?? "Section",
                        role: section.string("role") ?? "custom", status: section.string("status") ?? "empty",
                        targetWords: section.int("target_words"), order: section.int("order_idx") ?? 0
                    )
                }.sorted { $0.order < $1.order },
                chapters: (chapters[id] ?? []).map { chapter in
                    AcademicProjectChapter(
                        id: chapter.string("id") ?? UUID().uuidString, title: chapter.text("title") ?? "Chapter",
                        markdown: chapter.text("current_markdown") ?? "", wordCount: chapter.int("word_count") ?? 0,
                        updatedAt: chapter.string("updated_at")
                    )
                }.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") },
                links: (links[id] ?? []).map { link in
                    AcademicProjectLink(
                        id: link.string("id") ?? UUID().uuidString, sectionId: link.string("section_id"),
                        kind: link.string("kind") ?? "note", refId: link.string("ref_id") ?? "",
                        label: link.text("label") ?? link.string("ref_id") ?? "Reference", role: link.string("role") ?? "context"
                    )
                }
            )
        }.sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    private static func object(_ row: Row, _ key: String) -> [String: JSONValue]? {
        guard let raw = row.string(key), let data = raw.data(using: .utf8) else { return row.columns[key]?.objectValue }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
    }
}
