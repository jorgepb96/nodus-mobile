import Foundation
import NodusAI
import NodusKit

/// One search, run the best way this device and this vault allow.
///
/// The Search tab was lexical by construction: the query vector existed only inside the chat
/// and Deep Research paths, and the screen never asked for one. So a vault indexed with a key
/// the phone actually holds still answered synonyms with nothing, and said so in a footnote
/// nobody could act on.
///
/// The decision this type makes, in order:
///
///  1. No published vectors → lexical, and the vault is not at fault.
///  2. Vectors indexed with a desktop runtime → lexical, because a phone cannot reach Ollama.
///  3. Vectors this device *could* match but has no key for → lexical, and now the message
///     names the key to add. That case is the reason this exists.
///  4. Otherwise → embed the query and rank against the published matrix.
///
/// Every collaborator is a closure for the same reason `DeepResearchDeps` is: the table above
/// is the whole feature, and it should be testable without a server or a provider account.
struct CorpusSearch: Sendable {
    var identity: EmbeddingIdentity?
    var availability: @Sendable (EmbeddingIdentity) -> Result<AIProvider, EmbeddingService.Unavailability>
    var embed: @Sendable (String, EmbeddingIdentity) async throws -> [Float]
    var semantic: @Sendable (_ query: String, _ vector: [Float], _ identity: EmbeddingIdentity, _ kind: VectorKind, _ limit: Int) async throws -> SemanticSearchOutcome
    var lexical: @Sendable (_ query: String, _ limit: Int) async throws -> [LexicalSearchResults.Hit]

    enum Mode: String, Sendable, Equatable {
        case semantic
        case lexical
    }

    struct Hit: Sendable, Identifiable, Equatable {
        let id: String
        /// Always singular — `idea`, `passage`, `work`. The two endpoints disagree about this:
        /// the semantic one names the record and the lexical one names the *table*, so a
        /// lexical hit arrived as `passages` and fell through every `case "passage"` in the UI.
        let type: String
        let title: String?
        let excerpt: String?
        /// A passage's own coordinates. Neither is in its text, and both are what make a
        /// quotation worth reading: which work it was cut from, and where in it.
        let workId: String?
        let page: String?
        /// Only a semantic hit has one. A lexical hit is a substring match, not a distance.
        let score: Double?

        init(
            id: String,
            type: String,
            title: String?,
            excerpt: String?,
            workId: String? = nil,
            page: String? = nil,
            score: Double?
        ) {
            self.id = id
            self.type = type
            self.title = title
            self.excerpt = excerpt
            self.workId = workId
            self.page = page
            self.score = score
        }
    }

    struct Outcome: Sendable, Equatable {
        var hits: [Hit]
        var mode: Mode
        /// Why the search was not semantic — shown whenever there is one, because "no results"
        /// from a lexical search is a claim about spelling, not about the corpus.
        var warning: String?
        /// The same reason, still typed.
        ///
        /// `warning` is a sentence built inside NodusAI, which carries no string catalogue, so
        /// it reaches the screen in English on a Spanish phone. Keeping the case beside it lets
        /// the app say the same thing in the user's language and fall back to the sentence for
        /// anything that is not one of these three.
        var unavailability: EmbeddingService.Unavailability?
    }

    func run(_ query: String, limit: Int = 50, preference: Mode? = nil) async throws -> Outcome {
        // Desktop exposes the strategy as a real control and defaults to literal text search.
        // Nil keeps the historical mobile "best available" behaviour for background callers.
        if preference == .lexical {
            return Outcome(hits: try await lexicalHits(query, limit), mode: .lexical, warning: nil)
        }
        guard let identity else {
            // No vectors at all. Not a fault, and the idle state already explains it.
            return Outcome(hits: try await lexicalHits(query, limit), mode: .lexical, warning: nil)
        }
        if case .failure(let reason) = availability(identity) {
            return Outcome(
                hits: try await lexicalHits(query, limit),
                mode: .lexical,
                warning: reason.explanation,
                unavailability: reason
            )
        }

        let vector: [Float]
        do {
            vector = try await embed(query, identity)
        } catch {
            // A bad key, a rate limit, a provider outage. Lexical still works, and naming what
            // went wrong beats an empty list the user cannot explain.
            return Outcome(hits: try await lexicalHits(query, limit), mode: .lexical, warning: error.localizedDescription)
        }

        // Ideas carry the argument; passages carry the evidence. The server keys the two
        // matrices separately, so they are two requests — the same pair the assistant makes.
        async let ideaOutcome = semantic(query, vector, identity, .ideas, min(limit, 40))
        async let passageOutcome = semantic(query, vector, identity, .passages, min(limit, 20))

        var hits: [Hit] = []
        var warning: String?
        for outcome in [try await ideaOutcome, try await passageOutcome] {
            switch outcome {
            case .indexed(let found, _, _):
                hits.append(contentsOf: found.compactMap(Self.hit(from:)))
            case .notIndexed(_, let message), .mismatch(_, _, _, let message):
                // Never swallowed: the server is saying the search did not really run.
                warning = message
            }
        }

        guard !hits.isEmpty else {
            return Outcome(hits: try await lexicalHits(query, limit), mode: .lexical, warning: warning)
        }
        return Outcome(hits: Array(Self.ordered(hits).prefix(limit)), mode: .semantic, warning: warning)
    }

