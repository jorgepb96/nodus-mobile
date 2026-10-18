import Foundation
import NodusKit
import Observation

/// Turns the ids inside a relation into the names a reader recognises.
///
/// An idea's `relations` are raw `edges` rows — `{from_id, to_id, relation}` — its
/// `occurrences` are `{global_id, nodus_id, role}`, and an author's are `author_relations`
/// rows of `{from_author, to_author, type, weight}`. None of them carries a label or a title,
/// so a list of them renders as a column of "Untitled" unless something resolves the ids first.
///
/// So: the mirror when there is one, and otherwise the fewest requests that will do it — one
/// ego graph for a whole relations list, one page for the whole author table, and only then a
/// request per id for whatever is still missing.
@Observable
@MainActor
final class CorpusNames {
    // WebKit can release the last reader session from a synchronous task-local
    // scope. Avoid Swift's inferred isolated-deinit back-deployment path (#88036).
    nonisolated deinit {}

    private var ideaLabels: [String: String] = [:]
    private var workTitles: [String: String] = [:]
    private var authorNames: [String: String] = [:]
    /// Ids a request has already been *spent* on. Only ids that were actually fetched go in
    /// here: the previous version marked every missing id asked and then fetched the first
    /// thirty, so on a screen with fifty-eight relations the rest said "Loading…" for the life
    /// of the session — and went on saying it after opening one of them proved they existed.
    private var asked: Set<String> = []
    private var loadedAllAuthors = false

    /// How many ids one round of requests may cover. A relations list resolves in a single
    /// graph request; this is the tail, and it runs in rounds until nothing is left rather
    /// than stopping at the first one.
    private static let batchSize = 12

    private let client: NodusClient
    private let spaceId: String

    init(client: NodusClient, spaceId: String) {
        self.client = client
        self.spaceId = spaceId
    }

    func idea(_ globalId: String) -> String? { ideaLabels[globalId] }
    func work(_ nodusId: String) -> String? { workTitles[nodusId] }
    func author(_ authorId: String) -> String? { authorNames[authorId] }

    /// Fills the cache from the offline copy in one pass. Free, and covers everything.
    func preload(from mirror: MirrorStore?) async {
        guard let mirror else { return }
        if let ideas = try? await mirror.page(table: "ideas", limit: 20_000).items {
            for row in ideas {
                guard let id = row.string("global_id") else { continue }
                ideaLabels[id] = row.text("label") ?? row.text("statement")
            }
        }
        if let works = try? await mirror.page(table: "works", limit: 20_000).items {
            for row in works {
                guard let id = row.string("nodus_id") else { continue }
                workTitles[id] = row.text("title")
            }
        }
        if let authors = try? await mirror.page(table: "authors", limit: 20_000).items {
            for row in authors {
                guard let id = row.string("author_id") else { continue }
                authorNames[id] = row.text("display_name") ?? row.text("name")
            }
        }
        loadedAllAuthors = !authorNames.isEmpty
    }

    /// Names every idea one hop from this one, in a single request.
    ///
    /// `/ideas/:id/graph?depth=1` answers with the neighbourhood's *rows*, not just its edges,
    /// which is exactly what a relations list needs. Fifty-eight relations used to mean
    /// fifty-eight round trips, capped at thirty; now they mean one.
    func resolveNeighbours(ofIdea globalId: String) async {
        guard !globalId.isEmpty, !asked.contains("g:\(globalId)") else { return }
        asked.insert("g:\(globalId)")
        do {
            let graph = try await client.ideaGraph(globalId, in: spaceId, depth: 1, limit: PageBounds.graphMaxLimit)
            for row in graph.ideas {
                guard let id = row.string("global_id") else { continue }
                ideaLabels[id] = row.text("label") ?? row.text("statement") ?? id
            }
        } catch {
            // A failed graph is not a resolved one: let the per-id tail try, and let a later
            // visit ask again.
            asked.remove("g:\(globalId)")
        }
    }

