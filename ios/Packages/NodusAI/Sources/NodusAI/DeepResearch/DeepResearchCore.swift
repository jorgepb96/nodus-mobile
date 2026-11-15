import Foundation
import NodusKit

// A port of electron/ai/deepResearchCore.ts, keeping its two load-bearing properties:
// dependencies are injected, so the whole pipeline runs against fakes with no network; and
// citations are validated against a catalogue rather than trusted, so a model that invents a
// source produces a report with that sentence stripped, not a report with a fake reference.

public enum DeepResearchLength: String, Sendable, Codable, CaseIterable {
    case adaptive, concise, standard, exhaustive

    public var label: String {
        switch self {
        case .adaptive: return "Adapted to the corpus"
        case .concise: return "Brief (5–8 pages)"
        case .standard: return "Standard (9–14 pages)"
        case .exhaustive: return "Exhaustive (15–20 pages)"
        }
    }
}

/// Who the report is written for, which changes what it is.
///
/// The desktop keeps two prompt packs rather than one with a variable in it
/// (`electron/ai/studyDeepResearch.ts:232-239`), and the reason is that mixing teacher and
/// learner instructions produces a document that serves neither: a teaching unit sequences by
/// concept dependency and names classroom activities and common student errors, while a
/// research report argues a thesis.
public enum DeepResearchMode: String, Sendable, Codable, CaseIterable {
    /// A cited report that argues from the corpus.
    case research
    /// A teaching unit, written for whoever is going to give the class.
    case teachingUnit

    public var label: String {
        switch self {
        case .research: return "Report"
        case .teachingUnit: return "Teaching unit"
        }
    }

    public var explanation: String {
        switch self {
        case .research:
            return "Continuous academic prose arguing a thesis grounded in the corpus."
        case .teachingUnit:
            return "Parts sequenced by concept dependency, written for whoever gives the class: what is taught, with which materials, common mistakes, and how to check understanding."
        }
    }
}

/// The research method applied inside a report or teaching unit.
///
/// Raw values deliberately match `shared/deepResearchApproaches.ts` in Nodus Desktop. The
/// approach is independent from ``DeepResearchMode``: one says how evidence is organised,
/// while the other says who the resulting document is for.
public enum DeepResearchApproach: String, Sendable, Codable, CaseIterable, Identifiable {
    case general
    case literatureReview = "literature_review"
    case stateOfArt = "state_of_art"
    case scholarlyDebate = "scholarly_debate"
    case comparative
    case chronological
    case conceptual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .general: return "General research"
        case .literatureReview: return "Literature review"
        case .stateOfArt: return "State of the art"
        case .scholarlyDebate: return "Scholarly debate"
        case .comparative: return "Comparative analysis"
        case .chronological: return "Chronological analysis"
        case .conceptual: return "Conceptual or theoretical synthesis"
        }
    }

    public var explanation: String {
        switch self {
        case .general:
            return "Uses the broad retrieval and structure of the original Deep Research workflow."
        case .literatureReview:
            return "Synthesises interpretations, methods, agreements and disagreements across works."
        case .stateOfArt:
            return "Separates established findings, contested claims, limitations and open questions."
        case .scholarlyDebate:
            return "Reconstructs real disagreements, their evidence, assumptions and intermediate positions."
        case .comparative:
            return "Compares cases, works or concepts using stable criteria and balanced evidence."
        case .chronological:
            return "Explains antecedents, phases, continuities, changes and documented turning points."
        case .conceptual:
            return "Reconstructs definitions, frameworks and relationships between concepts without conflating them."
        }
    }

    /// Prompt adapter ported from Desktop's `electron/ai/deepResearchApproaches.ts`.
    public var promptRules: String {
        switch self {
        case .general:
            return ""
        case .literatureReview:
            return """
            RESEARCH APPROACH: LITERATURE REVIEW
            Retrieve diverse interpretations, frameworks, methods, agreements and disagreements. Organise by problems, schools or themes, never one section per author. Synthesize sources against one another and distinguish broad agreement from isolated claims. Never imply that the available Nodus corpus represents the entire academic field.
            """
        case .stateOfArt:
            return """
            RESEARCH APPROACH: STATE OF THE ART
            Separate what is well established in the available corpus from what is weakly supported, disputed, unresolved or absent. Organise around established knowledge, convergence, controversies, evidentiary or methodological limits and open problems. Never turn missing retrieved evidence into a claim that the field has never studied something.
            """
        case .scholarlyDebate:
            return """
            RESEARCH APPROACH: SCHOLARLY DEBATE
            Reconstruct genuine positions only when supported by the corpus. For each disagreement explain the claim, evidence, assumptions, stakes and possible intermediate positions. Do not manufacture a two-sided debate from nuance or silence.
            """
        case .comparative:
            return """
            RESEARCH APPROACH: COMPARATIVE ANALYSIS
            Name the comparands and use stable, explicit axes across them. Give each case balanced evidentiary treatment, distinguish similarity from equivalence, and explain both meaningful parallels and consequential differences.
            """
        case .chronological:
            return """
            RESEARCH APPROACH: CHRONOLOGICAL ANALYSIS
            Organise evidence into antecedents, phases, continuities, changes and documented turning points. Use dates only where the corpus supports them; do not infer causation merely from temporal succession.
            """
        case .conceptual:
            return """
            RESEARCH APPROACH: CONCEPTUAL OR THEORETICAL SYNTHESIS
            Reconstruct definitions, assumptions, conceptual families and relations between frameworks. Preserve differences between near concepts, show tensions and compatibilities, and never collapse distinct vocabularies into false synonyms.
            """
        }
    }
}

