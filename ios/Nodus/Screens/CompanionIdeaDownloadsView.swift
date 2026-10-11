import NodusKit
import NodusUI
import SwiftUI

struct CompanionIdeaDownloadsView: View {
    let session: SpaceSession
    @State private var catalogue: [JSONValue] = []
    @State private var catalogueRevision: String?
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var days = 7
    @State private var loading = false
    @State private var progress: (done: Int, total: Int)?
    @State private var stage = "Descargando ideas"
    @State private var issue: String?
    @State private var saved = false
    @State private var downloadTask: Task<Void, Never>?

    private var visible: [JSONValue] {
        catalogue.filter { query.isEmpty || ($0.objectValue?["label"]?.stringValue ?? "").localizedStandardContains(query) }
    }
    var body: some View {
        List {
            Section {
                Picker("Conservar la descarga", selection: $days) {
                    Text("7 días").tag(7); Text("30 días").tag(30)
                }.disabled(progress != nil)
            } footer: {
                Text("Elige las ideas que quieres consultar sin el Mac. Se incluyen sus evidencias y conexiones directas para explorar el grafo. El texto completo de otras ideas y los originales de las fuentes necesitan su propia descarga.")
            }
            if loading { ProgressView("Cargando ideas del Mac…") }
            if let issue {
                Section {
                    Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("companion-ideas-download-error")
                    if progress == nil { Button("Volver a cargar") { Task { await load() } } }
                }
            }
            if let progress {
                Section {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                    Text("\(stage) · \(progress.done) de \(progress.total)")
                    Button("Cancelar", role: .cancel) { downloadTask?.cancel() }
                }
            }
            if saved { Label("Ideas disponibles sin conexión", systemImage: "checkmark.circle.fill").foregroundStyle(.green).accessibilityIdentifier("companion-ideas-download-ready") }
            if !loading, catalogue.isEmpty, issue == nil { Text("Todavía no hay ideas en este vault.").foregroundStyle(.secondary) }
            Section("Ideas") {
                ForEach(visible, id: \.ideaDownloadId) { item in
                    if let id = item.objectValue?["id"]?.stringValue {
                        Button {
                            if !selection.insert(id).inserted { selection.remove(id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle").foregroundStyle(session.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.objectValue?["label"]?.stringValue ?? id).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text(item.objectValue?["statement"]?.stringValue ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.frame(minHeight: 44)
                        }.disabled(progress != nil || saved).accessibilityIdentifier("companion-download-corpus-idea-\(id)")
                            .accessibilityValue(selection.contains(id) ? "Seleccionado" : "Sin seleccionar")
                    }
                }
            }
        }
        .navigationTitle("Llevar ideas contigo").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Buscar ideas")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Descargar") { downloadTask = Task { await download() } }
                    .disabled(loading || selection.isEmpty || progress != nil || saved)
                    .accessibilityIdentifier("companion-ideas-download-start")
            }
        }
        .task { await load() }.onDisappear { downloadTask?.cancel() }
    }

    private func connection() throws -> (String, DesktopBridgeClient, PrivateBridgeCache) {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
        return (vault, DesktopBridgeClient(pairing: pairing, token: token), try PrivateBridgeCache(pairingId: pairing.id))
    }
    private func load() async {
        loading = true; issue = nil
        defer { loading = false }
        do {
            let (vault, client, _) = try connection()
            let revision = try await session.client.snapshotRevision(in: session.connection.spaceId)
            var items: [JSONValue] = [], ids = Set<String>(), total: Int?, bytes = 0
            repeat {
                try Task.checkCancellation()
                let response = try await client.operation(vaultId: vault, method: "listIdeasPage", args: [.object(["offset": .int(Int64(items.count)), "limit": .int(200), "sort": .string("label")])])
                bytes += try JSONEncoder.nodus.encode(response).count
                guard bytes <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                guard let page = response.objectValue, let rows = page["items"]?.arrayValue,
                      let count = page["total"]?.intValue, count >= 0, total == nil || count == total,
                      page["offset"]?.intValue == items.count, rows.count <= count - items.count,
                      !rows.isEmpty || items.count == count else { throw DesktopBridgeError.malformedResponse }
                total = count
                for row in rows {
                    guard let id = row.objectValue?["id"]?.stringValue, !id.isEmpty, ids.insert(id).inserted else { throw DesktopBridgeError.malformedResponse }
                    items.append(row)
                }
            } while items.count < total!
            guard revision != nil, try await session.client.snapshotRevision(in: session.connection.spaceId) == revision else {
                issue = "El contenido del Mac cambió mientras cargaban las ideas. Vuelve a abrir esta pantalla."; return
            }
            catalogueRevision = revision; catalogue = items
            selection.formIntersection(Set(items.map(\.ideaDownloadId)))
        } catch is CancellationError { }
        catch { issue = error.localizedDescription }
    }

    private func download() async {
        issue = nil; stage = "Descargando ideas"; progress = (0, selection.count)
        defer { progress = nil }
        do {
            let (vault, client, cache) = try connection()
            let revision = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard revision != nil, revision == catalogueRevision else {
                issue = "El contenido del Mac cambió desde que abriste la lista. Vuelve a abrirla antes de descargar."; return
            }
            let chosen = catalogue.filter { selection.contains($0.ideaDownloadId) }
            guard chosen.count == selection.count, !chosen.isEmpty else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
            var records: [PrivateBridgeCache.ReadPackRecord] = [], entries: [JSONValue] = []
            if let workshop = try await workshopDownloadRecord(client: client, vault: vault, path: "ideas", ids: selection.sorted()) { records.append(workshop) }
            var nodes: [String: JSONValue] = [:], edges: [String: JSONValue] = [:], edgeDetails: [JSONValue] = []
            var bytes = 0
            func account(_ value: JSONValue) throws {
                bytes += try JSONEncoder.nodus.encode(value).count
                guard bytes <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            }
            let settings = try await client.operation(vaultId: vault, method: "getSettings", args: [])
            try account(settings)
            records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("getSettings", []), data: try JSONEncoder.nodus.encode(settings)))
            let themes = try await client.operation(vaultId: vault, method: "stellarThemes", args: [])
            guard themes.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
            try account(themes)
            for (index, summary) in chosen.enumerated() {
                try Task.checkCancellation()
                let id = summary.ideaDownloadId
                let detail = try await client.operation(vaultId: vault, method: "getIdeaDetail", args: [.string(id)])
                let connections = try await client.operation(vaultId: vault, method: "getIdeaEdges", args: [.string(id)])
                let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
                guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.malformedResponse }
                let native = try await client.corpus(vaultId: vault, path: "ideas/\(encoded)", percentEncoded: true)
                guard native.status == 200 else { throw DesktopBridgeError.malformedResponse }
                let nativeDetail = try JSONDecoder.nodus.decode(JSONValue.self, from: native.data)
                let entry: JSONValue = .object(["summary": summary, "detail": detail, "connections": connections, "nativeDetail": nativeDetail])
                try account(entry); entries.append(entry)
                let element = try await client.operation(vaultId: vault, method: "stellarPage", args: [.object(["kind": .string("elements"), "nodeIds": .array([.string(id)])])])
                guard let seedNodes = element.objectValue?["nodes"]?.arrayValue,
                      seedNodes.contains(where: { $0.objectValue?["id"]?.stringValue == id }) else { throw DesktopBridgeError.malformedResponse }
                for node in seedNodes {
                    guard let nodeId = node.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                    if nodes[nodeId] == nil { try account(node); nodes[nodeId] = node }
                }
                var cursor = 0, total: Int?, seenEdges = Set<String>()
                repeat {
                    try Task.checkCancellation()
                    let response = try await client.operation(vaultId: vault, method: "stellarPage", args: [.object(["kind": .string("neighbors"), "id": .string(id), "cursor": .int(Int64(cursor)), "limit": .int(200)])])
                    guard let page = response.objectValue, let pageNodes = page["nodes"]?.arrayValue, let pageEdges = page["edges"]?.arrayValue,
                          let count = page["total"]?.intValue, count >= 0, total == nil || total == count,
                          pageEdges.count <= count - cursor else { throw DesktopBridgeError.malformedResponse }
                    total = count
                    for node in pageNodes {
                        guard let nodeId = node.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                        if nodes[nodeId] == nil { try account(node); nodes[nodeId] = node }
                    }
                    for edge in pageEdges {
                        guard let edgeId = edge.objectValue?["id"]?.stringValue,
                              seenEdges.insert(edgeId).inserted,
                              edge.objectValue?["source"]?.stringValue == id || edge.objectValue?["target"]?.stringValue == id else { throw DesktopBridgeError.malformedResponse }
                        if edges[edgeId] == nil { try account(edge); edges[edgeId] = edge }
                    }
                    if page["next"] == .null {
                        guard cursor + pageEdges.count == count else { throw DesktopBridgeError.malformedResponse }
                        break
                    }
                    guard let next = page["next"]?.intValue, next == cursor + pageEdges.count, next > cursor, next < count else { throw DesktopBridgeError.malformedResponse }
                    cursor = next
                } while true
                progress = (index + 1, chosen.count)
            }
            stage = "Preparando conexiones"; progress = (0, max(1, edges.count))
            for (index, id) in edges.keys.sorted().enumerated() {
                try Task.checkCancellation()
                let detail = try await client.operation(vaultId: vault, method: "getEdgeDetail", args: [.string(id)])
                guard detail.objectValue?["edge"]?.objectValue?["id"]?.stringValue == id else { throw DesktopBridgeError.malformedResponse }
                try account(detail); edgeDetails.append(detail)
                progress = (index + 1, max(1, edges.count))
            }
            let copy: JSONValue = .object(["version": .int(1), "entries": .array(entries),
                "graph": .object(["nodes": .array(nodes.keys.sorted().compactMap { nodes[$0] }), "edges": .array(edges.keys.sorted().compactMap { edges[$0] })]),
                "themes": themes, "edgeDetails": .array(edgeDetails)])
            _ = try CompanionIdeaCopy(copies: [copy])
            let data = try JSONEncoder.nodus.encode(copy)
            guard data.count + records.reduce(0, { $0 + $1.data.count }) <= PrivateBridgeCache.maximumSelectedCopyBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            guard try await session.client.snapshotRevision(in: session.connection.spaceId) == revision else {
                issue = "El contenido del Mac cambió durante la descarga. Vuelve a descargar las ideas."; return
            }
            try Task.checkCancellation()
            records.append(.init(domain: .corpus, recordId: CompanionIdeaCopy.recordId, data: data))
            let packId = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: selection.map { "idea:\($0)" })
            try await cache.saveReadPack(id: packId, vaultId: vault, title: "\(chosen.count) ideas y conexiones",
                expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: records)
            session.didChangeCompanionDownloads()
            saved = true
        } catch is CancellationError { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch let error as URLError where error.code == .cancelled { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch { issue = error.localizedDescription }
    }
}

private extension JSONValue {
    var ideaDownloadId: String { objectValue?["id"]?.stringValue ?? "" }
}