    /// Names every author in the space with one page request.
    ///
    /// `author_relations` rows name the other author by id and nothing else, and there are only
    /// ever hundreds of authors, so the whole table is cheaper than resolving one dossier's
    /// relations one at a time.
    func preloadAuthors() async {
        guard !loadedAllAuthors, let authors = Collections["authors"] else { return }
        var offset = 0
        while offset < 2_000 {
            do {
                let page = try await client.list(authors, in: spaceId, limit: PageBounds.maxLimit, offset: offset)
                for row in page.items {
                    guard let id = row.string("author_id") else { continue }
                    authorNames[id] = row.text("display_name") ?? row.text("name") ?? id
                }
                guard page.hasMore, !page.items.isEmpty else { break }
                offset += page.items.count
            } catch {
                return
            }
        }
        loadedAllAuthors = true
    }

    /// Resolves whatever is still missing, over the network, a handful at a time.
    ///
    /// Every id given is either resolved or left un-asked, and the rounds continue until the
    /// list is exhausted. A row that exists but has no name at all caches its id, because a
    /// reader can act on an id and cannot act on "Loading…" forever.
    func resolve(ideaIds: [String] = [], workIds: [String] = [], authorIds: [String] = []) async {
        await resolveMissing(
            ideaIds.filter { ideaLabels[$0] == nil },
            prefix: "i",
            collection: Collections["ideas"],
            name: { $0.text("label") ?? $0.text("statement") },
            store: { self.ideaLabels[$0] = $1 }
        )
        await resolveMissing(
            workIds.filter { workTitles[$0] == nil },
            prefix: "w",
            collection: Collections["works"],
            name: { $0.text("title") },
            store: { self.workTitles[$0] = $1 }
        )
        await resolveMissing(
            authorIds.filter { authorNames[$0] == nil },
            prefix: "a",
            collection: Collections["authors"],
            name: { $0.text("display_name") ?? $0.text("name") },
            store: { self.authorNames[$0] = $1 }
        )
    }

    private enum Outcome: Sendable {
        case named(String)
        /// A 404: the row the relation points at is not in this publication.
        case gone
        case failed
    }

    private func resolveMissing(
        _ ids: [String],
        prefix: String,
        collection: CollectionDescriptor?,
        name: @escaping @Sendable (Row) -> String?,
        store: (String, String) -> Void
    ) async {
        guard let collection else { return }
        // In the order the screen shows them, deduplicated: the list fills from the top rather
        // than in whatever order a Set happened to hash into.
        var seen = Set<String>()
        let wanted = ids.filter { id in
            !id.isEmpty && !asked.contains("\(prefix):\(id)") && seen.insert(id).inserted
        }
        guard !wanted.isEmpty else { return }

        for batch in stride(from: 0, to: wanted.count, by: Self.batchSize).map({
            Array(wanted[$0..<min($0 + Self.batchSize, wanted.count)])
        }) {
            for id in batch { asked.insert("\(prefix):\(id)") }
            let found = await withTaskGroup(of: (String, Outcome).self) { group in
                for id in batch {
                    group.addTask { [client, spaceId] in
                        do {
                            let row = try await client.item(collection, id: id, in: spaceId)
                            // Found, but nameless: the id is the only honest label left, and
                            // it is one the reader can match against the row they opened.
                            return (id, .named(name(row) ?? id))
                        } catch let error as APIError where error.isNotFound {
                            // The row is gone. Asked once, never again.
                            return (id, .gone)
                        } catch {
                            return (id, .failed)
                        }
                    }
                }
                var results: [(String, Outcome)] = []
                for await result in group { results.append(result) }
                return results
            }
            for (id, outcome) in found {
                switch outcome {
                case .named(let value): store(id, value)
                case .gone: break
                // The request never got an answer. Forget that it was asked, so returning to
                // the screen tries again instead of showing "Loading…" for the whole session.
                case .failed: asked.remove("\(prefix):\(id)")
                }
            }
        }
    }
}