public struct DeepResearchRequest: Sendable, Codable, Hashable {
    public var objective: String
    public var language: String
    public var audience: String?
    public var targetLength: DeepResearchLength
    public var sectionLimit: Int?
    public var mode: DeepResearchMode
    /// Missing on reports created before approaches existed. Nil deliberately normalizes to
    /// General, matching Desktop's backwards-compatibility contract.
    public var approach: DeepResearchApproach?
    public var model: ModelRef
    /// Draw the report an illustration when it is finished, in this style.
    ///
    /// Part of the request rather than of the screen, so a run picked up by a background task
    /// still produces the report the user asked for. Optional, so a checkpoint written before
    /// illustrations existed still decodes.
    public var illustration: DecorativeImageStyle?
    /// Genealogy vaults can anchor the investigation on one known person. Optional keeps old
    /// checkpoints and non-genealogy requests source compatible.
    public var focusPerson: String?
    /// A teacher may supply the intended unit order. The orchestrator treats it as guidance,
    /// never as evidence; citations still have to come from the corpus.
    public var teachingOutline: String?

    public init(
        objective: String,
        // English unless the caller says otherwise. The app always passes
        // `Prompts.interfaceLanguage`, which follows the phone; a Spanish default here meant a
        // request built without one — a resumed run, a test — silently changed the language the
        // report was written in.
        language: String = "en",
        audience: String? = nil,
        targetLength: DeepResearchLength = .adaptive,
        sectionLimit: Int? = nil,
        mode: DeepResearchMode = .research,
        approach: DeepResearchApproach = .general,
        model: ModelRef,
        illustration: DecorativeImageStyle? = nil,
        focusPerson: String? = nil,
        teachingOutline: String? = nil
    ) {
        self.objective = objective
        self.language = language
        self.audience = audience
        self.targetLength = targetLength
        self.sectionLimit = sectionLimit
        self.mode = mode
        self.approach = approach
        self.model = model
        self.illustration = illustration
        self.focusPerson = focusPerson
        self.teachingOutline = teachingOutline
    }

    public var resolvedApproach: DeepResearchApproach { approach ?? .general }
}

public enum DeepResearchPhase: String, Sendable, Codable {
    case queued, snapshot, planning, retrieving, writing, verifying, assembling, done
}

public struct DeepResearchProgress: Sendable, Codable, Hashable {
    public var phase: DeepResearchPhase
    public var message: String
    public var sectionIndex: Int?
    public var sectionTotal: Int?
    public var sectionTitle: String?
    public var wordsSoFar: Int

