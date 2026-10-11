import Foundation

public extension NodusClient {
    /// `HEAD /api/v1/spaces/:id/snapshot` — is there a publication, and which revision is it?
    ///
    /// Cheap enough to call on every foreground: it answers with `x-nodus-revision` and an
    /// ETag and no body at all, which is how the mirror learns it is stale without moving a
    /// hundred megabytes to find out.
    func snapshotRevision(in spaceId: String) async throws -> String? {
        let response = try await perform(.init(method: "HEAD", path: address.spacePath(spaceId, "/snapshot")))
        return response.revision
    }

    /// `GET /api/v1/spaces/:id/snapshot` — the whole published projection, gzipped.
    ///
    /// This is what makes the app work on a plane, and it is also the only way to reach the
    /// tables that have no REST collection of their own — the worldbuilding ones, which the
    /// server searches but does not project.
    ///
    /// The body arrives as `application/vnd.nodus.snapshot+json` with `content-encoding: gzip`.
    /// URLSession usually inflates it in passing; when it has not, the bytes still carry the
    /// gzip magic and are unwrapped here.
    func snapshot(in spaceId: String, consultation: SnapshotConsultation? = nil) async throws -> SnapshotDownload {
        let response = try await perform(.init(
            method: "GET",
            path: address.spacePath(spaceId, "/snapshot"),
            query: hasDesktopBridge ? consultation.map { [.init(name: "projection", value: $0.rawValue)] } ?? [] : [],
            extraHeaders: ["Accept": SnapshotFormat.contentType]
        ))

        return try SnapshotDownload.read(response.data, revision: response.revision)
    }
}

/// Live Mac consultations can avoid transferring the complete passage corpus.
/// Older Macs ignore the projection query; callers still select the same tables locally.
public enum SnapshotConsultation: String, Sendable {
    case dictionary, sources
}

/// One image the publication carried, described by everything except its bytes.
///
/// `kind` identifies one explicitly publishable image domain: portraits, Deep Research,
/// world galleries, maps or image-valued database attachments. `key` holds the source row's
/// key columns, so a portrait's key is `[person_id]` and a world image's is `[image_id]`.
public struct SnapshotAssetRef: Sendable, Hashable, Codable {
    public let hash: String
    public let thumbHash: String?
    public let mime: String
    public let thumbMime: String?
    public let bytes: Int
    public let thumbBytes: Int?
    public let kind: String
    public let table: String
    public let key: [String]
}

public struct SnapshotDownload: Sendable {
    public let document: [String: JSONValue]
    public let formatVersion: Int
    public let revision: String?
    /// Compressed size, i.e. what actually crossed the network.
    public let byteCount: Int

    /// Reads a published snapshot from the bytes it arrived as, gzipped or not.
    ///
    /// Separate from the request that fetched it because the app also carries one in its own
    /// bundle — the example vault, which never crosses a network — and a second parser for it
    /// would be a second opinion about what a valid publication is.
    ///
    /// - Parameter revision: what the transport said the revision was, when there was a
    ///   transport. The document's own `revision` is the fallback, which is what a snapshot
    ///   read off disk relies on.
    public static func read(_ data: Data, revision: String? = nil) throws -> SnapshotDownload {
        let json = Gzip.isGzipped(data) ? try Gzip.inflate(data) : data
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: json) else {
            throw TransportError.malformedResponse(expected: "a snapshot document")
        }
        guard object["format"]?.stringValue == SnapshotFormat.identifier else {
            throw TransportError.malformedResponse(expected: "format \"\(SnapshotFormat.identifier)\"")
        }
        let version = object["formatVersion"]?.intValue ?? 0
        guard SnapshotFormat.supportedVersions.contains(version) else {
            // A newer server can publish a format this build does not read. Saying so beats
            // importing half of it and showing a corpus with holes in it.
            throw TransportError.malformedResponse(
                expected: "snapshot format version in \(SnapshotFormat.supportedVersions.sorted()), got \(version)"
            )
        }

