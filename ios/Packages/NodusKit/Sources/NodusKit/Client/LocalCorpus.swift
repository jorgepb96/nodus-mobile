import Foundation

/// A published corpus that answers for itself, with no server behind it.
///
/// This exists for exactly one thing: the example vault the app carries in its own bundle, so
/// that somebody who installs Nodus without a Nodus Server — which includes whoever reviews it
/// for the App Store — has something to open.
///
/// It answers `NodusClient.Request`s rather than offering a second API, and that is the whole
/// design. Every screen in this app reads through `SpaceSession.client`; a demo that served
/// itself some other way would need a second `SpaceSession`, and two of those would drift apart
/// within a release. So the seam is the client's own transport: `perform` asks this first, and
/// what comes back is the same JSON a server would have sent, decoded by the same code.
///
/// Building a response and immediately decoding it again is not free, and it is deliberate. The
/// alternative — returning typed values and bypassing the decoders — would mean the demo
/// exercised a different half of the client from the one that ships, and the half it skipped is
/// the half that has ever been wrong.
///
/// The shapes are `server/lib/routes/corpus.mjs` and `server/lib/core/*.mjs`. Where this cannot
/// reproduce something the server does, it says so out loud rather than answering with an empty
/// list: an unsupported route throws, because "there is nothing here" and "this cannot be
/// answered without a server" are different claims and only one of them is true.
public struct LocalCorpus: Sendable {
    /// What the space calls itself. There is no server to ask, so this is stated by whoever
    /// built the corpus.
    public struct Space: Sendable, Hashable {
        public let id: String
        public let name: String
        public let description: String?

        public init(id: String, name: String, description: String? = nil) {
            self.id = id
            self.name = name
            self.description = description
        }
    }

    private let space: Space
    private let mirror: MirrorStore
    /// The publication exactly as it was compiled in, gzipped.
    ///
    /// Held so `GET .../snapshot` can be answered with the same bytes a download would have
    /// produced — which is what makes the offline-copy control on the settings screen tell the
    /// truth instead of failing at a device that already holds the corpus.
    private let archive: Data

    public init(space: Space, mirror: MirrorStore, archive: Data) {
        self.space = space
        self.mirror = mirror
        self.archive = archive
    }

    // MARK: - Routing

    /// `/api/v1/spaces/<id>`, encoded the way `ServerAddress.spacePath` encodes it, because
    /// that is what the caller built the path from.
    private var spacePrefix: String {
        "/api/v1/spaces/\(space.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? space.id)"
    }

    func answer(_ request: NodusClient.Request) async throws -> NodusClient.Response {
        if request.path == "/healthz" { return try json(health) }
        if request.path == "/api/v1/capabilities" { return try json(capabilities) }

        guard request.path == spacePrefix || request.path.hasPrefix("\(spacePrefix)/") else {
            throw Self.unavailable
        }
        let segments = request.path
            .dropFirst(spacePrefix.count)
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }

