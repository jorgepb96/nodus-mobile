import Foundation
import NodusAI
import NodusKit
import Testing
@testable import Nodus

// The module defaults to the main actor; these are reached from the `@Sendable` closures a
// `CorpusSearch` is made of, so they have to live outside the suite.
private nonisolated let identity = EmbeddingIdentity(provider: "openrouter", model: "baai/bge-m3", dim: 1024)

/// Built from JSON because that is how the client builds one: the type is `Decodable` with no
/// memberwise initialiser, which keeps a test from inventing a shape the server never sends.
private nonisolated func lexicalHit(_ id: String, _ title: String) -> LexicalSearchResults.Hit {
    let json = """
    {"type":"work","id":"\(id)","title":"\(title)","excerpt":"Un extracto"}
    """
    return try! JSONDecoder().decode(LexicalSearchResults.Hit.self, from: Data(json.utf8))
}

/// A lexical hit as the server really sends one: `type` is the *table* it matched in.
private nonisolated func tableHit(type: String, id: String, title: String) -> LexicalSearchResults.Hit {
    let json = """
    {"type":"\(type)","id":"\(id)","title":"\(title)","excerpt":"Un extracto"}
    """
    return try! JSONDecoder().decode(LexicalSearchResults.Hit.self, from: Data(json.utf8))
}

private nonisolated func semanticHit(ideaId: String, label: String, score: Double) -> SemanticHit {
    let json = """
    {"id":"\(ideaId)","score":\(score),"row":{"global_id":"\(ideaId)","label":"\(label)","statement":"Un enunciado"}}
    """
    return try! JSONDecoder.nodus.decode(SemanticHit.self, from: Data(json.utf8))
}

private nonisolated func passageHit(_ id: String, score: Double) -> SemanticHit {
    let json = """
    {"id":"\(id)","score":\(score),"row":{"passage_id":"\(id)","text":"Un pasaje","section":"Capítulo 2"}}
    """
    return try! JSONDecoder.nodus.decode(SemanticHit.self, from: Data(json.utf8))
}

/// Which search runs, and what the user is told when it is not the one they wanted.
///
/// The behaviour that matters is not "semantic search works" — it is that the app never lets an
/// empty lexical result stand as if it were a statement about the corpus. Every fallback here
/// has to carry a reason.
@Suite("Corpus search")
struct CorpusSearchTests {
    private func search(
        identity: EmbeddingIdentity?,
        availability: @escaping @Sendable (EmbeddingIdentity) -> Result<AIProvider, EmbeddingService.Unavailability> = { _ in .success(.openrouter) },
        embed: @escaping @Sendable (String, EmbeddingIdentity) async throws -> [Float] = { _, _ in [0.1, 0.2] },
        semantic: @escaping @Sendable (String, [Float], EmbeddingIdentity, VectorKind, Int) async throws -> SemanticSearchOutcome,
        lexical: @escaping @Sendable (String, Int) async throws -> [LexicalSearchResults.Hit] = { _, _ in [] }
    ) -> CorpusSearch {
        CorpusSearch(
            identity: identity,
            availability: availability,
            embed: embed,
            semantic: semantic,
            lexical: lexical
        )
    }

    @Test("a vault with vectors and a key is searched by meaning")
    func semanticWhenPossible() async throws {
        let subject = search(
            identity: identity,
            semantic: { _, _, _, kind, _ in
                .indexed(
                    hits: kind == .ideas
                        ? [semanticHit(ideaId: "i-1", label: "La escasez", score: 0.81)]
                        : [],
                    identity: identity,
                    indexable: 2000
                )
            },
            lexical: { _, _ in Issue.record("lexical must not run when the vectors answered"); return [] }
        )

        let outcome = try await subject.run("hambre")

        #expect(outcome.mode == .semantic)
        #expect(outcome.warning == nil)
        #expect(outcome.hits.map(\.id) == ["idea/i-1"])
        #expect(outcome.hits.first?.score == 0.81)
    }

