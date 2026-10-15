import NodusKit
import NodusUI
import SwiftUI

struct DatabaseRelationEditor: View {
    let session: SpaceSession
    let rowId: String
    let column: PagesDatabasesParity.Column
    @Binding var tables: [String: [Row]]
    let outbox: OutboxController?
    var downloadedOnly = false
    @State private var choosing = false
    @State private var issue: String?
    @State private var saving = false
    private var relations: [Row] { (tables["db_relations"] ?? []).filter { $0.string("row_id") == rowId && $0.string("column_id") == column.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(relations, id: \.columns) { relation in
                HStack {
                    DatabaseRelationLink(session: session, relation: relation)
                    Button(role: .destructive) { Task { await change(existing: relation) } } label: { Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Quitar relación").disabled(outbox == nil || saving)
                }
            }
            Button { choosing = true } label: { Label("Añadir relación", systemImage: "link.badge.plus").frame(minHeight: 44) }.disabled(outbox == nil || saving).accessibilityIdentifier("database-relation-add-\(column.id)")
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .nodusSheet(isPresented: $choosing) {
            NavigationStack {
                DatabaseRelationTargetPicker(session: session, column: column, tables: tables, downloadedOnly: downloadedOnly) { id, label, vault in
                    await change(target: id, label: label, vault: vault)
                }.navigationTitle("Seleccionar destino").nodusModalClose(accent: session.accent)
            }
        }
    }
    private func change(existing: Row? = nil, target: String? = nil, label: String? = nil, vault: String? = nil) async {
        guard let outbox, !saving else { return }; saving = true; defer { saving = false }
        do {
            guard let revision = tables["db_columns"]?.first(where: { $0.string("id") == column.id })?.int("revision") else { throw DesktopBridgeError.malformedResponse }
            let id = existing?.string("id") ?? "drel_" + UUID().uuidString.lowercased()
            let fields = try CompanionDatabaseLinks.relation(id: id, rowId: rowId, columnId: column.id, databaseId: column.databaseId, columnRevision: revision, current: relations,
                targetKind: target == nil ? nil : column.config["relationTargetKind"]?.stringValue ?? "db_row", targetId: target, targetVaultId: vault, label: label)
            guard await outbox.syncMutation(kind: existing == nil ? .upsert : .delete, table: .databaseRelations, key: [id], row: fields, title: existing == nil ? "Añadir relación" : "Quitar relación") else {
                throw APIError(status: 409, code: "database_relation_not_queued", message: outbox.lastError ?? "No se pudo guardar la relación.")
            }
            let inverse = existing?.string("inverse_relation_id")
            tables["db_relations", default: []].removeAll { value in
                value.string("id") == id || (inverse != nil && value.string("id") == inverse) || (existing == nil && column.config["relationCardinality"] == .string("one") && value.string("row_id") == rowId && value.string("column_id") == column.id)
            }
            if existing == nil { tables["db_relations", default: []].append(Row(fields.filter { !$0.key.hasPrefix("_mobile") })) }
            issue = nil; choosing = false
        } catch { issue = error.localizedDescription }
    }
}

private struct DatabaseRelationTargetPicker: View {
    struct Target: Identifiable { let id: String; let label: String }
    let session: SpaceSession
    let column: PagesDatabasesParity.Column
    let tables: [String: [Row]]
    let downloadedOnly: Bool
    let choose: (String, String, String?) async -> Void
    @State private var query = ""
    @State private var selectedVault = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var hasMore = false
    @State private var candidates: [Target] = []
    @State private var issue: String?
    @State private var loading = false
    @State private var generation = UUID()
    private var kind: String { column.config["relationTargetKind"]?.stringValue ?? "db_row" }
    private var targetDatabase: String { column.config["relationTargetDatabaseId"]?.stringValue ?? column.databaseId }
    private var connections: [AppModel.Connection] {
        guard let (_, pair, _) = try? privateBridgeConnection(session, domain: .corpus) else { return [] }
        return AppModel.storedConnections().filter { $0.desktopPairingId == pair.id && $0.vaultId.map(pair.vaultIds.contains) == true }
    }
    var body: some View {
        List {
            if kind != "db_row" {
                Picker("Espacio del destino", selection: $selectedVault) {
                    Text("Este espacio").tag("")
                    ForEach(connections.filter { $0.vaultId != session.vaultId }, id: \.id) { connection in Text(connection.spaceName).tag(connection.vaultId ?? "") }
                }
            }
            TextField(kind == "db_row" && !downloadedOnly && session.aiExecutionMode != .autonomous ? "Filtrar filas de esta página" : "Buscar destino", text: $query).accessibilityIdentifier("database-relation-target-search")
            if loading { ProgressView("Cargando destinos…") }
            if let issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            ForEach(candidates) { target in
                Button { Task { await choose(target.id, target.label, kind == "db_row" ? nil : selectedVault.isEmpty ? session.vaultId : selectedVault) } } label: {
                    Text(target.label).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("database-relation-target-\(target.id)")
            }
            if !loading {
                Text("Página \(offset / 50 + 1) · \(candidates.count) resultados · \(total) registros disponibles").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Anterior") { offset = max(0, offset - 50) }.disabled(offset == 0)
                    Spacer()
                    Button("Siguiente") { offset += 50 }.disabled(!hasMore)
                }.frame(minHeight: 44)
            }
        }
        .onChange(of: query) { _, _ in offset = 0 }.onChange(of: selectedVault) { _, _ in offset = 0 }
        .task(id: "\(query)|\(selectedVault)|\(offset)") { await load() }
    }
    private func destination() throws -> SpaceSession {
        if selectedVault.isEmpty || selectedVault == session.vaultId { return session }
        let (_, pair, token) = try privateBridgeConnection(session, domain: .corpus)
        guard let connection = connections.first(where: { $0.vaultId == selectedVault }),
              let client = ConnectionClient.make(for: connection, token: token, pairings: [pair], cacheDirectory: URL.cachesDirectory.appendingPathComponent("nodus-http", isDirectory: true)) else { throw DesktopBridgeError.permissionDenied }
        return SpaceSession(connection: connection, client: client)
    }
    private func load() async {
        let request = UUID(); generation = request; loading = true; issue = nil; candidates = []
        defer { if generation == request { loading = false } }
        do {
            let source = try destination(), local = downloadedOnly || session.aiExecutionMode == .autonomous
            var values: [Target], count: Int, more: Bool
            if kind == "db_row" {
                let table: [String:[Row]]
                var pageTotal = 0, pageHasMore = false
                if local {
                    guard (tables["db_databases"] ?? []).contains(where: { $0.string("id") == targetDatabase }) else { throw APIError(status: 409, code: "database_relation_target_not_downloaded", message: "Descarga la base de datos de destino para elegir sus filas sin conexión.") }
                    table = tables
                } else {
                    let detail = try await source.client.database(targetDatabase, in: source.connection.spaceId, limit: 50, offset: offset)
                    guard detail.offset == offset, detail.total >= offset + detail.rows.count, detail.hasMore == (offset + detail.rows.count < detail.total) else { throw DesktopBridgeError.malformedResponse }
                    table = ["db_rows": detail.rows, "db_cells": detail.cells, "db_columns": detail.columns]
                    pageTotal = detail.total; pageHasMore = detail.hasMore
                }
                let rows = PagesDatabasesParity.rows(databaseId: targetDatabase, in: table), columns = PagesDatabasesParity.columns(databaseId: targetDatabase, in: table)
                let title = columns.first { $0.type == "title" }
                values = rows.map { row in
                    let label = title.flatMap { row.cells[$0.id] }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return Target(id: row.id, label: label.isEmpty ? "Fila sin título" : label)
                }
                if local { values = values.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }; count = values.count; more = offset + 50 < count; values = Array(values.dropFirst(offset).prefix(50)) }
                else { values = values.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }; count = pageTotal; more = pageHasMore }
            } else {
                let path = ["work":"works", "idea":"ideas", "gap":"gaps", "author":"authors", "person":"persons"][kind]
                guard let path, let collection = Collections[path] else { throw DesktopBridgeError.permissionDenied }
                let rows: [Row]
                if local {
                    let copy = try await downloadedCollection(source, path: path)
                    let all = copy.selectedRows.filter { row in query.isEmpty || row.columns.values.compactMap(\.stringValue).contains { $0.localizedCaseInsensitiveContains(query) } }
                    count = all.count; more = offset + 50 < count; rows = Array(all.dropFirst(offset).prefix(50))
                } else {
                    let page = try await source.client.list(collection, in: source.connection.spaceId, query: query, limit: 50, offset: offset)
                    guard page.offset == offset, page.total >= offset + page.items.count, page.hasMore == (offset + page.items.count < page.total) else { throw DesktopBridgeError.malformedResponse }
                    rows = page.items; count = page.total; more = page.hasMore
                }
                values = try rows.map { row in
                    guard let id = row.string(collection.idField) else { throw DesktopBridgeError.malformedResponse }
                    return Target(id: id, label: row.text("title") ?? row.text("label") ?? row.text("name") ?? row.text("question") ?? "Registro sin título")
                }
            }
            try Task.checkCancellation(); guard generation == request else { return }
            candidates = values; total = count; hasMore = more
        } catch where error.isCancellation {} catch { if generation == request { issue = error.localizedDescription; total = 0; hasMore = false } }
    }
}