    public init(
        phase: DeepResearchPhase,
        message: String,
        sectionIndex: Int? = nil,
        sectionTotal: Int? = nil,
        sectionTitle: String? = nil,
        wordsSoFar: Int
    ) {
        self.phase = phase
        self.message = message
        self.sectionIndex = sectionIndex
        self.sectionTotal = sectionTotal
        self.sectionTitle = sectionTitle
        self.wordsSoFar = wordsSoFar
    }
    public var pagesSoFar: Double { Double(wordsSoFar) / Double(DeepResearchLimits.wordsPerPage) }

    public var fraction: Double? {
        guard let index = sectionIndex, let total = sectionTotal, total > 0 else { return nil }
        // Planning and assembly are real work either side of the sections, so the sections
        // occupy the middle 80% rather than the whole bar.
        return 0.1 + (Double(index) / Double(total)) * 0.8
    }
}

public enum DeepResearchLimits {
    public static let wordsPerPage = 450
    public static let minSections = 3
    public static let maxSections = 14
    /// How far past a requested count the planner may go when the material asks for it.
    public static let sectionGrace = 1
    public static let poolIdeas = 70
    public static let poolThemes = 20
    public static let poolGaps = 20
    public static let poolWorks = 40
    public static let poolPassages = 20

    /// `resolveTargetPages` (`deepResearchCore.ts:1919-1931`).
    ///
    /// `adaptive` is derived from how much the corpus actually holds: promising twenty pages
    /// from a corpus with forty ideas produces padding, not depth.
    public static func targetPages(_ length: DeepResearchLength, citableCount: Int) -> ClosedRange<Int> {
        switch length {
        case .concise: return 5...8
        case .standard: return 9...14
        case .exhaustive: return 15...20
        case .adaptive:
            switch citableCount {
            case ..<25: return 4...6
            case ..<80: return 6...10
            case ..<200: return 9...14
            default: return 12...18
            }
        }
    }

    /// The counts a run aims for, and the one it may not pass.
    ///
    /// A number the user chose is a *ceiling with a grace of one*, not a quota
    /// (`resolveSectionPlan`, `deepResearchCore.ts:736-738`): asking for six sections and being
    /// given exactly six every time would make the planner pad a corpus that had five things to
    /// say, and refuse a seventh that the material genuinely needed.
    public static func sectionPlan(pages: ClosedRange<Int>, requested: Int?) -> (target: Int, hardCap: Int) {
        if let requested {
            let clamped = min(maxSections, max(minSections, requested))
            return (clamped, min(maxSections, clamped + sectionGrace))
        }
        let derived = max(minSections, min(maxSections, Int((Double(pages.upperBound) / 1.5).rounded())))
        return (derived, min(maxSections, derived + 2))
    }
}

// MARK: - The citation catalogue

/// Every token the writer is allowed to cite, and nothing else.
///
/// A citation always resolves against a real corpus row — the server says so in the
/// `citationScheme` it returns with every context package. This type is that rule made
/// enforceable: anything not in here is removed at assembly.
public struct CitationCatalog: Sendable {
    public struct Entry: Sendable, Hashable, Codable {
        public let token: String
        public let kind: String
        public let id: String
        public let label: String
        public let detail: String?
        /// The work this citation rests on, when the row said which one. An idea does not carry
        /// it — the corpus keeps that in `idea_occurrences`, which no read endpoint projects —
        /// so it is resolved once, at assembly, for the ideas that were really cited.
        ///
        /// Optional and defaulted, because reports saved before it existed have to keep opening:
        /// a synthesised `Decodable` reads a missing key for an `Optional` as nil.
        public let workId: String?
        /// A page or locator, for a passage.
        public let locator: String?

        public init(
            token: String,
            kind: String,
            id: String,
            label: String,
            detail: String? = nil,
            workId: String? = nil,
            locator: String? = nil
        ) {
            self.token = token
            self.kind = kind
            self.id = id
            self.label = label
            self.detail = detail
            self.workId = workId
            self.locator = locator
        }
    }