    @Test("the Desktop text mode stays lexical even when semantic search is available")
    func explicitTextMode() async throws {
        let subject = search(
            identity: identity,
            embed: { _, _ in Issue.record("text mode must not spend an embedding call"); return [] },
            semantic: { _, _, _, _, _ in
                Issue.record("text mode must not reach the vector endpoint")
                return .notIndexed(fallback: [], warning: "")
            },
            lexical: { _, _ in [lexicalHit("w-1", "Una obra")] }
        )

        let outcome = try await subject.run("hambre", preference: .lexical)
        #expect(outcome.mode == .lexical)
        #expect(outcome.hits.map(\.id) == ["work/w-1"])
    }

    // The case this whole type exists for. Before it, a vault indexed with a provider the phone
    // could reach still searched lexically, and nothing on screen told the user that adding a
    // key would change that.
    @Test("a reachable provider with no key falls back, and the message names the key")
    func missingKeyIsNamed() async throws {
        let subject = search(
            identity: identity,
            availability: { _ in .failure(.missingKey(.openrouter)) },
            embed: { _, _ in Issue.record("must not try to embed without a key"); return [] },
            semantic: { _, _, _, _, _ in Issue.record("must not reach the server"); return .notIndexed(fallback: [], warning: "") },
            lexical: { _, _ in [lexicalHit("w-1", "Una obra")] }
        )

        let outcome = try await subject.run("hambre")

        #expect(outcome.mode == .lexical)
        #expect(outcome.hits.count == 1)
        let warning = try #require(outcome.warning)
        #expect(warning.contains("OpenRouter") || warning.lowercased().contains("openrouter"))
    }

    @Test("a vault indexed on the desktop falls back and says why")
    func desktopProviderIsExplained() async throws {
        let subject = search(
            identity: EmbeddingIdentity(provider: "ollama", model: "nomic", dim: 768),
            availability: { _ in .failure(.providerRunsOnDesktop("Ollama")) },
            semantic: { _, _, _, _, _ in .notIndexed(fallback: [], warning: "") },
            lexical: { _, _ in [lexicalHit("w-1", "Una obra")] }
        )

        let outcome = try await subject.run("hambre")
        #expect(outcome.mode == .lexical)
        #expect(outcome.warning?.contains("Ollama") == true)
    }

    @Test("a vault with no vectors is searched lexically, and that is not a fault")
    func noVectorsIsQuiet() async throws {
        let subject = search(
            identity: nil,
            semantic: { _, _, _, _, _ in Issue.record("there is nothing to search semantically"); return .notIndexed(fallback: [], warning: "") },
            lexical: { _, _ in [lexicalHit("w-1", "Una obra")] }
        )

        let outcome = try await subject.run("hambre")
        #expect(outcome.mode == .lexical)
        #expect(outcome.warning == nil, "the idle state already explains this; a warning would be noise")
    }

    @Test("a provider that refuses the embedding leaves lexical results and the provider's own words")
    func embeddingFailureIsReported() async throws {
        let subject = search(
            identity: identity,
            embed: { _, _ in throw EmbeddingError.http(status: 401, message: "Invalid API key") },
            semantic: { _, _, _, _, _ in Issue.record("no vector, no semantic request"); return .notIndexed(fallback: [], warning: "") },
            lexical: { _, _ in [lexicalHit("w-1", "Una obra")] }
        )

        let outcome = try await subject.run("hambre")
        #expect(outcome.mode == .lexical)
        #expect(outcome.warning == "Invalid API key")
        #expect(outcome.hits.count == 1)
    }

    // The server's own refusal is the one warning that must never be swallowed: it is the
    // server saying the search it was asked for did not happen.
    @Test("the server's mismatch warning survives to the screen")
    func serverWarningSurvives() async throws {
        let subject = search(
            identity: identity,
            semantic: { _, _, _, _, _ in
                .mismatch(
                    expected: EmbeddingIdentity(provider: "openai", model: "text-embedding-3-small", dim: 1536),
                    received: identity,
                    fallback: [],
                    warning: "This vault was indexed with openai/text-embedding-3-small."
                )
            },
            lexical: { _, _ in [lexicalHit("w-1", "Una obra")] }
        )

        let outcome = try await subject.run("hambre")
        #expect(outcome.mode == .lexical)
        #expect(outcome.warning == "This vault was indexed with openai/text-embedding-3-small.")
    }

