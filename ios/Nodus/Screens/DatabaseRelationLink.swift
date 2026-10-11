import NodusKit
import NodusUI
import SwiftUI

struct DatabaseRelationLink: View {
    let session: SpaceSession
    let relation: Row
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "link").foregroundStyle(session.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(relation.text("label") ?? relation.text("last_known_label") ?? relation.text("lastKnownLabel") ?? "Registro vinculado").font(.subheadline).multilineTextAlignment(.leading)
                    if relation.bool("broken") == true { Text("El enlace necesita revisión").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 6); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.frame(minHeight: 44)
        }.buttonStyle(.plain)
        .nodusSheet(isPresented: $showing) {
            NavigationStack { DatabaseRelationDestination(source: session, relation: relation).nodusModalClose(accent: session.accent) }
        }
    }
}

private struct DatabaseRelationDestination: View {
    let source: SpaceSession
    let relation: Row
    @State private var target: DatabaseRelationReference?
    @State private var session: SpaceSession?
    @State private var issue: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let session, let target {
                if target.kind == "db_row" { DatabaseLinkedRowReader(session: session, id: target.id) }
                else if let collection = target.collection { RowDetailView(session: session, collection: collection, row: Row([collection.idField: .string(target.id)])) }
            } else if let issue {
                VStack(alignment: .leading, spacing: 16) {
                    NodusNotice(tone: .caution, title: "No se pudo abrir el enlace", message: LocalizedStringKey(issue))
                    Button("Reintentar") { attempt += 1 }.frame(minHeight: 44)
                }.padding(NodusSpace.page)
            } else { ProgressView("Abriendo registro vinculado…") }
        }
        .task(id: attempt) {
            issue = nil; target = nil; session = nil
            do {
                let ref = try DatabaseRelationReference(relation)
                let destination: SpaceSession
                if ref.vaultId == nil || ref.vaultId == source.vaultId { destination = source }
                else {
                    let (_, pairing, token) = try privateBridgeConnection(source, domain: .corpus)
                    guard !pairing.isExpired, let vault = ref.vaultId, pairing.vaultIds.contains(vault),
                          let connection = AppModel.storedConnections().first(where: { $0.desktopPairingId == pairing.id && $0.vaultId == vault }),
                          let client = ConnectionClient.make(for: connection, token: token, pairings: [pairing],
                              cacheDirectory: URL.cachesDirectory.appendingPathComponent("nodus-http", isDirectory: true)) else {
                        throw APIError(status: 403, code: "relation_vault_not_linked", message: "El vault de este registro no está incluido en la vinculación actual. Actualiza la conexión del workspace con Nodus para abrirlo.")
                    }
                    destination = SpaceSession(connection: connection, client: client)
                }
                try Task.checkCancellation(); target = ref; session = destination
            } catch where error.isCancellation {}
            catch { issue = error.localizedDescription }
        }
    }
}

private struct DatabaseLinkedRowReader: View {
    let session: SpaceSession
    let id: String
    @State private var detail: DatabaseDetail?
    @State private var row: Row?
    @State private var offline = false
    @State private var issue: String?
    @State private var attempt = 0
    var body: some View {
        Group {
            if let detail, row != nil {
                DatabaseRowView(session: session, databaseName: detail.database.text("name"), columns: detail.columns,
                    context: DatabaseCell.Context(detail: detail, rowId: id), downloadedOnly: offline)
            } else if let issue {
                VStack(alignment: .leading, spacing: 16) {
                    NodusNotice(tone: .caution, title: "Fila no disponible", message: LocalizedStringKey(issue))
                    Button("Reintentar") { attempt += 1 }.frame(minHeight: 44)
                }.padding(NodusSpace.page)
            } else { ProgressView("Cargando fila vinculada…") }
        }.task(id: attempt) { await load() }
    }
    private func load() async {
        detail = nil; row = nil; issue = nil; offline = false
        do {
            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
            guard !pairing.isExpired, let collection = Collections["databases"] else { throw DesktopBridgeError.permissionDenied }
            do {
                let location = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileDatabaseRowLocation", args: [.string(id)])
                guard location.objectValue?["version"] == .int(1), location.objectValue?["vaultId"] == .string(vault),
                      location.objectValue?["rowId"] == .string(id), let database = location.objectValue?["databaseId"]?.stringValue, !database.isEmpty else { throw DesktopBridgeError.malformedResponse }
                var offset = 0, revision: String?, total: Int?
                repeat {
                    try Task.checkCancellation()
                    let response = try await session.client.dossier(collection, id: database, in: session.connection.spaceId,
                        query: [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "offset", value: String(offset))])
                    // A downloaded dossier is the whole selected database, not
                    // this REST page. Read it through the complete local branch.
                    if response.fromDevice { throw URLError(.notConnectedToInternet) }
                    guard response.primary.string("id") == database, let object = response.payload.objectValue,
                          let current = object["revision"]?.stringValue, revision == nil || revision == current,
                          let count = object["total"]?.intValue, total == nil || total == count, count >= offset,
                          object["offset"]?.intValue == offset, let rows = object["rows"]?.arrayValue,
                          !rows.isEmpty || offset == count, rows.count <= count - offset,
                          object["hasMore"]?.boolValue == (offset + rows.count < count) else { throw DesktopBridgeError.malformedResponse }
                    revision = current; total = count
                    if let found = rows.first(where: { $0.objectValue?["id"] == .string(id) }) {
                        let loaded = try response.decode(DatabaseDetail.self)
                        try Task.checkCancellation(); detail = loaded; row = Row(found.objectValue!); offline = response.fromDevice; return
                    }
                    offset += rows.count
                } while offset < (total ?? 0)
                throw APIError(status: 404, code: "relation_row_missing", message: "La fila vinculada se eliminó o cambió de base de datos. Actualiza el enlace en Nodus.")
            } catch {
                guard isPrivateBridgeOffline(error) else { throw error }
                let copy = try await downloadedCollection(session, path: "databases")
                var match: (DatabaseDetail, Row)?
                for database in copy.selectedRows {
                    guard let databaseId = database.string("id") else { throw DesktopBridgeError.malformedResponse }
                    let dossier = try copy.dossier(id: databaseId)
                    if let found = dossier.payload.objectValue?["rows"]?.arrayValue?.first(where: { $0.objectValue?["id"] == .string(id) }) {
                        guard match == nil else { throw DesktopBridgeError.malformedResponse }
                        match = (try dossier.decode(DatabaseDetail.self), Row(found.objectValue!))
                    }
                }
                guard let match else { throw APIError(status: 409, code: "relation_row_not_downloaded", message: "La fila está en una base de datos que no has descargado. Elige esa base de datos en Descargas cuando Nodus esté conectado.") }
                try Task.checkCancellation(); detail = match.0; row = match.1; offline = true
            }
        } catch where error.isCancellation {}
        catch { issue = error.localizedDescription }
    }
}