        return SnapshotDownload(
            document: object,
            formatVersion: version,
            revision: revision ?? object["revision"]?.stringValue,
            byteCount: data.count
        )
    }

    public var vault: VaultDescriptor? {
        guard let raw = document["vault"]?.objectValue else { return nil }
        return VaultDescriptor(
            name: raw["name"]?.stringValue,
            type: raw["type"]?.stringValue.flatMap(VaultType.init(rawValue:))
        )
    }

    public var schemaVersion: Int? { document["schemaVersion"]?.intValue }
    public var generatedAt: String? { document["generatedAt"]?.stringValue }

    /// The image references the publication carried.
    ///
    /// This is the *only* place a client can learn which hash belongs to which row. The rows
    /// themselves do not carry it: a `person_portraits` row arrives with `focus_x`, `mime`,
    /// `scale` and so on, but its `blob` column is stripped and no hash replaces it. So a
    /// REST-only client can fetch `/assets/<hash>` perfectly well and has no way to find out
    /// what `<hash>` is — `createCorpusRoutes` even accepts an `assetHashesFor` helper and
    /// never calls it (`server/lib/routes/corpus.mjs:126`).
    ///
    /// Resolving portraits is therefore one of the things the offline mirror is *for*, not
    /// merely faster at.
    public var assetRefs: [SnapshotAssetRef] {
        (document["assets"]?.arrayValue ?? []).compactMap { value in
            guard
                let object = value.objectValue,
                let hash = object["hash"]?.stringValue,
                let table = object["table"]?.stringValue
            else { return nil }
            return SnapshotAssetRef(
                hash: hash,
                thumbHash: object["thumbHash"]?.stringValue,
                mime: object["mime"]?.stringValue ?? "application/octet-stream",
                thumbMime: object["thumbMime"]?.stringValue,
                bytes: object["bytes"]?.intValue ?? 0,
                thumbBytes: object["thumbBytes"]?.intValue,
                kind: object["kind"]?.stringValue ?? "",
                table: table,
                key: (object["key"]?.arrayValue ?? []).compactMap(\.stringValue)
            )
        }
    }

    /// Table name → rows, which is how the snapshot stores everything.
    public var tables: [String: [Row]] {
        guard let tables = document["tables"]?.objectValue else { return [:] }
        return tables.compactMapValues { value in
            value.arrayValue?.compactMap { $0.objectValue.map(Row.init) }
        }
    }

    public func rows(of table: String) -> [Row] {
        guard
            let tables = document["tables"]?.objectValue,
            let array = tables[table]?.arrayValue
        else { return [] }
        return array.compactMap { $0.objectValue.map(Row.init) }
    }

    /// Keeps the shared Dictionary renderer from copying the whole research
    /// corpus into WebKit. Its source checks need only the referenced ideas and
    /// passages; catalogue and relationship rows remain complete.
    public func dictionaryConsultationTables() -> [String: JSONValue] {
        guard let tables = document["tables"]?.objectValue else { return [:] }
        let names = ["dictionary_entries", "dictionary_evidence", "dictionary_versions", "dictionary_relations",
            "works", "authors", "work_authors", "work_themes", "themes", "zotero_tags", "work_zotero_tags",
            "collections", "work_collections", "idea_occurrences", "idea_theme_links", "author_relations", "author_dossier_synthesis"]
        var result = tables.filter { names.contains($0.key) }
        let evidence = tables["dictionary_evidence"]?.arrayValue ?? []
        var citations: [String: Set<String>] = [:]
        for row in evidence {
            if let kind = row.objectValue?["kind"]?.stringValue, let id = row.objectValue?["ref_id"]?.stringValue {
                citations[kind, default: []].insert(id)
            }
        }
        let citationPattern = try? NSRegularExpression(pattern: #"nodus://(idea|passage|work|gap|contradiction)/([^\s\)\]<>\"\?#]+(?:#[^\s\)\]<>\"\?]+)?)"#)
        for table in ["dictionary_entries", "dictionary_versions"] {
            for row in tables[table]?.arrayValue ?? [] {
                let text = row.objectValue?["content_markdown"]?.stringValue ?? ""
                for match in citationPattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                    guard let kindRange = Range(match.range(at: 1), in: text), let idRange = Range(match.range(at: 2), in: text) else { continue }
                    citations[String(text[kindRange]), default: []].insert(String(text[idRange]).removingPercentEncoding ?? String(text[idRange]))
                }
            }
        }
        for edge in tables["edges"]?.arrayValue ?? [] {
            guard let row = edge.objectValue, let id = row["id"]?.stringValue, citations["contradiction"]?.contains(id) == true else { continue }
            for field in ["from_id", "to_id"] {
                if let idea = row[field]?.stringValue { citations["idea", default: []].insert(idea) }
            }
        }
        for (table, kind, field) in [("ideas", "idea", "global_id"), ("passages", "passage", "passage_id"), ("gaps", "gap", "id"), ("edges", "contradiction", "id")] {
            let ids = citations[kind] ?? []
            if let rows = tables[table]?.arrayValue {
                result[table] = .array(rows.filter { row in row.objectValue?[field]?.stringValue.map(ids.contains) ?? false })
            }
        }
        return result
    }

    /// Source dossiers need the complete ideas and evidence for each work and
    /// author, including rows not cited by the current Dictionary version.
    /// Keep large passage bodies and unrelated/private vault domains out of
    /// this WebKit payload; their lookups use their own permission-aware route.
    public func sourceConsultationTables() -> [String: JSONValue] {
        guard let tables = document["tables"]?.objectValue else { return [:] }
        let names: Set<String> = ["works", "authors", "work_authors", "work_themes", "themes", "zotero_tags", "work_zotero_tags",
            "ideas", "idea_occurrences", "idea_theme_links", "evidence", "edges", "edge_feedback", "gaps",
            "work_summaries", "work_idea_synthesis", "author_relations", "author_dossier_synthesis", "work_metadata", "edge_traces"]
        return tables.filter { names.contains($0.key) }
    }

    public var tableNames: [String] {
        (document["tables"]?.objectValue?.keys).map(Array.init)?.sorted() ?? []
    }
}
