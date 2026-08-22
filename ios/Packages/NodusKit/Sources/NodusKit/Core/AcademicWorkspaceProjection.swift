import CryptoKit
import Foundation

/// Swift counterpart of `server/lib/core/academicWorkspace.mjs`.
///
/// The example vault and an offline mirror have the same immutable tables as the server. These
/// projections keep their catalogues, dossiers, synthesis matrix and route ranking identical to
/// the online contract instead of maintaining a simplified demo-only surface.
public enum AcademicWorkspaceProjection {
    public static let tableNames = [
        "works", "authors", "work_authors", "zotero_tags", "work_zotero_tags", "themes",
        "ideas", "idea_occurrences", "idea_theme_links", "evidence", "edges", "edge_feedback",
        "author_relations", "author_dossier_synthesis", "synthesis_matrix_cell",
    ]

    private static let ideaTypes = Set(["claim", "finding", "construct", "method", "framework"])
    private static let debateRelations = Set(["contradicts", "refutes"])

    private struct Attribution: Hashable {
        let workId: String
        let authorId: String
        let role: String
        let basis: String
    }

    public static func visibleEdges(in tables: [String: [Row]]) -> [Row] {
        var rejected = Set<String>()
        for row in tables["edge_feedback"] ?? [] where row.string("verdict") == "rejected" {
            guard let type = row.string("type"), let from = row.string("from_id"), let to = row.string("to_id") else { continue }
            rejected.insert("\(type)\0\(from)\0\(to)")
            rejected.insert("\(type)\0\(to)\0\(from)")
        }
        return (tables["edges"] ?? []).filter { edge in
            guard edge.string("type") != "contains",
                  let type = edge.string("type"), let from = edge.string("from_id"), let to = edge.string("to_id")
            else { return false }
            return !rejected.contains("\(type)\0\(from)\0\(to)")
        }
    }

