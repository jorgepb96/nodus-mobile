import NodusKit
import NodusUI
import SwiftUI
import UniformTypeIdentifiers

/// Import, preview and transfer are explicit. Closing the inspector does not
/// cancel a durable import or send; the same UUID is recovered after relaunch.
struct DatabaseAttachmentControls: View {
    let session: SpaceSession
    let rowId: String
    let column: PagesDatabasesParity.Column
    @Binding var tables: [String: [Row]]
    let outbox: OutboxController?
    @State private var transfers: [CompanionDatabaseAttachments.Transfer] = []
    @State private var importer = false
    @State private var retryImport: UUID?
    @State private var worker: Task<Void, Never>?
    @State private var busy = false
    @State private var issue: String?
    @State private var export: PrivateBridgeFileLease?
    @State private var deleting: Row?
    @State private var discarding: UUID?
    private var rowRevision: Int? { tables["db_rows"]?.first { $0.string("id") == rowId }?.int("revision") }
    private var columnRevision: Int? { tables["db_columns"]?.first { $0.string("id") == column.id }?.int("revision") }
    private var existing: [Row] { (tables["db_attachments"] ?? []).filter { $0.string("row_id") == rowId && $0.string("column_id") == column.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { retryImport = nil; importer = true } label: { Label("Importar archivo", systemImage: "paperclip").frame(minHeight: 44) }
                .disabled(busy || rowRevision == nil || columnRevision == nil).accessibilityIdentifier("database-file-import-\(column.id)")
            ForEach(existing, id: \.columns) { file in
                HStack {
                    if let id = file.string("id") { PrivateFileButton(session: session, kind: .databaseAttachment, id: id) }
                    Spacer(minLength: 8)
                    Button(role: .destructive) { deleting = file } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("Eliminar archivo").disabled(outbox == nil || busy)
                }
            }
            ForEach(transfers) { file in
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.filename).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Text(state(file)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    ProgressView(value: Double(file.state == "importing" ? file.importedBytes : file.uploadedBytes), total: Double(max(1, file.byteCount)))
                    if let text = file.issue { Text(text).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    if file.state == "discarded" {
                        Button("Completar eliminación de la copia local") { run { try await store().discardDeviceCopy(file.id) } }.frame(minHeight: 44).disabled(busy)
                    } else if file.sha256 == nil {
                        if file.recoveryReviewRequired == true {
                            Button("Revisar archivo recuperado") { run { try await store().approveRecovered(file.id) } }.frame(minHeight: 44).disabled(busy)
                        }
                        Button("Seleccionar de nuevo el original") { retryImport = file.id; importer = true }.frame(minHeight: 44).disabled(busy)
                    } else {
                        HStack {
                            Button("Exportar original") { run { try await preview(file.id) } }.frame(minHeight: 44).disabled(busy)
                            if file.state == "available" {
                                Button("Eliminar copia del dispositivo", role: .destructive) { discarding = file.id }.frame(minHeight: 44).disabled(busy)
                            } else {
                                Button(file.recoveryReviewRequired == true ? "Revisar y enviar" : "Enviar o reanudar") { run { try await send(file) } }.frame(minHeight: 44).disabled(busy)
                            }
                        }
                    }
                }.padding(10).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("database-file-transfer-\(file.id.uuidString.lowercased())")
            }
            if busy { Button("Pausar transferencia", role: .cancel) { worker?.cancel() }.frame(minHeight: 44) }
            if let export { ShareLink(item: export.url) { Label("Compartir archivo", systemImage: "square.and.arrow.up").frame(minHeight: 44) } }
            if let issue { Text(issue).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .task(id: rowId + ":" + column.id) {
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): run { try await importFile(url) }
            case .failure(let error): issue = error.localizedDescription
            }
        }
        .confirmationDialog(discarding == nil ? "Eliminar este archivo de Nodus" : "Eliminar la copia del dispositivo", isPresented: Binding(get: { deleting != nil || discarding != nil }, set: { if !$0 { deleting = nil; discarding = nil } })) {
            if let file = deleting { Button("Eliminar archivo", role: .destructive) { run { try await delete(file) } } }
            if let id = discarding { Button("Eliminar copia local", role: .destructive) { run { try await store().discardDeviceCopy(id); discarding = nil } } }
            Button("Cancelar", role: .cancel) { deleting = nil; discarding = nil }
        } message: {
            Text(discarding == nil ? "La eliminación se guardará y sincronizará con Nodus." : "Se borrarán los bloques cifrados de esta copia. El archivo aplicado en Nodus se conserva.")
        }
    }
    private func store() async throws -> CompanionDatabaseAttachments {
        let (vault, pair, _) = try privateBridgeConnection(session, domain: .writing)
        return try await CompanionDatabaseAttachmentStores.shared.store(pairingId: pair.id, vaultId: vault)
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }; busy = true; issue = nil
        worker = Task { @MainActor in
            defer { busy = false; worker = nil }
            do { try await action() } catch { issue = error.localizedDescription }
            await refresh()
        }
    }
    private func refresh() async {
        do { transfers = try await store().all().filter { $0.rowId == rowId && $0.columnId == column.id } }
        catch { issue = error.localizedDescription }
    }
    private func importFile(_ url: URL) async throws {
        guard let rowRevision, let columnRevision else { throw DesktopBridgeError.malformedResponse }
        let id = retryImport ?? UUID(), mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let store = try await store(), previous = try await store.transfer(id)
        let value = try await store.importFile(url: url, filename: previous?.filename, mimeType: previous?.mimeType ?? mime, rowId: rowId, columnId: column.id, expectedRowRevision: previous?.expectedRowRevision ?? Int64(rowRevision), expectedColumnRevision: previous?.expectedColumnRevision ?? Int64(columnRevision), uploadId: id)
        transfers.removeAll { $0.id == value.id }; transfers.append(value)
        // Importing is useful offline; it does not implicitly send any bytes.
    }
    private func preview(_ id: UUID) async throws { export = try await store().export(id) }
    private func send(_ file: CompanionDatabaseAttachments.Transfer) async throws {
        let (vault, pair, token) = try privateBridgeConnection(session, domain: .writing)
        let store = try await store()
        if file.recoveryReviewRequired == true { try await store.approveRecovered(file.id) }
        let bridge = DesktopBridgeClient(pairing: pair, token: token)
        let result = try await store.upload(file.id, commit: true) { id, action, body in try await bridge.databaseFileUpload(vaultId: vault, uploadId: id, action: action, body: body) }
        guard let receipt = result.result?.objectValue, let attachment = receipt["attachment"]?.objectValue,
              attachment["id"] == receipt["id"], attachment["row_id"] == .string(rowId), attachment["column_id"] == .string(column.id),
              let parent = receipt["row"]?.objectValue, parent["id"] == .string(rowId), parent["database_id"] == .string(column.databaseId) else { throw DesktopBridgeError.malformedResponse }
        tables["db_attachments", default: []].removeAll { $0.columns["id"] == attachment["id"] }
        tables["db_attachments", default: []].append(Row(attachment))
        if let index = tables["db_rows"]?.firstIndex(where: { $0.string("id") == rowId }) { tables["db_rows"]?[index] = Row(parent) }
    }
    private func delete(_ file: Row) async throws {
        guard let outbox, let id = file.string("id"), let revision = file.int("revision"), let hash = file.string("content_hash"), let columnRevision else { throw DesktopBridgeError.malformedResponse }
        var record = file.columns
        record["_mobileExpectedColumnRevision"] = .int(Int64(columnRevision)); record["_mobileExpectedRevision"] = .int(Int64(revision)); record["_mobileExpectedContentHash"] = .string(hash)
        guard await outbox.syncMutation(kind: .delete, table: .databaseAttachments, key: [id], row: record, title: "Eliminar archivo") else { throw APIError(status: 409, code: "database_file_delete_not_queued", message: outbox.lastError ?? "No se pudo guardar la eliminación del archivo.") }
        tables["db_attachments"]?.removeAll { $0.string("id") == id }; deleting = nil
    }
    private func state(_ value: CompanionDatabaseAttachments.Transfer) -> String {
        if value.recoveryReviewRequired == true { return "Archivo conservado · revisa el destino antes de enviarlo" }
        switch value.state {
        case "importing": return "Importación incompleta · selecciona el original para continuar"
        case "ready": return "Guardado cifrado en este dispositivo · pendiente de enviar"
        case "uploading": return "Enviando bloques verificados a Nodus"
        case "staged": return "Bloques enviados · pendiente de publicar en la propiedad"
        case "available": return "Archivo aplicado en Nodus"
        case "discarded": return "Eliminación de la copia local pendiente de completar"
        default: return "Transferencia pausada · la copia permanece en este dispositivo"
        }
    }
}