    private func lexicalHits(_ query: String, _ limit: Int) async throws -> [Hit] {
        Self.ordered(try await lexical(query, limit).map { hit in
            // The lexical endpoint names the table it matched in — `passages`, `ideas` — while
            // the semantic one and every citation name the record: `passage`, `idea`.
            // `CorpusReference` already owns that mapping, so using it here means one
            // vocabulary reaches the screen instead of two that nearly agree.
            let reference = CorpusReference(kind: hit.type, recordId: hit.id)
            return Hit(
                id: reference.id,
                type: reference.kind,
                title: hit.title,
                excerpt: hit.excerpt,
                score: nil
            )
        })
    }

    /// Ideas first, passages last, and the score deciding only within a kind.
    ///
    /// It used to be one ranking across both matrices, on the argument that a merged order
    /// sorts by meaning rather than by which matrix answered. In use that reads badly: a
    /// passage is a raw chunk of somebody's PDF, several hundred characters of it, and three
    /// of them above the first idea buries what the corpus actually derived. Ideas carry the
    /// argument, works name where it lives, and passages are the evidence underneath — which
    /// is the order a reader wants them in, and the order the assistant already builds its
    /// context in.
    static func ordered(_ hits: [Hit]) -> [Hit] {
        hits.enumerated().sorted { lhs, rhs in
            let left = rank(lhs.element.type), right = rank(rhs.element.type)
            if left != right { return left < right }
            let leftScore = lhs.element.score ?? 0, rightScore = rhs.element.score ?? 0
            if leftScore != rightScore { return leftScore > rightScore }
            // A lexical hit has no score at all, so without this the order would be whatever
            // the sort happened to do. This keeps the server's.
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    static func rank(_ type: String) -> Int {
        switch type {
        case "idea": return 0
        case "work": return 1
        case "theme": return 2
        case "gap": return 3
        case "note": return 4
        case "passage": return 9
        default: return 5
        }
    }

    /// The same reading of a semantic row the citation catalogue makes, so a hit in Search and
    /// a citation in a report name the same thing the same way.
    static func hit(from hit: SemanticHit) -> Hit? {
        let row = hit.row
        if let id = row.string("global_id") {
            return Hit(
                id: "idea/\(id)",
                type: "idea",
                title: row.text("label") ?? row.text("statement"),
                excerpt: row.text("statement"),
                score: hit.score
            )
        }
        if let id = row.string("passage_id") {
            // `String((row.text("text") ?? "").prefix(80))` was the old title, and when the row
            // carried no text that is the empty string — not nil. `Text("")` draws a blank
            // line, which is how a passage hit came to show its type chip and nothing else.
            // A passage's headline is its source anyway, not the first eighty characters of
            // itself, and the source is these two columns.
            return Hit(
                id: "passage/\(id)",
                type: "passage",
                title: row.text("section") ?? row.text("heading"),
                excerpt: row.text("text") ?? row.text("content"),
                workId: row.string("nodus_id"),
                page: pageLabel(row),
                score: hit.score
            )
        }
        if let id = row.string("nodus_id") {
            return Hit(
                id: "work/\(id)",
                type: "work",
                title: row.text("title"),
                excerpt: row.text("year"),
                score: hit.score
            )
        }
        return nil
    }

    /// Where in the work a passage sits, in whichever column this vault names it.
    ///
    /// `page_label` is the published one (`migrations.ts:474`); the rest are what other
    /// vintages of the pipeline wrote, and reading only the first meant a passage with a page
    /// showed none.
    static func pageLabel(_ row: Row) -> String? {
        if let label = row.text("page_label") ?? row.text("page") ?? row.text("location") {
            // "231" alone is a number in a row of numbers. "p. 231" is a page.
            return Int(label) != nil ? "p. \(label)" : label
        }
        if let page = row.int("page") { return "p. \(page)" }
        if let chunk = row.int("chunk_index") { return "#\(chunk)" }
        return nil
    }
}

extension CorpusSearch {
    /// Wired to a real space.
    static func live(
        client: NodusClient,
        spaceId: String,
        embeddings: EmbeddingService,
        identity: EmbeddingIdentity?
    ) -> CorpusSearch {
        CorpusSearch(
            identity: identity,
            availability: { embeddings.availability(for: $0) },
            embed: { query, identity in try await embeddings.embed(query, as: identity) },
            semantic: { query, vector, identity, kind, limit in
                try await client.semanticSearch(
                    query: query,
                    vector: vector,
                    identity: identity,
                    kind: kind,
                    in: spaceId,
                    limit: limit
                )
            },
            lexical: { query, limit in
                try await client.search(query, in: spaceId, limit: limit).results
            }
        )
    }
}
