import NodusKit
import NodusUI
import SwiftUI

/// Catalogue pages are read on demand; only the chosen full dossiers commit.
struct CompanionCollectionDownloadsView: View {
    let session: SpaceSession
    @State private var path = ""
    @State private var query = ""
    @State private var rows: [Row] = []
    @State private var selected: [String: Row] = [:]
    @State private var catalogueRevision: String?
    @State private var pageRevision: String?
    @State private var total = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var days = 7
    @State private var includeImages = true
    @State private var includeFiles = false
    @State private var issue: String?
    @State private var saved = false
    @State private var progress: (done: Int, total: Int)?
    @State private var downloadTask: Task<Void, Never>?

    private var collections: [CollectionDescriptor] {
        Collections.all.filter { !["ideas", "dictionary"].contains($0.path) && (session.count(of: $0) ?? 1) > 0 }
    }
    private var collection: CollectionDescriptor? { Collections[path] }
    var body: some View {
        List {
            Section {
                Picker("Colección", selection: $path) {
                    ForEach(collections, id: \.path) { Text($0.label).tag($0.path) }
                }.disabled(progress != nil)
                Picker("Conservar la descarga", selection: $days) {
                    Text("7 días").tag(7); Text("30 días").tag(30)
                }.disabled(progress != nil)
                Toggle("Incluir imágenes", isOn: $includeImages).disabled(progress != nil)
                Toggle("Incluir archivos originales", isOn: $includeFiles).disabled(progress != nil)
            } footer: {
                Text("Se conserva el dossier completo de cada registro elegido y los recursos que marques, hasta 50 MB por descarga. Una base de datos incluye todas sus filas y celdas. Las fuentes enlazadas necesitan su propia descarga; no se copia automáticamente el vault entero. Los originales que faltan en el Mac no se incluyen.")
            }
            if let issue {
                Section {
                    Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("companion-collection-download-error")
                    if progress == nil { Button("Volver a cargar") { Task { await load() } } }
                }
            }
            if let progress {
                Section {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                    Text("Descargando \(progress.done) de \(progress.total)")
                    Button("Cancelar", role: .cancel) { downloadTask?.cancel() }
                }
            }
            if saved { Label("Dossiers disponibles sin conexión", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("companion-collection-download-ready") }
            if let collection {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        if let id = row.string(collection.idField) {
                            Button {
                                if selected[id] != nil { selected[id] = nil } else { selected[id] = row }
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: selected[id] != nil ? "checkmark.circle.fill" : "circle").foregroundStyle(session.accent)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(collection.presenter.title(row)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        if let subtitle = collection.presenter.subtitle(row), !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                }.frame(minHeight: 44)
                            }.disabled(progress != nil || saved)
                                .accessibilityIdentifier("companion-download-record-\(path)-\(id)")
                                .accessibilityValue(selected[id] != nil ? "Seleccionado" : "Sin seleccionar")
                        }
                    }
                    if loading { ProgressView("Cargando contenido del Mac…") }
                    if hasMore, !loading, progress == nil { Button("Mostrar más") { Task { await loadMore() } } }
                    if rows.isEmpty, !loading, issue == nil { Text("No hay registros que coincidan con esta búsqueda.").foregroundStyle(.secondary) }
                } header: { Text("\(collection.label) · \(rows.count) de \(total) · \(selected.count) seleccionados") }
            }
        }
        .navigationTitle("Llevar dossiers contigo").navigationBarTitleDisplayMode(.inline)
        .searchable(text: Binding(get: { query }, set: { if progress == nil { query = $0 } }), prompt: "Buscar en la colección")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Descargar") { downloadTask = Task { await download() } }
                    .disabled(selected.isEmpty || loading || progress != nil || saved)
                    .accessibilityIdentifier("companion-collection-download-start")
            }
        }
        .onChange(of: path) { _, _ in selected = [:]; catalogueRevision = nil; query = ""; saved = false }
        .task(id: "\(path)|\(query)") {
            if path.isEmpty { path = collections.first?.path ?? ""; return }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .onDisappear { downloadTask?.cancel() }
    }

    private func connection() throws -> (String, DesktopBridgeClient, PrivateBridgeCache) {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
        return (vault, DesktopBridgeClient(pairing: pairing, token: token), try PrivateBridgeCache(pairingId: pairing.id))
    }
    private func load() async {
        guard let collection else { return }
        let loadingPath = path, loadingQuery = query
        loading = true; issue = nil; saved = false; rows = []; pageRevision = nil; total = 0; hasMore = false
        defer { if path == loadingPath, query == loadingQuery { loading = false } }
        do {
            let (vault, client, _) = try connection()
            let revision = try await session.client.snapshotRevision(in: session.connection.spaceId)
            let value = try await cataloguePage(client, vault: vault, collection: collection, query: loadingQuery, offset: 0)
            let current = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard current == revision else { throw DesktopBridgeError.malformedResponse }
            try Task.checkCancellation()
            guard path == loadingPath, query == loadingQuery else { return }
            if let catalogueRevision, catalogueRevision != revision { selected = [:] }
            catalogueRevision = revision; pageRevision = value.revision; rows = value.rows; total = value.total; hasMore = value.hasMore
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { if path == loadingPath, query == loadingQuery { issue = error.localizedDescription } }
    }
    private func loadMore() async {
        guard !loading, hasMore, let collection else { return }
        let loadingPath = path, loadingQuery = query, offset = rows.count, expectedRevision = pageRevision, expectedTotal = total
        loading = true
        defer { if path == loadingPath, query == loadingQuery { loading = false } }
        do {
            let (vault, client, _) = try connection()
            let value = try await cataloguePage(client, vault: vault, collection: collection, query: loadingQuery, offset: offset)
            try Task.checkCancellation()
            guard path == loadingPath, query == loadingQuery else { return }
            guard value.revision == expectedRevision, value.total == expectedTotal,
                  Set(rows.compactMap { $0.string(collection.idField) }).isDisjoint(with: value.rows.compactMap { $0.string(collection.idField) }) else { throw DesktopBridgeError.malformedResponse }
            rows += value.rows; hasMore = value.hasMore
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch { if path == loadingPath, query == loadingQuery { issue = error.localizedDescription } }
    }
    private func cataloguePage(_ client: DesktopBridgeClient, vault: String, collection: CollectionDescriptor, query: String, offset: Int) async throws -> (rows: [Row], total: Int, hasMore: Bool, revision: String) {
        var items = [URLQueryItem(name: "limit", value: "60"), URLQueryItem(name: "offset", value: String(offset))]
        if !query.isEmpty { items.append(.init(name: "q", value: query)) }
        let response = try await client.corpus(vaultId: vault, path: collection.path, query: items)
        let object = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data).objectValue
        guard let values = object?[collection.listKey]?.arrayValue, values.allSatisfy({ $0.objectValue != nil }),
              let total = object?["total"]?.intValue, total >= 0, object?["offset"]?.intValue == offset,
              let hasMore = object?["hasMore"]?.boolValue, offset + values.count <= total,
              hasMore == (offset + values.count < total), !values.isEmpty || !hasMore,
              let revision = object?["revision"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
        let rows = values.map { Row($0.objectValue!) }, ids = rows.compactMap { $0.string(collection.idField) }
        guard ids.count == rows.count, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw DesktopBridgeError.malformedResponse }
        return (rows, total, hasMore, revision)
    }

    private func download() async {
        guard let collection else { return }
        let chosen = selected, selectedDays = days, downloadImages = includeImages, downloadFiles = includeFiles
        issue = nil; progress = (0, chosen.count)
        defer { progress = nil }
        do {
            let (vault, client, cache) = try connection()
            let (_, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
            let revision = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard revision == catalogueRevision else { throw DesktopBridgeError.malformedResponse }
            var entries: [JSONValue] = [], sources: [PrivateBridgeCache.ReadPackRecord] = [], bytes = 0
            if let workshop = try await workshopDownloadRecord(client: client, vault: vault, path: collection.path, ids: chosen.keys.sorted()) {
                sources.append(workshop); bytes += workshop.data.count
            }
            func retain(_ method: String, _ args: [JSONValue], _ value: JSONValue) throws {
                let data = try JSONEncoder.nodus.encode(value); bytes += data.count
                guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                sources.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey(method, args), data: data))
            }
            func appendDependencies(_ incoming:[PrivateBridgeCache.ReadPackRecord]) throws {
                for record in incoming {
                    if let index=sources.firstIndex(where:{$0.domain == record.domain && $0.recordId == record.recordId}) {
                        guard record.recordId == CompanionPageDownload.linkedDatabaseKey else {
                            guard sources[index].data == record.data else {throw DesktopBridgeError.malformedResponse};continue
                        }
                        let before=try JSONDecoder.nodus.decode(JSONValue.self,from:sources[index].data),after=try JSONDecoder.nodus.decode(JSONValue.self,from:record.data)
                        guard before.objectValue?["vaultId"] == .string(vault),after.objectValue?["vaultId"] == .string(vault),
                            var merged=before.objectValue?["databases"]?.objectValue,let addition=after.objectValue?["databases"]?.objectValue else {throw DesktopBridgeError.malformedResponse}
                        for (id,payload) in addition {guard merged[id] == nil || merged[id] == payload else {throw APIError(status:409,code:"page_dependency_changed",message:"La base de datos cambió durante la descarga. Vuelve a intentarlo.")};merged[id]=payload}
                        let data=try JSONEncoder.nodus.encode(JSONValue.object(["version":.int(1),"vaultId":.string(vault),"databases":.object(merged)]))
                        let next=bytes - sources[index].data.count + data.count
                        guard next <= PrivateBridgeCache.defaultReadLimitBytes else {throw PrivateBridgeCache.ReadPackError.tooLarge}
                        bytes=next;sources[index] = .init(domain:record.domain,recordId:record.recordId,data:data)
                    } else {
                        guard record.data.count <= PrivateBridgeCache.defaultReadLimitBytes - bytes else {throw PrivateBridgeCache.ReadPackError.tooLarge}
                        bytes += record.data.count;sources.append(record)
                    }
                }
            }
            if ["study-docs", "study-subjects", "study-questions"].contains(collection.path) {
                let settings = try await client.operation(vaultId: vault, method: "getSettings", args: [])
                guard settings.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                try retain("getSettings", [], settings)
            }
            for (index, id) in chosen.keys.sorted().enumerated() {
                try Task.checkCancellation()
                let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
                guard let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.invalidOrigin }
                let detail = try await dossier(client, vault: vault, collection: collection, id: escaped, maxBytes: PrivateBridgeCache.defaultReadLimitBytes - bytes)
                let entry = JSONValue.object(["summary": .object(chosen[id]!.columns), "detail": .object(detail)])
                bytes += try JSONEncoder.nodus.encode(entry).count
                guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                entries.append(entry)
                let resources = try await CompanionDossierDownload.records(client: client, vault: vault, domains: pairing.domains,
                    collection: collection.path, id: id, detail: .object(detail), images: downloadImages, files: downloadFiles,
                    existing: Set(sources.map(\.recordId)), maximumBytes: PrivateBridgeCache.defaultReadLimitBytes - bytes)
                sources.append(contentsOf: resources); bytes += resources.reduce(0) { $0 + $1.data.count }
                if collection.path == "study-questions" {
                    let args: [JSONValue] = [.object(["kind": .string("question"), "sourceId": .string(id)])]
                    let original = try await client.operation(vaultId: vault, method: "getMobileStudyChatOriginal", args: args)
                    guard original.objectValue?["kind"] == .string("question"), original.objectValue?["sourceId"] == .string(id) else { throw DesktopBridgeError.malformedResponse }
                    try await CompanionChatContext.validateStudyOriginal(original)
                    try retain("getMobileStudyChatOriginal", args, original)
                }
                if collection.path == "world-maps" {
                    let source = try await client.operation(vaultId: vault, method: "getMobileWorldMapReadSource", args: [.string(id)])
                    try WorldMapReadSource.validate(source, vault: vault, mapId: id)
                    try retain("getMobileWorldMapReadSource", [.string(id)], source)
                }
                if collection.path == "pages" {
                    let source = try await client.operation(vaultId: vault, method: "getMobilePageDocument", args: [.string(id)])
                    _ = try CompanionPageDocuments.document(source, vaultId: vault, pageId: id)
                    try retain("getMobilePageDocument", [.string(id)], source)
                    let linked = try await CompanionPageDownload.records(client:client,vault:vault,root:source,domains:pairing.domains,
                        images:downloadImages,files:downloadFiles,existing:Set(sources.map(\.recordId)),maximumBytes:PrivateBridgeCache.defaultReadLimitBytes - bytes) { databaseId, remaining in
                        guard let databaseCollection=Collections["databases"],let escaped=databaseId.addingPercentEncoding(withAllowedCharacters:allowed) else {throw DesktopBridgeError.malformedResponse}
                        return .object(try await dossier(client,vault:vault,collection:databaseCollection,id:escaped,maxBytes:remaining))
                    }
                    try appendDependencies(linked)
                }
                if collection.path == "databases" {
                    try appendDependencies([try await CompanionDatabasePresentationSource.download(client: client, vault: vault, database: id, maximumBytes: PrivateBridgeCache.defaultReadLimitBytes - bytes)])
                    guard let views=detail["views"]?.arrayValue else {throw DesktopBridgeError.malformedResponse}
                    let viewRecords=try await CompanionDatabaseViewSource.download(client:client,vault:vault,views:views,maximumBytes:PrivateBridgeCache.defaultReadLimitBytes - bytes,existing:Set(sources.map(\.recordId)),ownerDatabase:id) { databaseId,remaining in
                        guard let descriptor=Collections["databases"],let escaped=databaseId.addingPercentEncoding(withAllowedCharacters:allowed) else {throw DesktopBridgeError.malformedResponse}
                        return .object(try await dossier(client,vault:vault,collection:descriptor,id:escaped,maxBytes:remaining))
                    }
                    try appendDependencies(viewRecords)
                    let pack = try await client.operation(vaultId:vault,method:"getMobileDatabaseResearchSourcePack",args:[.object(["databaseIds":.array([.string(id)])])])
                    guard pack.objectValue?["version"] == .int(1),pack.objectValue?["vaultId"] == .string(vault),
                          pack.objectValue?["databases"]?.arrayValue?.count == 1,
                          pack.objectValue?["databases"]?.arrayValue?.first?.objectValue?["snapshot"]?.objectValue?["databaseId"] == .string(id) else { throw DesktopBridgeError.malformedResponse }
                    let data = try JSONEncoder.nodus.encode(pack);bytes += data.count
                    guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                    sources.append(.init(domain:.corpus,recordId:"companion:database-source:v1:\(id)",data:data))
                }
                if collection.path == "study-docs" {
                    let args: [JSONValue] = [.object(["documentId": .string(id)])]
                    let source = try await client.operation(vaultId: vault, method: "getStudyImprovementOfflineSource", args: args)
                    guard source.objectValue?["version"] == .int(1), source.objectValue?["documentId"] == .string(id),
                          source.objectValue?["source"]?.objectValue?["id"] == .string(id), source.objectValue?["styles"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
                    try retain("getStudyImprovementOfflineSource", args, source)
                    if let styles = source.objectValue?["styles"] { try retain("listStudyStyles", [], styles) }
                }
                if let kind = ["study-docs": "study_document", "study-subjects": "study_subject", "study-questions": "study_question"][collection.path] {
                    let args: [JSONValue] = [.object(["entityKind": .string(kind), "entityId": .string(id)])]
                    let source = try await client.operation(vaultId: vault, method: "getContentTranslationOfflineSource", args: args)
                    guard source.objectValue?["version"] == .int(1), source.objectValue?["entityId"] == .string(id),
                          source.objectValue?["entityKind"] == .string(kind), source.objectValue?["source"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                    try retain("getContentTranslationOfflineSource", args, source)
                }
                progress = (index + 1, chosen.count)
            }
            let current = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard current == revision else { throw DesktopBridgeError.malformedResponse }
            let copy = JSONValue.object(["version": .int(1), "path": .string(collection.path), "entries": .array(entries)])
            _ = try CompanionCollectionCopy(path: collection.path, copies: [copy])
            try Task.checkCancellation()
            let id = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: chosen.keys.map { "\(collection.path):\($0)" })
            sources.append(.init(domain: .corpus, recordId: try CompanionCollectionCopy.recordId(path: collection.path), data: try JSONEncoder.nodus.encode(copy)))
            // Several selected documents share the same style bootstrap. Keep
            // one exact query record; the individual revision-bound sources
            // retain their own style snapshots for conflict checks.
            var keys = Set<String>()
            sources = Array(sources.reversed().filter { keys.insert($0.recordId).inserted }.reversed())
            try await cache.saveReadPack(id: id, vaultId: vault, title: "\(collection.label) · \(entries.count)",
                expiresAt: Date().addingTimeInterval(Double(selectedDays) * 86_400), records: sources)
            session.didChangeCompanionDownloads()
            saved = true
        } catch is CancellationError { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch let error as URLError where error.code == .cancelled { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch { issue = error.localizedDescription }
    }

    private func dossier(_ client: DesktopBridgeClient, vault: String, collection: CollectionDescriptor, id: String, maxBytes: Int) async throws -> [String: JSONValue] {
        var combined: [String: JSONValue]?, offset = 0, total: Int?, ids = Set<String>(), bytes = 0
        repeat {
            try Task.checkCancellation()
            let query = collection.path == "databases" ? [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "offset", value: String(offset))] : []
            let response = try await client.corpus(vaultId: vault, path: "\(collection.path)/\(id)", query: query, percentEncoded: true)
            bytes += response.data.count
            guard bytes <= maxBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            guard let page = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data).objectValue else { throw DesktopBridgeError.malformedResponse }
            if collection.path != "databases" { return page }
            guard let rows = page["rows"]?.arrayValue, let count = page["total"]?.intValue, count >= 0,
                  page["offset"]?.intValue == offset, total == nil || total == count,
                  rows.count <= count - offset, !rows.isEmpty || offset == count,
                  page["hasMore"]?.boolValue == (offset + rows.count < count) else { throw DesktopBridgeError.malformedResponse }
            total = count
            for row in rows {
                guard let id = row.objectValue?["id"]?.stringValue, ids.insert(id).inserted else { throw DesktopBridgeError.malformedResponse }
            }
            if var previous = combined {
                guard ["database", "columns", "views", "options", "revision"].allSatisfy({ previous[$0] == page[$0] }) else { throw DesktopBridgeError.malformedResponse }
                for field in ["rows", "cells", "relations", "attachments"] {
                    guard let first = previous[field]?.arrayValue, let next = page[field]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
                    previous[field] = .array(first + next)
                }
                combined = previous
            } else { combined = page }
            offset += rows.count
        } while offset < total!
        guard var result = combined else { throw DesktopBridgeError.malformedResponse }
        result["limit"] = .int(Int64(offset)); result["offset"] = .int(0); result["hasMore"] = .bool(false)
        return result
    }
}