    public static func ideaPage(
        in tables: [String: [Row]],
        query: String = "",
        type: String = "",
        sort: IdeaWorkspaceSort = .label,
        limit: Int = 80,
        offset: Int = 0,
        revision: String? = nil
    ) -> IdeaWorkspacePage {
        let works = Dictionary(uniqueKeysWithValues: (tables["works"] ?? []).compactMap { row in
            row.string("nodus_id").map { ($0, row) }
        })
        let occurrences = (tables["idea_occurrences"] ?? []).filter { occurrence in
            guard let id = occurrence.string("nodus_id"), let work = works[id], isLive(work) else { return false }
            return work.string("deep_status").map { $0 == "done" } ?? true
        }
        let byIdea = Dictionary(grouping: occurrences) { $0.string("global_id") ?? "" }
        var connectionCount: [String: Int] = [:]
        for edge in visibleEdges(in: tables) {
            for id in [edge.string("from_id"), edge.string("to_id")].compactMap({ $0 }) {
                connectionCount[id, default: 0] += 1
            }
        }
        let themeNames: [String: String] = Dictionary(uniqueKeysWithValues: (tables["themes"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("theme_id"), let label = row.text("label") else { return nil }
            return (id, label)
        })
        var themesByIdea: [String: Set<String>] = [:]
        for link in tables["idea_theme_links"] ?? [] {
            guard let ideaId = link.string("global_id"), let themeId = link.string("theme_id"), let label = themeNames[themeId] else { continue }
            themesByIdea[ideaId, default: []].insert(label)
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items = (tables["ideas"] ?? []).compactMap { idea -> IdeaWorkspaceItem? in
            guard let id = idea.string("global_id"), let occurrences = byIdea[id], !occurrences.isEmpty else { return nil }
            let kind = ideaTypes.contains(idea.string("type") ?? "") ? idea.string("type")! : "claim"
            let label = idea.text("label") ?? id
            let statement = idea.text("statement") ?? ""
            guard type.isEmpty || kind == type else { return nil }
            guard needle.isEmpty || "\(label)\n\(statement)".lowercased().contains(needle) else { return nil }
            return IdeaWorkspaceItem(
                id: id,
                label: label,
                type: kind,
                statement: statement,
                workCount: Set(occurrences.compactMap { $0.string("nodus_id") }).count,
                themes: Array(themesByIdea[id] ?? []).sorted(by: localizedAscending),
                maxConfidence: occurrences.compactMap { $0.double("confidence") }.max() ?? 0,
                connectionCount: connectionCount[id, default: 0]
            )
        }
        items.sort { left, right in
            switch sort {
            case .type: return left.type == right.type ? localizedAscending(left.label, right.label) : localizedAscending(left.type, right.type)
            case .works: return left.workCount == right.workCount ? localizedAscending(left.label, right.label) : left.workCount > right.workCount
            case .connections: return left.connectionCount == right.connectionCount ? localizedAscending(left.label, right.label) : left.connectionCount > right.connectionCount
            case .confidence: return left.maxConfidence == right.maxConfidence ? localizedAscending(left.label, right.label) : left.maxConfidence > right.maxConfidence
            case .label: return localizedAscending(left.label, right.label)
            }
        }
        let boundedOffset = max(0, offset)
        let boundedLimit = min(max(1, limit), 200)
        let slice = boundedOffset < items.count ? Array(items[boundedOffset..<min(items.count, boundedOffset + boundedLimit)]) : []
        return IdeaWorkspacePage(
            items: slice,
            total: items.count,
            offset: boundedOffset,
            limit: boundedLimit,
            hasMore: boundedOffset + slice.count < items.count,
            revision: revision
        )
    }

    public static func authorPage(
        in tables: [String: [Row]],
        query: String = "",
        sort: AuthorWorkspaceSort = .surname,
        synthesis: AuthorSynthesisFilter = .all,
        limit: Int = 80,
        offset: Int = 0,
        revision: String? = nil
    ) -> AuthorWorkspacePage {
        var items = authorSummaries(in: tables)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !needle.isEmpty {
            items = items.filter { "\($0.fullName)\n\($0.name)".lowercased().contains(needle) }
        }
        switch synthesis {
        case .with: items.removeAll { !$0.hasSynthesis }
        case .without: items.removeAll { $0.hasSynthesis }
        case .all: break
        }
        items.sort { left, right in
            switch sort {
            case .name:
                return left.firstName == right.firstName ? localizedAscending(left.lastName, right.lastName) : localizedAscending(left.firstName, right.firstName)
            case .works:
                return left.workCount == right.workCount ? localizedAscending(left.lastName, right.lastName) : left.workCount > right.workCount
            case .ideas:
                return left.ideaCount == right.ideaCount ? localizedAscending(left.lastName, right.lastName) : left.ideaCount > right.ideaCount
            case .connections:
                return left.relationCount == right.relationCount ? localizedAscending(left.lastName, right.lastName) : left.relationCount > right.relationCount
            case .surname:
                return left.lastName == right.lastName ? localizedAscending(left.firstName, right.firstName) : localizedAscending(left.lastName, right.lastName)
            }
        }
        let boundedOffset = max(0, offset)
        let boundedLimit = min(max(1, limit), 100)
        let slice = boundedOffset < items.count ? Array(items[boundedOffset..<min(items.count, boundedOffset + boundedLimit)]) : []
        return AuthorWorkspacePage(
            items: slice,
            total: items.count,
            offset: boundedOffset,
            limit: boundedLimit,
            hasMore: boundedOffset + slice.count < items.count,
            revision: revision
        )
    }

    public static func authorDossier(in tables: [String: [Row]], authorId: String) -> AuthorWorkspaceDossier? {
        guard let author = (tables["authors"] ?? []).first(where: { $0.string("author_id") == authorId }) else { return nil }
        let worksById = Dictionary(uniqueKeysWithValues: (tables["works"] ?? []).filter(isLive).compactMap { row in
            row.string("nodus_id").map { ($0, row) }
        })
        let credits = (tables["work_authors"] ?? []).filter { $0.string("author_id") == authorId && worksById[$0.string("nodus_id") ?? ""] != nil }
        let allAttributions = attributions(in: tables).filter { worksById[$0.workId] != nil }
        let mine = allAttributions.filter { $0.authorId == authorId }
        let attributedIds = Set(mine.map(\.workId))
        let basisByWork = Dictionary(uniqueKeysWithValues: mine.map { ($0.workId, $0.basis) })
        let ideasById = Dictionary(uniqueKeysWithValues: (tables["ideas"] ?? []).compactMap { row in row.string("global_id").map { ($0, row) } })
        let themeNames: [String: String] = Dictionary(uniqueKeysWithValues: (tables["themes"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("theme_id"), let label = row.text("label") else { return nil }
            return (id, label)
        })
        var themesByIdea: [String: Set<String>] = [:]
        for link in tables["idea_theme_links"] ?? [] where attributedIds.contains(link.string("nodus_id") ?? "") {
            guard let id = link.string("global_id"), let themeId = link.string("theme_id"), let label = themeNames[themeId] else { continue }
            themesByIdea[id, default: []].insert(label)
        }
        let evidence = tables["evidence"] ?? []
        let occurrences = (tables["idea_occurrences"] ?? [])
            .filter { attributedIds.contains($0.string("nodus_id") ?? "") && ideasById[$0.string("global_id") ?? ""] != nil }
            .sorted { left, right in
                let principal = (right.string("role") == "principal" ? 1 : 0) - (left.string("role") == "principal" ? 1 : 0)
                return principal == 0 ? (left.double("confidence") ?? 0) > (right.double("confidence") ?? 0) : principal < 0
            }
        var seen = Set<String>()
        var ideas: [AuthorDossierIdea] = []
        for occurrence in occurrences {
            guard let id = occurrence.string("global_id"), !seen.contains(id), let idea = ideasById[id], let workId = occurrence.string("nodus_id") else { continue }
            seen.insert(id)
            ideas.append(AuthorDossierIdea(
                globalId: id,
                type: ideaTypes.contains(idea.string("type") ?? "") ? idea.string("type")! : "claim",
                label: idea.text("label") ?? id,
                statement: idea.text("statement") ?? "",
                development: occurrence.text("development") ?? "",
                role: occurrence.string("role") == "principal" ? "principal" : "secondary",
                confidence: occurrence.double("confidence") ?? 0,
                workId: workId,
                workTitle: worksById[workId]?.text("title") ?? workId,
                year: worksById[workId]?.int("year"),
                provisional: basisByWork[workId] == "editor_only",
                themes: Array(themesByIdea[id] ?? []).sorted(by: localizedAscending),
                evidence: evidence.filter { $0.string("global_id") == id && $0.string("nodus_id") == workId }
            ))
        }

        let authorsById = Dictionary(uniqueKeysWithValues: (tables["authors"] ?? []).compactMap { row in row.string("author_id").map { ($0, row) } })
        let themeSets = authorThemeSets(in: tables, attributions: allAttributions)
        let ownThemes = themeSets[authorId] ?? []
        var relationMap: [String: AuthorDossierRelation] = [:]
        for relation in tables["author_relations"] ?? [] {
            let from = relation.string("from_author") ?? "", to = relation.string("to_author") ?? ""
            guard from == authorId || to == authorId else { continue }
            let otherId = from == authorId ? to : from
            guard !otherId.isEmpty, otherId != authorId else { continue }
            let type = relation.string("type") ?? "related", key = "\(otherId)::\(type)"
            let prior = relationMap[key]
            relationMap[key] = AuthorDossierRelation(
                authorId: otherId,
                name: authorsById[otherId]?.text("name") ?? authorsById[otherId]?.text("display_name") ?? otherId,
                type: type,
                weight: (prior?.weight ?? 0) + (relation.double("weight") ?? 0),
                sharedThemes: Array((themeSets[otherId] ?? []).intersection(ownThemes)).sorted(by: localizedAscending)
            )
        }
        let relations = relationMap.values.sorted { $0.weight == $1.weight ? localizedAscending($0.name, $1.name) : $0.weight > $1.weight }
        var themeFrequency: [String: Int] = [:]
        for idea in ideas { for theme in idea.themes { themeFrequency[theme, default: 0] += 1 } }
        let themes = themeFrequency.sorted { $0.value == $1.value ? localizedAscending($0.key, $1.key) : $0.value > $1.value }.map(\.key)
        let fingerprint = sha1("\(ideas.map(\.globalId).sorted().joined(separator: ","))|\(relations.map { "\($0.authorId):\($0.type)" }.sorted().joined(separator: ","))")
        let synthesis = (tables["author_dossier_synthesis"] ?? []).first { $0.string("author_id") == authorId }.map {
            synthesisValue($0, fingerprint: fingerprint)
        }
        let dossierWorks = credits.compactMap { credit -> AuthorDossierWork? in
            guard let id = credit.string("nodus_id"), let work = worksById[id] else { return nil }
            return workValue(work, credit: credit, attributed: attributedIds.contains(id))
        }
        let parts = splitName(author.text("name") ?? author.text("display_name") ?? authorId)
        return AuthorWorkspaceDossier(
            author: author,
            fullName: parts.full, firstName: parts.first, lastName: parts.last,
            works: dossierWorks.filter { $0.role != "editor" },
            editedWorks: dossierWorks.filter { $0.role == "editor" },
            ideas: ideas, relations: relations, themes: themes, synthesis: synthesis
        )
    }

    public static func synthesisMatrix(in tables: [String: [Row]]) -> SynthesisMatrix {
        let liveIds = Set((tables["works"] ?? []).filter(isLive).compactMap { $0.string("nodus_id") })
        let attributions = attributions(in: tables).filter { liveIds.contains($0.workId) }
        let ideasById = Dictionary(uniqueKeysWithValues: (tables["ideas"] ?? []).compactMap { row in row.string("global_id").map { ($0, row) } })
        var occurrenceIdsByWork: [String: Set<String>] = [:]
        for occurrence in tables["idea_occurrences"] ?? [] {
            guard let work = occurrence.string("nodus_id"), let idea = occurrence.string("global_id") else { continue }
            occurrenceIdsByWork[work, default: []].insert(idea)
        }
        var authorIdeas: [String: Set<String>] = [:], authorWorks: [String: Set<String>] = [:]
        for attribution in attributions {
            authorIdeas[attribution.authorId, default: []].formUnion(occurrenceIdsByWork[attribution.workId] ?? [])
            authorWorks[attribution.authorId, default: []].insert(attribution.workId)
        }
        let authorsById = Dictionary(uniqueKeysWithValues: (tables["authors"] ?? []).compactMap { row in row.string("author_id").map { ($0, row) } })
        let selectedAuthors = authorIdeas.map { id, ideas in
            (SynthesisMatrixAuthor(authorId: id, name: authorsById[id]?.text("name") ?? authorsById[id]?.text("display_name") ?? id, workCount: authorWorks[id]?.count ?? 0), ideas.count)
        }.sorted { left, right in left.1 == right.1 ? localizedAscending(left.0.name, right.0.name) : left.1 > right.1 }.prefix(40).map(\.0)
        let selectedAuthorIds = Set(selectedAuthors.map(\.authorId))
        let themeNames: [String: String] = Dictionary(uniqueKeysWithValues: (tables["themes"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("theme_id"), let label = row.text("label") else { return nil }; return (id, label)
        })
        var themeFrequency: [String: Int] = [:]
        for link in tables["idea_theme_links"] ?? [] { if let id = link.string("theme_id") { themeFrequency[id, default: 0] += 1 } }
        let availableThemes = themeFrequency.filter { themeNames[$0.key] != nil }
        let rankedThemes = availableThemes.sorted { left, right in
            if left.value != right.value { return left.value > right.value }
            return localizedAscending(themeNames[left.key] ?? left.key, themeNames[right.key] ?? right.key)
        }
        let selectedThemes: [SynthesisMatrixTheme] = rankedThemes.prefix(24).compactMap { pair in
            guard let label = themeNames[pair.key] else { return nil }
            return SynthesisMatrixTheme(themeId: pair.key, label: label)
        }
        let selectedThemeIds = Set(selectedThemes.map { $0.themeId })
        var authorsByWork: [String: Set<String>] = [:]
        for attribution in attributions where selectedAuthorIds.contains(attribution.authorId) {
            authorsByWork[attribution.workId, default: []].insert(attribution.authorId)
        }
        var cellIdeas: [String: [String: Row]] = [:]
        for link in tables["idea_theme_links"] ?? [] {
            guard let workId = link.string("nodus_id"), let themeId = link.string("theme_id"), selectedThemeIds.contains(themeId),
                  let ideaId = link.string("global_id"), let idea = ideasById[ideaId] else { continue }
            for authorId in authorsByWork[workId] ?? [] { cellIdeas["\(authorId)::\(themeId)", default: [:]][ideaId] = idea }
        }
        let cached = Dictionary(uniqueKeysWithValues: (tables["synthesis_matrix_cell"] ?? []).map { ("\($0.string("author_id") ?? "")::\($0.string("theme_id") ?? "")", $0) })
        let cells = cellIdeas.map { key, map -> SynthesisMatrixCell in
            let parts = key.components(separatedBy: "::"), allIdeas = Array(map.values)
            let fingerprint = sha1(allIdeas.compactMap { $0.string("global_id") }.sorted().joined(separator: ","))
            let cachedRow = cached[key]
            return SynthesisMatrixCell(
                authorId: parts[0], themeId: parts[1], ideaCount: allIdeas.count,
                ideas: allIdeas.prefix(8).map { idea in
                    let id = idea.string("global_id") ?? ""
                    return SynthesisMatrixCellIdea(globalId: id, label: idea.text("label") ?? id, type: ideaTypes.contains(idea.string("type") ?? "") ? idea.string("type")! : "claim")
                },
                stance: cachedRow?.string("fingerprint") == fingerprint ? cachedRow?.text("stance") : nil
            )
        }
        return SynthesisMatrix(authors: selectedAuthors, themes: selectedThemes, cells: cells)
    }

    public static func argumentRoutes(in tables: [String: [Row]]) -> [ArgumentRouteSuggestion] {
        let ideasById = Dictionary(uniqueKeysWithValues: (tables["ideas"] ?? []).compactMap { row in row.string("global_id").map { ($0, row) } })
        var adjacency: [String: [(other: String, edge: Row)]] = [:]
        var orderedIds: [String] = []
        for edge in visibleEdges(in: tables) {
            guard let from = edge.string("from_id"), let to = edge.string("to_id"), ideasById[from] != nil, ideasById[to] != nil else { continue }
            if adjacency[from] == nil { orderedIds.append(from) }
            if adjacency[to] == nil { orderedIds.append(to) }
            adjacency[from, default: []].append((to, edge)); adjacency[to, default: []].append((from, edge))
        }
        var ranked: [(suggestion: ArgumentRouteSuggestion, score: Double, order: Int)] = []
        for (order, id) in orderedIds.enumerated() {
            let neighbours = adjacency[id] ?? []
            let idea = ideasById[id]!
            let debate = neighbours.filter { debateRelations.contains($0.edge.string("type") ?? "") }.count
            let confidence = neighbours.reduce(0) { $0 + ($1.edge.double("confidence") ?? 0) }
            var relations: [String: Int] = [:]
            for neighbour in neighbours { relations[neighbour.edge.string("type") ?? "related", default: 0] += 1 }
            let sortedRelations = relations.sorted {
                $0.value == $1.value ? localizedAscending($0.key, $1.key) : $0.value > $1.value
            }
            let topRelations = sortedRelations.prefix(4).map {
                ArgumentRouteRelation(type: $0.key, count: $0.value)
            }
            let topNeighbours = neighbours.sorted { edgePriority($0.edge) > edgePriority($1.edge) }
            let neighbourLabels = topNeighbours.prefix(4).map { ideasById[$0.other]?.text("label") ?? $0.other }
            let suggestion = ArgumentRouteSuggestion(
                ideaId: id,
                label: idea.text("label") ?? id,
                statement: idea.text("statement") ?? "",
                type: ideaTypes.contains(idea.string("type") ?? "") ? idea.string("type")! : "claim",
                degree: neighbours.count,
                debateCount: debate,
                avgConfidence: neighbours.isEmpty ? 0 : confidence / Double(neighbours.count),
                topRelations: topRelations,
                neighborLabels: neighbourLabels
            )
            ranked.append((suggestion, Double(neighbours.count) + Double(debate) * 1.5 + confidence * 0.2, order))
        }
        ranked.sort { left, right in
            if left.score != right.score { return left.score > right.score }
            if left.suggestion.degree != right.suggestion.degree { return left.suggestion.degree > right.suggestion.degree }
            return left.order < right.order
        }
        return ranked.map { $0.suggestion }
    }

    private static func authorSummaries(in tables: [String: [Row]]) -> [AuthorWorkspaceItem] {
        let works = Dictionary(uniqueKeysWithValues: (tables["works"] ?? []).filter(isLive).compactMap { row in row.string("nodus_id").map { ($0, row) } })
        let credits = (tables["work_authors"] ?? []).filter { works[$0.string("nodus_id") ?? ""] != nil }
        let attributions = attributions(in: tables).filter { works[$0.workId] != nil }
        let occurrences = tables["idea_occurrences"] ?? []
        let links = tables["idea_theme_links"] ?? []
        let themes: [String: String] = Dictionary(uniqueKeysWithValues: (tables["themes"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("theme_id"), let label = row.text("label") else { return nil }; return (id, label)
        })
        let synthesisIds = Set((tables["author_dossier_synthesis"] ?? []).compactMap { $0.string("author_id") })
        let relations = tables["author_relations"] ?? []
        let tags: [String: String] = Dictionary(uniqueKeysWithValues: (tables["zotero_tags"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("tag_id"), let label = row.text("label") else { return nil }; return (id, label)
        })
        var tagsByWork: [String: [String]] = [:]
        for link in tables["work_zotero_tags"] ?? [] {
            guard let work = link.string("nodus_id"), let tag = link.string("tag_id").flatMap({ tags[$0] }) else { continue }
            tagsByWork[work, default: []].append(tag)
        }
        return (tables["authors"] ?? []).compactMap { author -> AuthorWorkspaceItem? in
            guard let id = author.string("author_id") else { return nil }
            let mine = credits.filter { $0.string("author_id") == id }
            guard !mine.isEmpty else { return nil }
            let authored = mine.filter { $0.string("role") != "editor" }, edited = mine.filter { $0.string("role") == "editor" }
            let attributed = Set(attributions.filter { $0.authorId == id }.map(\.workId))
            let ideaIds = Set(occurrences.filter { attributed.contains($0.string("nodus_id") ?? "") }.compactMap { $0.string("global_id") })
            var themeFrequency: [String: Int] = [:]
            for link in links where attributed.contains(link.string("nodus_id") ?? "") {
                if let label = link.string("theme_id").flatMap({ themes[$0] }) { themeFrequency[label, default: 0] += 1 }
            }
            var tagFrequency: [String: Int] = [:]
            for work in attributed { for tag in tagsByWork[work] ?? [] { tagFrequency[tag, default: 0] += 1 } }
            var connected = Set<String>()
            for relation in relations {
                if relation.string("from_author") == id, let other = relation.string("to_author"), other != id { connected.insert(other) }
                if relation.string("to_author") == id, let other = relation.string("from_author"), other != id { connected.insert(other) }
            }
            let name = author.text("name") ?? author.text("display_name") ?? id, parts = splitName(name)
            return AuthorWorkspaceItem(
                authorId: id, name: name, firstName: parts.first, lastName: parts.last, fullName: parts.full,
                affiliation: author.text("affiliation"), workCount: authored.count, editedCount: edited.count,
                ideaCount: ideaIds.count, relationCount: connected.count,
                topTags: tagFrequency.sorted { $0.value == $1.value ? localizedAscending($0.key, $1.key) : $0.value > $1.value }.prefix(5).map(\.key),
                topThemes: themeFrequency.sorted { $0.value == $1.value ? localizedAscending($0.key, $1.key) : $0.value > $1.value }.prefix(4).map(\.key),
                read: !authored.isEmpty && authored.allSatisfy { credit in works[credit.string("nodus_id") ?? ""]?.bool("read_tag") == true },
                hasSynthesis: synthesisIds.contains(id), saved: false
            )
        }
    }

    private static func attributions(in tables: [String: [Row]]) -> [Attribution] {
        let credits = tables["work_authors"] ?? []
        let hasAuthor = Set(credits.filter { $0.string("role") == "author" }.compactMap { $0.string("nodus_id") })
        return credits.compactMap { credit in
            guard let work = credit.string("nodus_id"), let author = credit.string("author_id") else { return nil }
            let role = credit.string("role") == "editor" ? "editor" : "author"
            guard role == "author" || !hasAuthor.contains(work) else { return nil }
            return Attribution(workId: work, authorId: author, role: role, basis: role == "author" ? "author" : "editor_only")
        }
    }

    private static func authorThemeSets(in tables: [String: [Row]], attributions: [Attribution]) -> [String: Set<String>] {
        let themes: [String: String] = Dictionary(uniqueKeysWithValues: (tables["themes"] ?? []).compactMap { row -> (String, String)? in
            guard let id = row.string("theme_id"), let label = row.text("label") else { return nil }; return (id, label)
        })
        var linksByWork: [String: [String]] = [:]
        for link in tables["idea_theme_links"] ?? [] {
            guard let work = link.string("nodus_id"), let label = link.string("theme_id").flatMap({ themes[$0] }) else { continue }
            linksByWork[work, default: []].append(label)
        }
        var result: [String: Set<String>] = [:]
        for attribution in attributions { result[attribution.authorId, default: []].formUnion(linksByWork[attribution.workId] ?? []) }
        return result
    }

    private static func workValue(_ work: Row, credit: Row, attributed: Bool) -> AuthorDossierWork {
        let authors = (work.embeddedJSON("authors_json")?.arrayValue ?? []).compactMap { value -> String? in
            if let string = value.stringValue { return string }
            guard let object = value.objectValue else { return nil }
            return [object["given"]?.stringValue, object["family"]?.stringValue].compactMap { $0 }.joined(separator: " ")
        }
        return AuthorDossierWork(
            nodusId: work.string("nodus_id") ?? "", title: work.text("title") ?? work.string("nodus_id") ?? "",
            authors: authors, year: work.int("year"), itemType: work.text("item_type"), doi: work.text("doi"), zoteroKey: work.text("zotero_key"),
            sourceType: work.text("source_type"), lightStatus: work.string("light_status") ?? "none", deepStatus: work.string("deep_status") ?? "none",
            summaryStatus: work.string("summary_status") ?? "none", notes: work.text("notes"), read: work.bool("read_tag") == true,
            role: credit.string("role") == "editor" ? "editor" : "author", attributed: attributed
        )
    }

    private static func synthesisValue(_ row: Row, fingerprint: String) -> AuthorDossierSynthesis {
        let remember = (row.embeddedJSON("remember_json")?.arrayValue ?? []).compactMap(\.stringValue)
        return AuthorDossierSynthesis(
            thesis: row.text("thesis") ?? "", remember: remember, positioning: row.text("positioning") ?? "",
            model: row.embeddedJSON("model_json"), generatedAt: row.string("generated_at") ?? "",
            stale: row.string("fingerprint").map { $0 != fingerprint } ?? false
        )
    }

    private static func splitName(_ value: String) -> (first: String, last: String, full: String) {
        let clean = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if let comma = clean.firstIndex(of: ",") {
            let last = clean[..<comma].trimmingCharacters(in: .whitespaces)
            let first = clean[clean.index(after: comma)...].trimmingCharacters(in: .whitespaces)
            return (first, last, [first, last].filter { !$0.isEmpty }.joined(separator: " "))
        }
        let parts = clean.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return ("", clean, clean) }
        return (parts[0], parts.dropFirst().joined(separator: " "), clean)
    }

    private static func isLive(_ row: Row) -> Bool { row.bool("archived") != true }

    private static func localizedAscending(_ left: String, _ right: String) -> Bool {
        left.localizedCaseInsensitiveCompare(right) == .orderedAscending
    }

    private static func edgePriority(_ edge: Row) -> Double {
        let type = edge.string("type") ?? ""
        return (edge.double("confidence") ?? 0) + (debateRelations.contains(type) ? 1.5 : (type == "supports" || type == "extends" ? 0.4 : 0))
    }

    private static func sha1(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}