    public private(set) var entries: [Entry]
    private let byToken: [String: Entry]

    public init(entries: [Entry]) {
        self.entries = entries
        byToken = Dictionary(entries.map { ($0.token, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func contains(_ token: String) -> Bool { byToken[token] != nil }
    public func entry(for token: String) -> Entry? { byToken[token] }
    public var isEmpty: Bool { entries.isEmpty }

    /// Budget complete source entries. An oversized literal quotation is
    /// omitted, never rewritten as a prefix that could change its meaning.
    public func bounded(to bytes: Int) throws -> (catalog: CitationCatalog, omitted: Int, bytes: Int) {
        var kept: [Entry] = [], used = 0, omitted = 0
        let limit = max(0, bytes)
        for entry in entries {
            let cost = try JSONEncoder.nodus.encode(entry).count
            if cost > limit - used { omitted += 1; continue }
            used += cost; kept.append(entry)
        }
        return (CitationCatalog(entries: kept), omitted, used)
    }

    /// Built from a context package the server returned.
    public static func from(_ package: ContextPackage) -> CitationCatalog {
        var entries: [Entry] = []
        for section in package.sections {
            for row in section.items {
                switch section.kind {
                case "sources":
                    guard let source = try? CorpusSourceMaterial(row: row) else { continue }
                    entries.append(Entry(token: source.citation, kind: source.kind, id: source.id, label: source.label,
                        detail: source.text, locator: row.text("locator")))
                case "ideas":
                    guard let id = row.string("global_id") else { continue }
                    entries.append(Entry(
                        token: "nodus://idea/\(id)",
                        kind: "idea",
                        id: id,
                        label: row.text("label") ?? row.text("statement") ?? "Idea",
                        detail: row.text("statement")
                    ))
                case "passages":
                    guard let id = row.string("passage_id") else { continue }
                    entries.append(Entry(
                        token: "nodus://passage/\(id)",
                        kind: "passage",
                        id: id,
                        label: String((row.text("text") ?? "Passage").prefix(120)),
                        detail: row.text("text") ?? row.text("section"),
                        workId: row.string("nodus_id"),
                        locator: row.text("page_label")
                    ))
                case "works":
                    guard let id = row.string("nodus_id") else { continue }
                    let year = row.text("year").map { " (\($0))" } ?? ""
                    entries.append(Entry(
                        token: "nodus://work/\(id)",
                        kind: "work",
                        id: id,
                        label: (row.text("title") ?? "Work") + year,
                        detail: nil,
                        workId: id
                    ))
                case "gaps":
                    guard let id = row.string("id") else { continue }
                    entries.append(Entry(token: "nodus://gap/\(id)", kind: "gap", id: id,
                        label: row.text("title") ?? row.text("label") ?? row.text("topic") ?? "Gap",
                        detail: row.text("description") ?? row.text("rationale")))
                default:
                    continue
                }
            }
        }
        return CitationCatalog(entries: entries)
    }

    /// Merge two catalogues, keeping the first occurrence of each token.
    public func merging(_ other: CitationCatalog) -> CitationCatalog {
        var seen = Set(entries.map(\.token))
        var combined = entries
        for entry in other.entries where seen.insert(entry.token).inserted {
            combined.append(entry)
        }
        return CitationCatalog(entries: combined)
    }
}

// MARK: - Output

public struct DeepResearchSection: Sendable, Codable, Hashable {
    public init(title: String, prose: String, citations: [String], rejectedCitations: [String]) {
        self.title = title
        self.prose = prose
        self.citations = citations
        self.rejectedCitations = rejectedCitations
    }

    public let title: String
    public let prose: String
    /// Tokens that survived validation.
    public let citations: [String]
    /// Tokens the model produced that are not in the catalogue. Removed from the prose, and
    /// reported rather than hidden — an invented citation says something about the run.
    public let rejectedCitations: [String]

    public var wordCount: Int {
        prose.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }
}

public struct DeepResearchSupportCell: Sendable, Codable, Hashable, Identifiable {
    public enum Status: String, Sendable, Codable, Hashable { case supported, partial, unavailable }

    public let id: String
    public let sectionTitle: String
    public let citationToken: String
    public let sourceLabel: String
    public let claimPreview: String
    public let status: Status

    public init(id: String, sectionTitle: String, citationToken: String, sourceLabel: String, claimPreview: String, status: Status) {
        self.id = id
        self.sectionTitle = sectionTitle
        self.citationToken = citationToken
        self.sourceLabel = sourceLabel
        self.claimPreview = claimPreview
        self.status = status
    }
}

public struct DeepResearchAudit: Sendable, Codable, Hashable {
    public let citationsChecked: Int
    public let citationsRejected: Int
    public let citedSourceCount: Int
    public let generatedAt: Date

    public init(citationsChecked: Int, citationsRejected: Int, citedSourceCount: Int, generatedAt: Date = Date()) {
        self.citationsChecked = citationsChecked
        self.citationsRejected = citationsRejected
        self.citedSourceCount = citedSourceCount
        self.generatedAt = generatedAt
    }
}

public struct DeepResearchReport: Sendable, Codable, Hashable {
    public init(
        objective: String,
        sections: [DeepResearchSection],
        references: [CitationCatalog.Entry],
        words: Int,
        pages: Double,
        citationsChecked: Int,
        citationsRejected: Int,
        stoppedReason: String?,
        supportMatrix: [DeepResearchSupportCell]? = nil,
        audit: DeepResearchAudit? = nil,
        materialScopes: [String]? = nil
    ) {
        self.objective = objective
        self.sections = sections
        self.references = references
        self.words = words
        self.pages = pages
        self.citationsChecked = citationsChecked
        self.citationsRejected = citationsRejected
        self.stoppedReason = stoppedReason
        self.materialScopes = materialScopes
        let labels = Dictionary(uniqueKeysWithValues: references.map { ($0.token, $0.label) })
        self.supportMatrix = supportMatrix ?? sections.flatMap { section in
            let preview = section.prose.split(separator: ".", maxSplits: 1).first.map(String.init) ?? section.prose
            return section.citations.enumerated().map { offset, token in
                DeepResearchSupportCell(
                    id: "\(section.title)-\(offset)-\(token)",
                    sectionTitle: section.title,
                    citationToken: token,
                    sourceLabel: labels[token] ?? token,
                    claimPreview: String(preview.prefix(220)),
                    status: labels[token] == nil ? .unavailable : .supported
                )
            }
        }
        self.audit = audit ?? DeepResearchAudit(
            citationsChecked: citationsChecked,
            citationsRejected: citationsRejected,
            citedSourceCount: references.count
        )
    }

    public let objective: String
    public let sections: [DeepResearchSection]
    /// The works actually cited, in the order they first appear. Built from citations, not
    /// from anything the model claimed as a bibliography.
    public let references: [CitationCatalog.Entry]
    public let words: Int
    public let pages: Double
    public let citationsChecked: Int
    public let citationsRejected: Int
    /// Set when the run stopped short of its target and why.
    public let stoppedReason: String?
    /// Claim-to-source traceability materialised with the report so every platform presents
    /// the same support evidence without reverse engineering prose in the reader.
    public let supportMatrix: [DeepResearchSupportCell]?
    /// Verification facts and generation timestamp. Optional for reports created before the
    /// full contract was introduced.
    public let audit: DeepResearchAudit?
    public let materialScopes: [String]?

    public var materialNotice: String? {
        guard materialScopes?.contains("device_downloads") == true else { return nil }
        if materialScopes?.contains("linked_corpus") == true || materialScopes?.contains("unknown_recovered") == true {
            return "La investigación combina material descargado en este dispositivo con material recuperado previamente. Las descargas no representan el vault completo."
        }
        return "Investigación basada en los dossiers descargados en este dispositivo. Su alcance se limita a ese material y no representa el vault completo."
    }

    public func withMaterialScopes(_ scopes: [String]) -> Self {
        Self(objective: objective, sections: sections, references: references, words: words, pages: pages,
            citationsChecked: citationsChecked, citationsRejected: citationsRejected, stoppedReason: stoppedReason,
            supportMatrix: supportMatrix, audit: audit, materialScopes: scopes)
    }

    public var resolvedSupportMatrix: [DeepResearchSupportCell] { supportMatrix ?? [] }

    public var markdown: String {
        var output = "# \(objective)\n\n"
        if let materialNotice { output += "> \(materialNotice)\n\n" }
        for section in sections {
            output += "## \(section.title)\n\n\(section.prose)\n\n"
        }
        if !references.isEmpty {
            output += "## References\n\n"
            for reference in references {
                output += "- \(reference.label)\n"
            }
        }
        return output
    }
}

// MARK: - Injected dependencies

/// Everything the orchestrator needs from the outside, so it can be driven by fakes.
public struct DeepResearchDeps: Sendable {
    /// Ranks the corpus for the objective and returns what may be cited.
    public var buildCatalog: @Sendable (_ objective: String) async throws -> CitationCatalog
    /// Retrieval for one section, which may narrow the catalogue.
    public var retrieveForSection: @Sendable (_ sectionTitle: String, _ objective: String) async throws -> CitationCatalog
    /// Returns section titles.
    public var plan: @Sendable (_ request: DeepResearchRequest, _ catalog: CitationCatalog, _ target: Int, _ cap: Int) async throws -> [String]
    /// Writes one section's prose.
    public var writeSection: @Sendable (_ request: DeepResearchRequest, _ title: String, _ index: Int, _ total: Int, _ catalog: CitationCatalog, _ wordTarget: Int) async throws -> String
    /// Turns the citations a report really used into what a reader sees: a label for each token
    /// and the works behind them.
    ///
    /// Injected rather than computed here because naming a source is a question about the
    /// corpus — an idea's work lives in a table no page of prose carries — and the orchestrator
    /// is the one piece of this pipeline that never talks to a server.
    public var describeCitations: @Sendable (_ cited: [CitationCatalog.Entry]) async -> CitationLabelling

    public init(
        buildCatalog: @escaping @Sendable (String) async throws -> CitationCatalog,
        retrieveForSection: @escaping @Sendable (String, String) async throws -> CitationCatalog,
        plan: @escaping @Sendable (DeepResearchRequest, CitationCatalog, Int, Int) async throws -> [String],
        writeSection: @escaping @Sendable (DeepResearchRequest, String, Int, Int, CitationCatalog, Int) async throws -> String,
        describeCitations: @escaping @Sendable ([CitationCatalog.Entry]) async -> CitationLabelling = { CitationLabelling.plain($0) }
    ) {
        self.buildCatalog = buildCatalog
        self.retrieveForSection = retrieveForSection
        self.plan = plan
        self.writeSection = writeSection
        self.describeCitations = describeCitations
    }
}

public enum DeepResearchError: Error, Sendable {
    case emptyCorpus
    case planningFailed(String)
    case cancelled
}

// MARK: - Resuming

/// Everything a half-finished run needs to carry on somewhere else.
///
/// A run is one model call per section. Being killed halfway — by the user leaving the app, by
/// iOS reclaiming memory, by a background task expiring — would waste every call already paid
/// for, so the orchestrator emits one of these after each section and can be handed one back.
///
/// The citation catalogue is deliberately *not* in here. Rebuilding it costs retrieval and at
/// most one embedding call, while a section costs a full completion; persisting a few hundred
/// entries to save the cheaper of the two would be the wrong trade, and a catalogue rebuilt
/// from the current publication is more correct than one frozen an hour ago.
public struct DeepResearchCheckpoint: Sendable, Codable, Hashable {
    public let request: DeepResearchRequest
    /// The plan, fixed at the first attempt. Re-planning on resume would produce a report whose
    /// second half answers a different outline from its first.
    public let titles: [String]
    public let wordTarget: Int
    public let sections: [DeepResearchSection]
    public let citationsChecked: Int
    public let citationsRejected: Int
    public let startedAt: Date
    public let materialScopes: [String]?

    public init(
        request: DeepResearchRequest,
        titles: [String],
        wordTarget: Int,
        sections: [DeepResearchSection],
        citationsChecked: Int,
        citationsRejected: Int,
        startedAt: Date,
        materialScopes: [String]? = nil
    ) {
        self.request = request
        self.titles = titles
        self.wordTarget = wordTarget
        self.sections = sections
        self.citationsChecked = citationsChecked
        self.citationsRejected = citationsRejected
        self.startedAt = startedAt
        self.materialScopes = materialScopes
    }

    public func withMaterialScopes(_ scopes: [String]) -> Self {
        Self(request: request, titles: titles, wordTarget: wordTarget, sections: sections, citationsChecked: citationsChecked,
            citationsRejected: citationsRejected, startedAt: startedAt, materialScopes: scopes)
    }

    /// The next section to write. Everything before it is already paid for.
    public var nextSectionIndex: Int { min(sections.count, titles.count) }
    public var isComplete: Bool { sections.count >= titles.count }
    public var words: Int { sections.reduce(0) { $0 + $1.wordCount } }

    /// Whether this checkpoint can still be resumed against a given request.
    ///
    /// Resuming into a *different* objective would silently graft half a report onto another
    /// question, so the objective and the shape of the run must match.
    public func resumes(_ other: DeepResearchRequest) -> Bool {
        request.objective == other.objective
            && request.mode == other.mode
            && request.targetLength == other.targetLength
    }
}

// MARK: - The orchestrator

public struct DeepResearchOrchestrator: Sendable {
    private let deps: DeepResearchDeps

    public init(deps: DeepResearchDeps) {
        self.deps = deps
    }

    /// - Parameters:
    ///   - resuming: a checkpoint from an earlier attempt at the same request. Its sections are
    ///     kept and its plan is reused; only the sections it never reached are written.
    ///   - onCheckpoint: called after every section, and once after planning. Persisting what it
    ///     hands over is what makes a killed run resumable rather than wasted.
    public func run(
        _ request: DeepResearchRequest,
        resuming checkpoint: DeepResearchCheckpoint? = nil,
        onCheckpoint: @Sendable (DeepResearchCheckpoint) -> Void = { _ in },
        onProgress: @Sendable (DeepResearchProgress) -> Void = { _ in }
    ) async throws -> DeepResearchReport {
        // A checkpoint for a different objective is not a checkpoint for this run.
        let resume = checkpoint.flatMap { $0.resumes(request) ? $0 : nil }

        onProgress(.init(
            phase: .snapshot,
            message: resume == nil ? "Preparing the corpus" : "Picking up where it stopped",
            wordsSoFar: resume?.words ?? 0
        ))
        // Rebuilt even on resume: it is the cheap half of the run, and the sections still to be
        // written must be able to cite the corpus as it stands now.
        let catalog = try await deps.buildCatalog(request.objective)
        guard !catalog.isEmpty else { throw DeepResearchError.emptyCorpus }

        let pages = DeepResearchLimits.targetPages(request.targetLength, citableCount: catalog.entries.count)
        let plan = DeepResearchLimits.sectionPlan(pages: pages, requested: request.sectionLimit)

        var titles: [String]
        let wordTarget: Int
        if let resume {
            titles = resume.titles
            wordTarget = resume.wordTarget
        } else {
            onProgress(.init(phase: .planning, message: "Planning \(plan.target) sections", wordsSoFar: 0))
            titles = try await deps.plan(request, catalog, plan.target, plan.hardCap)
            guard !titles.isEmpty else { throw DeepResearchError.planningFailed("the plan came back empty") }
            if titles.count > plan.hardCap { titles = Array(titles.prefix(plan.hardCap)) }
            wordTarget = max(
                250,
                (pages.lowerBound + pages.upperBound) / 2 * DeepResearchLimits.wordsPerPage / max(1, titles.count)
            )
        }

        var sections: [DeepResearchSection] = resume?.sections ?? []
        var words = sections.reduce(0) { $0 + $1.wordCount }
        var checked = resume?.citationsChecked ?? 0
        var rejected = resume?.citationsRejected ?? 0
        var stoppedReason: String?
        let startedAt = resume?.startedAt ?? Date()

        func currentCheckpoint() -> DeepResearchCheckpoint {
            DeepResearchCheckpoint(
                request: request,
                titles: titles,
                wordTarget: wordTarget,
                sections: sections,
                citationsChecked: checked,
                citationsRejected: rejected,
                startedAt: startedAt
            )
        }

        // Emitted before the first model call so a run killed during its first section still
        // resumes with a plan rather than paying to draw one up again.
        onCheckpoint(currentCheckpoint())

        // Everything any section was allowed to cite. A section's own retrieval widens the
        // catalogue for that section only, so a work first met in section seven was absent from
        // the assembly catalogue and dropped out of the bibliography it belonged in.
        var known = catalog

        let first = resume?.nextSectionIndex ?? 0
        for (index, title) in titles.enumerated() where index >= first {
            try Task.checkCancellation()

            onProgress(.init(
                phase: .retrieving,
                message: "Retrieving for “\(title)”",
                sectionIndex: index, sectionTotal: titles.count, sectionTitle: title,
                wordsSoFar: words
            ))
            // A section-specific catalogue narrows what may be cited here, merged with the
            // global one so a section can still reach back to the corpus as a whole.
            let sectionCatalog = (try? await deps.retrieveForSection(title, request.objective))
                .map { catalog.merging($0) } ?? catalog
            known = known.merging(sectionCatalog)

            onProgress(.init(
                phase: .writing,
                message: "Writing “\(title)”",
                sectionIndex: index, sectionTotal: titles.count, sectionTitle: title,
                wordsSoFar: words
            ))

            do {
                let prose = try await deps.writeSection(request, title, index, titles.count, sectionCatalog, wordTarget)
                let validated = CitationValidator.validate(prose: prose, against: sectionCatalog)
                checked += validated.accepted.count + validated.rejected.count
                rejected += validated.rejected.count
                let section = DeepResearchSection(
                    title: title,
                    prose: validated.prose,
                    citations: validated.accepted,
                    rejectedCitations: validated.rejected
                )
                sections.append(section)
                words += section.wordCount
                // After the call has been paid for, not before.
                onCheckpoint(currentCheckpoint())
            } catch is CancellationError {
                throw DeepResearchError.cancelled
            } catch {
                // One failed section does not throw away the ones already paid for. The report
                // says which section is missing rather than pretending it was never planned.
                stoppedReason = "Section “\(title)” failed: \(error.localizedDescription)"
                break
            }
        }

        try Task.checkCancellation()
        onProgress(.init(
            phase: .assembling,
            message: "Assembling",
            sectionIndex: titles.count, sectionTotal: titles.count,
            wordsSoFar: words
        ))

        // What was really cited, in order of first appearance — never a list the model wrote.
        var seen = Set<String>()
        var cited: [CitationCatalog.Entry] = []
        for section in sections {
            for token in section.citations where seen.insert(token).inserted {
                guard let entry = known.entry(for: token) else { continue }
                cited.append(entry)
            }
        }

        // Naming the sources is the last thing that happens, and the only step that can reach
        // the corpus for something the prose does not contain. It runs once over the whole
        // report rather than once per section, so a book cited in six of them is looked up once.
        let labelling = await deps.describeCitations(cited)
        let named = sections.map { section in
            DeepResearchSection(
                title: section.title,
                prose: CitationRendering.linking(section.prose, labels: labelling.inline),
                citations: section.citations,
                rejectedCitations: section.rejectedCitations
            )
        }

        onProgress(.init(phase: .done, message: "Finished", wordsSoFar: words))

        return DeepResearchReport(
            objective: request.objective,
            sections: named,
            references: labelling.references,
            words: words,
            pages: Double(words) / Double(DeepResearchLimits.wordsPerPage),
            citationsChecked: checked,
            citationsRejected: rejected,
            stoppedReason: stoppedReason
        )
    }
}