    // Every idea before any passage, and the score deciding only within a kind. A merged
    // ranking put a raw chunk of somebody's PDF above the idea the corpus derived from it,
    // which is the opposite of what this app is for.
    @Test("ideas rank above passages, and the score orders each kind")
    func ideasComeFirst() async throws {
        let subject = search(
            identity: identity,
            semantic: { _, _, _, kind, _ in
                switch kind {
                case .ideas:
                    return .indexed(hits: [
                        semanticHit(ideaId: "i-low", label: "Lejana", score: 0.30),
                        semanticHit(ideaId: "i-high", label: "Cercana", score: 0.95),
                    ], identity: identity, indexable: 10)
                case .passages:
                    return .indexed(hits: [passageHit("p-1", score: 0.60)], identity: identity, indexable: 10)
                }
            }
        )

        let outcome = try await subject.run("hambre")
        #expect(outcome.hits.map(\.id) == ["idea/i-high", "idea/i-low", "passage/p-1"])
    }

    @Test("a lexical hit arrives named after its table, and is filed under the record it is")
    func lexicalTableNamesAreCanonicalised() async throws {
        let subject = search(
            identity: nil,
            semantic: { _, _, _, _, _ in .notIndexed(fallback: [], warning: "") },
            lexical: { _, _ in [
                tableHit(type: "passages", id: "w-9", title: "Una cita larga"),
                tableHit(type: "ideas", id: "i-2", title: "Una idea"),
            ] }
        )

        let outcome = try await subject.run("hambre")
        // Singular, and the idea ahead of the passage even though the server sent it second.
        #expect(outcome.hits.map(\.type) == ["idea", "passage"])
        #expect(outcome.hits.map(\.id) == ["idea/i-2", "passage/w-9"])
    }

    /// A passage whose row carries no text — the shape a space publishes when its owner keeps
    /// the extracted full text out of the publication, which is the default.
    @Test("a passage with no published text never renders as an empty line")
    func textlessPassageHasNoEmptyTitle() {
        let json = """
        {"id":"p-2","score":0.5,"row":{"passage_id":"p-2","nodus_id":"w-1","chunk_index":4,"page_label":"231"}}
        """
        let hit = try! JSONDecoder.nodus.decode(SemanticHit.self, from: Data(json.utf8))
        let mapped = try! #require(CorpusSearch.hit(from: hit))

        // The old title was `String((nil ?? "").prefix(80))` — the empty string, which draws a
        // blank line and reads as a hit with nothing in it.
        #expect(mapped.title != "")
        #expect(mapped.excerpt == nil)
        #expect(mapped.workId == "w-1")
        #expect(mapped.page == "p. 231")
    }

    @Test("a semantic search that returns nothing falls back rather than claiming silence")
    func emptySemanticFallsBack() async throws {
        let subject = search(
            identity: identity,
            semantic: { _, _, _, _, _ in .indexed(hits: [], identity: identity, indexable: 2000) },
            lexical: { _, _ in [lexicalHit("w-1", "Una obra")] }
        )

        let outcome = try await subject.run("hambre")
        #expect(outcome.mode == .lexical)
        #expect(outcome.hits.count == 1)
    }
    @Test("one linked search deduplicates a canonical result and retains literal matches when meaning search fails")
    func unifiedLinkedSearch() async throws {
        var subject = search(identity: nil,
            semantic: { _, _, _, _, _ in Issue.record("An iOS provider must not run for a linked search"); return .notIndexed(fallback: [], warning: "") },
            lexical: { _, _ in [tableHit(type: "ideas", id: "same", title: "Literal"), tableHit(type: "works", id: "work", title: "Source")] })
        let duplicate = CorpusSearch.Hit(id: "idea/same", type: "idea", title: "Related", excerpt: nil, score: 0.9)
        let related = CorpusSearch.Hit(id: "idea/other", type: "idea", title: "Synonym", excerpt: nil, score: 0.7)
        subject.linkedSemantic = { _, _ in [duplicate, related] }
        let outcome = try await subject.runUnified("concept")
        #expect(Set(outcome.hits.map(\.id)) == ["idea/same", "idea/other", "work/work"])
        #expect(outcome.hits.count == 3)
        subject.linkedSemantic = { _, _ in throw URLError(.notConnectedToInternet) }
        let offline = try await subject.runUnified("concept")
        #expect(offline.hits.count == 2); #expect(offline.warning != nil)
    }

}
