import Foundation
import NodusAI
import NodusKit

/// Names the sources a report cited.
///
/// A citation token is checkable and unreadable: `nodus://passage/920737fb-…#42` says nothing to
/// the person holding the phone. What a reader needs is the sentence the desktop puts there —
/// `Arco Blanco, M., 2020, p. 42` — and that name lives in the `works` table, one or two joins
/// away from whatever was cited.
///
/// So this asks the corpus, once, at the end of a run:
///
/// - a **work** is its own answer;
/// - a **passage** carries its work in its id (`<nodus_id>#<chunk>`), so it needs no lookup at
///   all beyond the work itself;
/// - an **idea** does not — the corpus keeps that in `idea_occurrences`, which no list endpoint
///   projects — so the idea's own detail is fetched and its first occurrence read.
///
/// Everything degrades to the entry's own label. A citation whose source cannot be named is
/// still a real citation, and showing its material beats showing its primary key.
actor CorpusCitations {
    private let client: NodusClient
    private let spaceId: String

    /// Work rows already fetched, including the ones that came back missing, so a corpus that
    /// no longer holds a work is asked about once rather than once per citation.
    private var works: [String: WorkCitation?] = [:]
    private var ideaWorks: [String: String?] = [:]
    /// Passages whose id did not name their work, and the page they sit on.
    private var passageWorks: [String: (work: String, page: String?)?] = [:]

    /// How many lookups a single report may cost.
    ///
    /// A run is one model call per section; a hundred small GETs beside that is nothing. Ten
    /// thousand would be, and a report that cites the whole corpus is exactly the shape that
    /// would produce them.
    private static let lookupCeiling = 160
    /// Enough to hide the round trips, few enough that a phone on a slow link is not opening
    /// sixty sockets to a Raspberry Pi.
    private static let concurrency = 6

    init(client: NodusClient, spaceId: String) {
        self.client = client
        self.spaceId = spaceId
    }

    /// The labels and the bibliography for everything a report really cited.
    func labelling(for cited: [CitationCatalog.Entry]) async -> CitationLabelling {
        let ideas = cited.filter { $0.kind == "idea" && $0.workId == nil }.map(\.id)
        await resolveIdeaWorks(Array(ideas.prefix(Self.lookupCeiling)))

        // A passage usually names its work in its own id, but only because that is how the
        // desktop mints one. A vault whose passages are keyed some other way is not a vault
        // whose citations should give up, so the row itself is asked.
        let passages = cited.filter { $0.kind == "passage" && $0.impliedWorkId == nil }.map(\.id)
        await resolvePassageWorks(Array(passages.prefix(Self.lookupCeiling)))

        var needed: [String] = []
        var seenWork = Set<String>()
        for entry in cited {
            guard let id = workId(for: entry), seenWork.insert(id).inserted else { continue }
            needed.append(id)
        }
        await resolveWorks(Array(needed.prefix(Self.lookupCeiling)))

        var inline: [String: String] = [:]
        var references: [CitationCatalog.Entry] = []
        var referenced = Set<String>()

        for entry in cited {
            let work = workId(for: entry).flatMap { works[$0] ?? nil }
            inline[entry.token] = label(for: entry, work: work)

            guard let work, referenced.insert(work.id).inserted else { continue }
            references.append(CitationCatalog.Entry(
                token: "nodus://work/\(work.id)",
                kind: "work",
                id: work.id,
                label: work.bibliography,
                workId: work.id
            ))
        }
        return CitationLabelling(inline: inline, references: references)
    }

    /// Name the sources of a report written before assembly learned to.
    ///
    /// Reports already on this device open with `(passage/920737fb-…#42)` in the middle of their
    /// sentences, and no amount of care taken with new ones fixes that. The tokens are still on
    /// the page, though, and a token is enough to ask the corpus what it points at — so opening
    /// an old report repairs it, once, in place.
    ///
    /// Returns nil when there is nothing to repair, which is the common case.
    func repairing(_ report: DeepResearchReport) async -> DeepResearchReport? {
        guard report.sections.contains(where: { CitationRendering.hasBareToken(in: $0.prose) }) else { return nil }

        var seen = Set<String>()
        var cited: [CitationCatalog.Entry] = []
        for section in report.sections {
            for token in CitationRendering.tokens(in: section.prose) where seen.insert(token).inserted {
                guard let parsed = CitationRendering.parse(token) else { continue }
                // No label: this entry was reconstructed from a page, not read from a catalogue,
                // so it has no name to fall back on and must not invent one.
                cited.append(CitationCatalog.Entry(
                    token: token,
                    kind: parsed.kind,
                    id: parsed.id,
                    label: ""
                ))
            }
        }
        let labelling = await labelling(for: cited)
        guard labelling.inline.values.contains(where: { !$0.isEmpty }) else { return nil }

        return DeepResearchReport(
            objective: report.objective,
            sections: report.sections.map { section in
                DeepResearchSection(
                    title: section.title,
                    prose: CitationRendering.linking(section.prose, labels: labelling.inline),
                    citations: section.citations,
                    rejectedCitations: section.rejectedCitations
                )
            },
            // The old bibliography held only works the model happened to cite by name. The new
            // one is every work behind every citation, which is what a bibliography is.
            references: labelling.references.isEmpty ? report.references : labelling.references,
            words: report.words,
            pages: report.pages,
            citationsChecked: report.citationsChecked,
            citationsRejected: report.citationsRejected,
            stoppedReason: report.stoppedReason,
            supportMatrix: report.supportMatrix, audit: report.audit, materialScopes: report.materialScopes
        )
    }

    // MARK: - Labels

    /// A passage is cited with the page it sits on, when the corpus captured one. The chunk
    /// index in its id is deliberately never shown as a page: nothing is better than a page
    /// number the reader would turn to and not find.
    private func label(for entry: CitationCatalog.Entry, work: WorkCitation?) -> String {
        guard let work else { return entry.shortLabel }
        guard entry.kind == "passage" else { return work.inline }
        guard let page = page(entry.locator ?? (passageWorks[entry.id] ?? nil)?.page) else { return work.inline }
        return "\(work.inline), \(page)"
    }

    /// `42` is a page and reads as one only once it is told so; `p. 42` and `ff. 3r` already are.
    private func page(_ locator: String?) -> String? {
        guard let trimmed = locator?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        let isBareNumber = trimmed.allSatisfy { $0.isNumber || $0 == "-" || $0 == "–" }
        return isBareNumber ? "p. \(trimmed)" : trimmed
    }

    private func workId(for entry: CitationCatalog.Entry) -> String? {
        if let id = entry.impliedWorkId { return id }
        switch entry.kind {
        case "idea": return ideaWorks[entry.id] ?? nil
        case "passage": return (passageWorks[entry.id] ?? nil)?.work
        default: return nil
        }
    }

    // MARK: - Lookups

    private func resolveIdeaWorks(_ ids: [String]) async {
        let wanted = ids.filter { ideaWorks[$0] == nil }
        guard !wanted.isEmpty else { return }
        let found: [String: String] = await inBatches(wanted) { [client, spaceId] id in
            guard let detail = try? await client.idea(id, in: spaceId) else { return nil }
            // The first occurrence, which is the order the desktop cites in too
            // (`deepResearchCore.ts:1781`): an idea drawn from several works is cited by the
            // one the corpus lists first rather than by all of them at once.
            return detail.occurrences.compactMap { $0.string("nodus_id") }.first
        }
        for id in wanted { ideaWorks[id] = found[id] ?? nil }
    }

    private func resolvePassageWorks(_ ids: [String]) async {
        let wanted = ids.filter { passageWorks[$0] == nil }
        guard !wanted.isEmpty, let passages = Collections["passages"] else { return }
        let found: [String: (work: String, page: String?)] = await inBatches(wanted) { [client, spaceId] id in
            guard let row = try? await client.item(passages, id: id, in: spaceId),
                  let work = row.string("nodus_id")
            else { return nil }
            return (work, row.text("page_label"))
        }
        for id in wanted { passageWorks[id] = found[id] ?? nil }
    }

    private func resolveWorks(_ ids: [String]) async {
        let wanted = ids.filter { works[$0] == nil }
        guard !wanted.isEmpty else { return }
        let found: [String: WorkCitation] = await inBatches(wanted) { [client, spaceId] id in
            guard let detail = try? await client.work(id, in: spaceId) else { return nil }
            return Self.citation(id: id, from: detail.work)
        }
        for id in wanted { works[id] = found[id] ?? nil }
    }

    /// Run one lookup per id, a few at a time, keeping only the ones that answered.
    private func inBatches<Value: Sendable>(
        _ ids: [String],
        _ lookup: @escaping @Sendable (String) async -> Value?
    ) async -> [String: Value] {
        var results: [String: Value] = [:]
        for chunk in stride(from: 0, to: ids.count, by: Self.concurrency).map({ start in
            Array(ids[start..<min(start + Self.concurrency, ids.count)])
        }) {
            if Task.isCancelled { return results }
            await withTaskGroup(of: (String, Value?).self) { group in
                for id in chunk {
                    group.addTask { (id, await lookup(id)) }
                }
                for await (id, value) in group where value != nil {
                    results[id] = value
                }
            }
        }
        return results
    }

    /// A work row as a citation names it.
    ///
    /// `authors_json` is CSL — objects with `family`/`given`, sometimes a `literal`, sometimes
    /// just a string — which is the same shape `RowPresenter.authorList` reads for the library.
    nonisolated static func citation(id: String, from row: Row) -> WorkCitation {
        WorkCitation(
            id: id,
            authors: authors(row),
            year: row.text("year"),
            title: row.text("title")
        )
    }

    nonisolated private static func authors(_ row: Row) -> [String] {
        guard let array = row.embeddedJSON("authors_json")?.arrayValue else {
            return row.text("authors").map { [$0] } ?? []
        }
        return array.compactMap { entry -> String? in
            if let object = entry.objectValue {
                if let literal = object["literal"]?.stringValue { return literal }
                let family = object["family"]?.stringValue
                let given = object["given"]?.stringValue
                let joined = [family, given].compactMap { $0 }.joined(separator: ", ")
                return joined.isEmpty ? nil : joined
            }
            return entry.stringValue
        }
    }
}