        let revision = try await self.revision
        switch segments.first {
        case nil:
            return try json(await overview(revision: revision))

        case "snapshot":
            // HEAD is how the mirror asks whether it is stale. It never is: the corpus and the
            // publication are the same file, and the file cannot change without a new build.
            let headers = ["x-nodus-revision": revision]
            return NodusClient.Response(
                data: request.method == "HEAD" ? Data() : archive,
                status: 200,
                headers: headers,
                fromCache: false
            )

        case "search" where segments.count == 1:
            return try json([
                "results": .array(try await lexicalSearch(
                    request.value(of: "q"),
                    limit: PageBounds.clampedLimit(
                        request.number(of: "limit"),
                        max: PageBounds.searchMaxLimit,
                        fallback: PageBounds.searchDefaultLimit
                    )
                )),
                "mode": .string("lexical"),
                "revision": .string(revision),
            ])

        case "search" where segments.count == 2 && segments[1] == "semantic":
            return try json(await semanticRefusal(request, revision: revision))

        case "context":
            return try json(await context(request, revision: revision))

        case "debates":
            return try json(await debates(segments, revision: revision))

        case "notes":
            return try json(await notes(segments, request: request, revision: revision))

        case "deep-research":
            // The corpus carries no saved drafts, and a report written on this device is kept
            // by `LocalReportStore` rather than by a vault. An empty page is the honest answer
            // and the one the Research screen is written for.
            guard segments.count == 1 else { throw Self.notFound }
            return try json(Self.page("reports", [], limit: 100, offset: 0, revision: revision))

        case "immersion":
            guard segments.count == 1 else { throw Self.notFound }
            return try json(Self.page("sessions", [], limit: 100, offset: 0, revision: revision))

        case let head? where Collections.byPath[head] != nil:
            return try json(await collection(Collections.byPath[head]!, segments, request: request, revision: revision))

        default:
            throw Self.unavailable
        }
    }

    // MARK: - The space

    private var revision: String {
        get async throws { try await mirror.summary()?.revision ?? "" }
    }

    private func overview(revision: String) async throws -> [String: JSONValue] {
        let summary = try await mirror.summary()
        let counts = try await mirror.tableCounts()
        return [
            "space": .object([
                "id": .string(space.id),
                "name": .string(space.name),
                "description": space.description.map(JSONValue.string) ?? .null,
                "updatedAt": summary.map { .string(ISO8601DateFormatter.nodusFractional.string(from: $0.importedAt)) } ?? .null,
                "revision": .string(revision),
            ]),
            "vault": .object([
                "name": summary?.vaultName.map(JSONValue.string) ?? .null,
                "type": summary?.vaultType.map { .string($0.rawValue) } ?? .null,
            ]),
            "schemaVersion": summary?.schemaVersion.map { .int(Int64($0)) } ?? .int(0),
            "snapshotFormatVersion": .int(Int64(summary?.formatVersion ?? SnapshotFormat.supportedVersions.max() ?? 2)),
            "generatedAt": summary.map { .string(ISO8601DateFormatter.nodusFractional.string(from: $0.importedAt)) } ?? .null,
            // No image ever travels in this corpus: `collectSnapshotAssets` finds nothing in a
            // vault with no portraits and no illustrations, and the bundle carries no bytes.
            "assets": .int(0),
            "counts": .object(counts.mapValues { .int(Int64($0)) }),
        ]
    }

    /// What a device with no server can honestly claim about itself.
    ///
    /// The diagnostics screen reads this, and every "no" here is a fact rather than a
    /// placeholder: nothing can be sent, no vectors were published, and no asset exists.
    private var capabilities: [String: JSONValue] {
        [
            "api": .string("v1"),
            "version": .string(NodusVersion.current),
            "server": .object([
                "name": .string(space.name),
                "publicUrl": .null,
                "language": .null,
                "version": .string(NodusVersion.current),
            ]),
            "snapshotVersions": .array(SnapshotFormat.supportedVersions.sorted().map { .int(Int64($0)) }),
            "assets": .bool(false),
            "mutations": .bool(false),
            "vectors": .bool(false),
            "resources": .object([:]),
            "maxAssetBytes": .int(0),
            "maxSpaceAssetBytes": .int(0),
            "maxSnapshotBytes": .int(Int64(archive.count)),
            "maxSnapshotJsonBytes": .int(Int64(archive.count)),
            "maxMutationBatch": .int(0),
        ]
    }

    private var health: [String: JSONValue] {
        [
            "ok": .bool(true),
            "service": .string("nodus-demo"),
            "version": .string(NodusVersion.current),
            "language": .null,
        ]
    }

    // MARK: - Collections

    private func collection(
        _ descriptor: CollectionDescriptor,
        _ segments: [String],
        request: NodusClient.Request,
        revision: String
    ) async throws -> [String: JSONValue] {
        guard segments.count > 1 else {
            if request.value(of: "surface") == "workspace", descriptor.path == "ideas" {
                let page = AcademicWorkspaceProjection.ideaPage(
                    in: try await academicTables(),
                    query: request.value(of: "q") ?? "",
                    type: request.value(of: "type") ?? "",
                    sort: IdeaWorkspaceSort(rawValue: request.value(of: "sort") ?? "") ?? .label,
                    limit: PageBounds.clampedLimit(request.number(of: "limit"), max: 200, fallback: 80),
                    offset: PageBounds.clampedOffset(request.number(of: "offset")),
                    revision: revision
                )
                return try Self.encodedObject(page)
            }
            if request.value(of: "surface") == "workspace", descriptor.path == "authors" {
                let page = AcademicWorkspaceProjection.authorPage(
                    in: try await academicTables(),
                    query: request.value(of: "q") ?? "",
                    sort: AuthorWorkspaceSort(rawValue: request.value(of: "sort") ?? "") ?? .surname,
                    synthesis: AuthorSynthesisFilter(rawValue: request.value(of: "synthesis") ?? "") ?? .all,
                    limit: PageBounds.clampedLimit(request.number(of: "limit"), max: 100, fallback: 80),
                    offset: PageBounds.clampedOffset(request.number(of: "offset")),
                    revision: revision
                )
                return try Self.encodedObject(page)
            }
            // The mirror's own `LIKE` over every string in the row, which is the same scan the
            // server's `?q=` performs — that equivalence is why `searchable` is stored at all.
            let page = try await mirror.page(
                table: descriptor.table,
                query: request.value(of: "q"),
                limit: PageBounds.clampedLimit(request.number(of: "limit")),
                offset: PageBounds.clampedOffset(request.number(of: "offset"))
            )
            return [
                descriptor.listKey: .array(page.items.map { .object($0.columns) }),
                "total": .int(Int64(page.total)),
                "limit": .int(Int64(page.limit)),
                "offset": .int(Int64(page.offset)),
                "hasMore": .bool(page.hasMore),
                "revision": .string(revision),
            ]
        }

        let wanted = segments[1]
        if descriptor.path == "ideas", wanted == "routes", segments.count == 2 {
            return [
                "routes": .array(try await AcademicWorkspaceProjection.argumentRoutes(in: academicTables()).map {
                    try Self.encodedValue($0)
                }),
                "revision": .string(revision),
            ]
        }
        if descriptor.path == "authors", wanted == "matrix", segments.count == 2 {
            return [
                "matrix": try await Self.encodedValue(AcademicWorkspaceProjection.synthesisMatrix(in: academicTables())),
                "revision": .string(revision),
            ]
        }
        guard let row = try await find(wanted, in: descriptor) else { throw Self.notFound }

        switch descriptor.path {
        case "ideas" where segments.count > 2 && segments[2] == "graph":
            return try await ideaGraph(
                seed: wanted,
                depth: PageBounds.clampedDepth(request.number(of: "depth")),
                limit: PageBounds.clampedLimit(
                    request.number(of: "limit"),
                    max: PageBounds.graphMaxLimit,
                    fallback: PageBounds.graphMaxLimit
                ),
                revision: revision
            )
        case "ideas":
            return try await idea(row, id: wanted, revision: revision)
        case "works":
            return try await work(row, id: wanted, revision: revision)
        case "authors":
            if segments.count == 3, segments[2] == "dossier" {
                guard let dossier = try await AcademicWorkspaceProjection.authorDossier(in: academicTables(), authorId: wanted) else {
                    throw Self.notFound
                }
                return ["dossier": try Self.encodedValue(dossier), "revision": .string(revision)]
            }
            return try await author(row, id: wanted, revision: revision)
        default:
            guard segments.count == 2 else { throw Self.notFound }
            return [descriptor.detailKey: .object(row.columns), "revision": .string(revision)]
        }
    }

    private func academicTables() async throws -> [String: [Row]] {
        var tables: [String: [Row]] = [:]
        for table in AcademicWorkspaceProjection.tableNames {
            tables[table] = try await mirror.allRows(table: table)
        }
        return tables
    }

    /// The server matches on the declared key and falls back to `id`; so does this, or a row
    /// listed inside another dossier would open a 404 for half the tables.
    private func find(_ id: String, in descriptor: CollectionDescriptor) async throws -> Row? {
        if let row = try await mirror.row(table: descriptor.table, id: id) { return row }
        return try await mirror.allRows(table: descriptor.table)
            .first { $0.string(descriptor.idField) == id || $0.string("id") == id }
    }

    private func idea(_ row: Row, id: String, revision: String) async throws -> [String: JSONValue] {
        let relations = try await visibleEdges().filter { $0.string("from_id") == id || $0.string("to_id") == id }
        let occurrences = try await mirror.rows(table: "idea_occurrences", where: "global_id", equals: id)
        let evidence = try await mirror.rows(table: "evidence", where: "global_id", equals: id)
        let labels = try await mirror.allRows(table: "themes")
            .reduce(into: [String: String]()) { result, theme in
                guard let key = theme.string("theme_id"), let label = theme.text("label") else { return }
                result[key] = label
            }
        var themes: [String] = []
        for link in try await mirror.rows(table: "idea_theme_links", where: "global_id", equals: id) {
            guard let label = link.string("theme_id").flatMap({ labels[$0] }), !themes.contains(label) else { continue }
            themes.append(label)
        }
        return [
            "idea": .object(row.columns),
            "relations": .array(relations.map { .object($0.columns) }),
            "occurrences": .array(occurrences.map { .object($0.columns) }),
            "evidence": .array(evidence.map { .object($0.columns) }),
            "themes": .array(themes.map(JSONValue.string)),
            "revision": .string(revision),
        ]
    }

    private func work(_ row: Row, id: String, revision: String) async throws -> [String: JSONValue] {
        let occurrences = try await mirror.rows(table: "idea_occurrences", where: "nodus_id", equals: id)
        let ideaIds = Set(occurrences.compactMap { $0.string("global_id") })
        let ideas = try await mirror.allRows(table: "ideas").filter { ideaIds.contains($0.string("global_id") ?? "") }
        let summary = try await mirror.rows(table: "work_summaries", where: "nodus_id", equals: id).first
        let passages = try await mirror.rows(table: "passages", where: "nodus_id", equals: id).count
        return [
            // `authors` parsed out of `authors_json`, exactly as `worksById` does it, because
            // the detail screen prints the list and the raw column is a string.
            "work": .object(Self.withParsedAuthors(row)),
            "ideas": .array(ideas.map { .object($0.columns) }),
            "summary": summary.map { .object($0.columns) } ?? .null,
            "passages": .int(Int64(passages)),
            "revision": .string(revision),
        ]
    }

    private func author(_ row: Row, id: String, revision: String) async throws -> [String: JSONValue] {
        let links = try await mirror.rows(table: "work_authors", where: "author_id", equals: id)
        let workIds = Set(links.compactMap { $0.string("nodus_id") })
        let works = try await mirror.allRows(table: "works").filter { workIds.contains($0.string("nodus_id") ?? "") }
        let relations = try await mirror.allRows(table: "author_relations")
            .filter { $0.string("from_author") == id || $0.string("to_author") == id }
        let synthesis = try await mirror.rows(table: "author_dossier_synthesis", where: "author_id", equals: id).first
        return [
            "author": .object(row.columns),
            "works": .array(works.map { .object($0.columns) }),
            "relations": .array(relations.map { .object($0.columns) }),
            "synthesis": synthesis.map { .object($0.columns) } ?? .null,
            "revision": .string(revision),
        ]
    }

    /// Bounded breadth-first walk around one idea, from `corpus.mjs`'s `ideaGraph`.
    private func ideaGraph(seed: String, depth: Int, limit: Int, revision: String) async throws -> [String: JSONValue] {
        let edges = try await visibleEdges()
        var adjacency: [String: [Row]] = [:]
        for edge in edges {
            guard let from = edge.string("from_id"), let to = edge.string("to_id") else { continue }
            adjacency[from, default: []].append(edge)
            adjacency[to, default: []].append(edge)
        }

        var seen: Set<String> = [seed]
        var frontier = [seed]
        for _ in 0..<depth where seen.count < limit {
            var next: [String] = []
            for node in frontier {
                for edge in adjacency[node] ?? [] {
                    for candidate in [edge.string("from_id"), edge.string("to_id")].compactMap({ $0 }) {
                        guard !seen.contains(candidate), seen.count < limit else { continue }
                        seen.insert(candidate)
                        next.append(candidate)
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { break }
        }

        let ideas = try await mirror.allRows(table: "ideas").filter { seen.contains($0.string("global_id") ?? "") }
        let included = edges.filter {
            seen.contains($0.string("from_id") ?? "") && seen.contains($0.string("to_id") ?? "")
        }
        return [
            "seedId": .string(seed),
            "depth": .int(Int64(depth)),
            "ideas": .array(ideas.map { .object($0.columns) }),
            "edges": .array(included.map { .object($0.columns) }),
            "truncated": .bool(seen.count >= limit),
            "revision": .string(revision),
        ]
    }

    // MARK: - Notes

    private func notes(
        _ segments: [String],
        request: NodusClient.Request,
        revision: String
    ) async throws -> [String: JSONValue] {
        let all = try await mirror.allRows(table: "notes")
        guard segments.count > 1 else {
            let folder = request.value(of: "folderId")
            let kind = request.value(of: "kind")
            let needle = request.value(of: "q")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let folders = try await mirror.allRows(table: "note_folders")
            var folderIds: Set<String>?
            if let folder, request.value(of: "recursive") == "1" {
                var found: Set<String> = [folder]
                var changed = true
                while changed {
                    changed = false
                    for candidate in folders {
                        guard let id = candidate.string("id"), let parent = candidate.string("parent_id"),
                              found.contains(parent), !found.contains(id) else { continue }
                        found.insert(id); changed = true
                    }
                }
                folderIds = found
            }
            let filtered = all
                .filter { note in
                    guard let folder else { return true }
                    return folderIds?.contains(note.string("folder_id") ?? "") ?? (note.string("folder_id") == folder)
                }
                .filter { kind == nil || ($0.string("kind") ?? "markdown") == kind }
                .filter { needle == nil || needle!.isEmpty || $0.searchableText.lowercased().contains(needle!) }
                // The list carries a 240-character snippet rather than whole bodies, which is
                // what the cell shows and what keeps a corpus of long notes from arriving whole.
                .map { note -> Row in
                    var summary = Row()
                    for key in ["id", "title", "folder_id", "kind", "order_idx", "created_at", "updated_at"] {
                        summary.columns[key] = note.columns[key] ?? .null
                    }
                    summary.columns["snippet"] = .string(Self.snippet(note.text("content")))
                    return summary
                }
            var envelope = Self.page(
                "notes",
                filtered,
                limit: PageBounds.clampedLimit(request.number(of: "limit")),
                offset: PageBounds.clampedOffset(request.number(of: "offset")),
                revision: revision
            )
            envelope["folders"] = .array(folders.map { .object($0.columns) })
            envelope["counts"] = .object([
                "notes": .int(Int64(all.filter { ($0.string("kind") ?? "markdown") != "idea" }.count)),
                "ideas": .int(Int64(all.filter { $0.string("kind") == "idea" }.count)),
            ])
            return envelope
        }
        guard let note = all.first(where: { $0.string("id") == segments[1] }) else { throw Self.notFound }
        return ["note": .object(note.columns), "revision": .string(revision)]
    }

    // MARK: - Search and retrieval

    /// `lexicalSearch` from `server/lib/core/search.mjs`, field lists included.
    ///
    /// Ported rather than answered from the mirror's FTS index, which ranks differently and
    /// would make the same query return a different order offline from online. The table order
    /// here *is* the result order, and the limit cuts it.
    private static let searchFields: [(table: String, fields: [String])] = [
        ("works", ["title", "abstract", "citation"]),
        ("ideas", ["label", "statement"]),
        ("themes", ["label", "description"]),
        ("gaps", ["text", "description"]),
        ("notes", ["title", "content"]),
        ("passages", ["text"]),
        ("persons", ["display_name", "notes", "biography"]),
        ("places", ["name", "kind", "notes"]),
    ]

    private static let excerptCharacters = 600

    private func lexicalSearch(_ query: String?, limit: Int) async throws -> [JSONValue] {
        let needle = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let present = try await mirror.tableCounts()

        var results: [JSONValue] = []
        for (table, fields) in Self.searchFields {
            guard (present[table] ?? 0) > 0 else { continue }
            for row in try await mirror.allRows(table: table) {
                let text = fields.compactMap { row.string($0) }.joined(separator: "\n")
                guard text.lowercased().contains(needle) else { continue }
                // A hit with no id is a hit that cannot be opened, and `LexicalSearchResults.Hit`
                // will not decode without one. The server's own fallback chain stops at
                // `passage_id` (`search.mjs:44`), which leaves a matching theme with no id at
                // all — so the declared key of the table is consulted first here. That is a
                // divergence from the server, and the only one in this file: reproducing it
                // faithfully would mean reproducing a failure.
                guard let id = Collections.byTable[table].flatMap({ row.string($0.idField) })
                    ?? row.string("id")
                    ?? row.string("nodus_id")
                    ?? row.string("global_id")
                    ?? row.string("passage_id")
                else { continue }
                results.append(.object([
                    "type": .string(table),
                    "id": .string(id),
                    "title": .string(row.text("title") ?? row.text("label") ?? String(text.prefix(120))),
                    "excerpt": .string(String(text.prefix(Self.excerptCharacters))),
                ]))
                if results.count >= limit { return results }
            }
        }
        return results
    }

    /// `POST .../search/semantic` over a corpus that carries no vectors.
    ///
    /// The refusal is the point. The example vault publishes no embedding matrix — nothing here
    /// could compute one without a provider key, and the snapshot strips the columns anyway —
    /// so the answer is the server's own `not_indexed` shape with lexical results attached. The
    /// app already knows how to read that: it is what puts "No published vectors — search will
    /// be lexical" on Home, and it is true.
    private func semanticRefusal(_ request: NodusClient.Request, revision: String) async throws -> [String: JSONValue] {
        let input = (try? JSONDecoder().decode([String: JSONValue].self, from: request.body ?? Data())) ?? [:]
        let kind = input["kind"]?.stringValue ?? VectorKind.ideas.rawValue
        let limit = PageBounds.clampedLimit(input["limit"]?.intValue, max: PageBounds.semanticMaxLimit, fallback: 20)
        let table = kind == VectorKind.passages.rawValue ? "passages" : "ideas"
        let hits = try await lexicalSearch(input["query"]?.stringValue, limit: limit)
        let ids = Set(hits.compactMap { $0.objectValue?["type"]?.stringValue == table ? $0.objectValue?["id"]?.stringValue : nil })
        let idColumn = table == "passages" ? "passage_id" : "global_id"
        let fallback = try await mirror.allRows(table: table).filter { ids.contains($0.string(idColumn) ?? "") }

        return [
            "indexed": .bool(false),
            "reason": .string("not_indexed"),
            "kind": .string(kind),
            "results": .array(fallback.map { .object($0.columns) }),
            "warning": .string("This example vault carries no published vectors, so the search was lexical."),
            "revision": .string(revision),
        ]
    }

    /// `POST .../context` — the retrieval package a client-side chat is built from.
    ///
    /// The same budgeting the server does, including the order the sections are filled in:
    /// what does not fit is dropped and `truncated` says so, rather than the package quietly
    /// arriving short.
    private func context(_ request: NodusClient.Request, revision: String) async throws -> [String: JSONValue] {
        let input = (try? JSONDecoder().decode([String: JSONValue].self, from: request.body ?? Data())) ?? [:]
        let budget = min(Self.maxContextCharacters, max(1000, input["budget"]?.intValue ?? Self.maxContextCharacters))
        let requested = (input["include"]?.arrayValue ?? []).compactMap { $0.stringValue }
        let wanted = Set(requested.isEmpty ? ContextSectionKind.allCases.map(\.rawValue) : requested)

        let hits = try await lexicalSearch(input["query"]?.stringValue, limit: 200)
        let matched = Set(hits.compactMap { $0.objectValue?["id"]?.stringValue })

        var sections: [JSONValue] = []
        var used = 0
        var truncated = false
        func push(_ kind: String, _ rows: [Row]) {
            var kept: [JSONValue] = []
            for row in rows {
                let value = JSONValue.object(row.columns)
                let cost = (try? JSONEncoder().encode(value).count) ?? 0
                if used + cost > budget { truncated = true; break }
                used += cost
                kept.append(value)
            }
            guard !kept.isEmpty else { return }
            sections.append(.object(["kind": .string(kind), "items": .array(kept)]))
        }

        if wanted.contains("ideas") {
            push("ideas", try await mirror.allRows(table: "ideas").filter { matched.contains($0.string("global_id") ?? "") })
        }
        if wanted.contains("passages") {
            push("passages", try await mirror.allRows(table: "passages").filter { matched.contains($0.string("passage_id") ?? "") })
        }
        if wanted.contains("themes") {
            push("themes", try await mirror.allRows(table: "themes"))
        }
        if wanted.contains("gaps") {
            push("gaps", try await mirror.allRows(table: "gaps").filter { matched.contains($0.string("id") ?? "") })
        }
        if wanted.contains("works") {
            push("works", try await mirror.allRows(table: "works").filter { matched.contains($0.string("nodus_id") ?? "") })
        }

        let summary = try await mirror.summary()
        return [
            "sections": .array(sections),
            "stats": .object([
                "chars": .int(Int64(used)),
                "budget": .int(Int64(budget)),
                "truncated": .bool(truncated),
                "matched": .int(Int64(hits.count)),
            ]),
            "vault": .object([
                "name": summary?.vaultName.map(JSONValue.string) ?? .null,
                "type": summary?.vaultType.map { .string($0.rawValue) } ?? .null,
            ]),
            "revision": .string(revision),
            "citationScheme": .object([
                "idea": .string("nodus://idea/<global_id>"),
                "passage": .string("nodus://passage/<passage_id>"),
                "work": .string("nodus://work/<nodus_id>"),
            ]),
        ]
    }

    /// `MAX_CONTEXT_CHARS` on the server side of the same conversation.
    private static let maxContextCharacters = 120_000

    // MARK: - Shared helpers

    /// The `visible_edges` view: every edge no `edge_feedback` row has rejected, in either
    /// direction. Getting the reverse wrong would resurrect a debate the owner dismissed.
    func visibleEdges() async throws -> [Row] {
        let edges = try await mirror.allRows(table: "edges")
        let feedback = try await mirror.allRows(table: "edge_feedback")
        guard !feedback.isEmpty else { return edges }
        var rejected: Set<String> = []
        for row in feedback where row.string("verdict") == "rejected" {
            guard let type = row.string("type"), let from = row.string("from_id"), let to = row.string("to_id") else { continue }
            rejected.insert("\(type) \(from) \(to)")
            rejected.insert("\(type) \(to) \(from)")
        }
        return edges.filter { edge in
            guard let type = edge.string("type"), let from = edge.string("from_id"), let to = edge.string("to_id") else { return true }
            return !rejected.contains("\(type) \(from) \(to)")
        }
    }

    func rows(of table: String) async throws -> [Row] {
        try await mirror.allRows(table: table)
    }

    /// `page()` from `server/lib/core/snapshot.mjs`, `hasMore` computed from the slice that was
    /// actually cut rather than from the limit that was asked for.
    static func page(_ key: String, _ list: [Row], limit: Int, offset: Int, revision: String) -> [String: JSONValue] {
        let slice = list.count > offset ? Array(list[offset..<min(offset + limit, list.count)]) : []
        return [
            key: .array(slice.map { .object($0.columns) }),
            "total": .int(Int64(list.count)),
            "limit": .int(Int64(limit)),
            "offset": .int(Int64(offset)),
            "hasMore": .bool(offset + slice.count < list.count),
            "revision": .string(revision),
        ]
    }

    /// `authors_json` unpacked into an `authors` array, the one enrichment `worksById` applies
    /// before a work leaves the server.
    private static func withParsedAuthors(_ row: Row) -> [String: JSONValue] {
        var columns = row.columns
        columns["authors"] = row.embeddedJSON("authors_json") ?? .array([])
        return columns
    }

    private static func snippet(_ value: String?) -> String {
        let clean = (value ?? "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count <= 240 ? clean : "\(clean.prefix(239))…"
    }

    private static func encodedValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func encodedObject<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        guard case .object(let object) = try encodedValue(value) else {
            throw APIError(status: 500, code: "local_projection_encoding")
        }
        return object
    }

    private func json(_ value: [String: JSONValue]) throws -> NodusClient.Response {
        NodusClient.Response(
            data: try JSONEncoder().encode(value),
            status: 200,
            headers: [:],
            fromCache: false
        )
    }

    static let notFound = APIError(status: 404, code: "not_found")

    /// A route no corpus on a device can answer.
    ///
    /// Deliberately not an empty list. The example vault is complete — everything the app can
    /// read from a publication is here — and the routes that fall through are the ones that
    /// need an account or a server behind them. Saying "there is nothing here" about those
    /// would be a claim about the corpus, and it would be false.
    static let unavailable = APIError(
        status: 404,
        code: "demo_unavailable",
        message: "The example vault is on this device, so there is no server to answer this."
    )
}

private extension NodusClient.Request {
    func value(of name: String) -> String? {
        query.first { $0.name == name }?.value
    }

    func number(of name: String) -> Int? {
        value(of: name).flatMap(Int.init)
    }
}
