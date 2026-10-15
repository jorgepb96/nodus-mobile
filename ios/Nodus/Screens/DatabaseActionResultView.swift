import NodusKit
import NodusUI
import SwiftUI

/// Render retained cells and automation receipts, never raw checkpoint JSON or
/// base64. Publishing this view's existing result cannot invoke a model.
struct DatabaseActionResultView: View {
    let session: SpaceSession
    let request: DesktopJobLedger.Request
    let checkpoint: JSONValue
    @State private var latest: DesktopJobLedger.Request?
    @State private var busy = false
    @State private var confirmingResolution = false
    @State private var issue: String?
    private var current: DesktopJobLedger.Request { latest ?? request }
    private var value: JSONValue { current.checkpoint ?? checkpoint }
    private var fields: [String:JSONValue] { value.objectValue ?? [:] }
    private var source: [String:JSONValue] { fields["source"]?.objectValue ?? [:] }
    private var kind: String { fields["request"]?.objectValue?["kind"]?.stringValue ?? "" }
    private var operations: [JSONValue] {
        guard let raw = source["plan"], let id = fields["id"]?.stringValue, let time = fields["createdAt"]?.stringValue else { return [] }
        return (try? CompanionDatabaseActionCheckpoint.instantiate(raw, requestId: id, clickedAt: time).objectValue?["operations"]?.arrayValue) ?? []
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(source["title"]?.stringValue ?? "Resultado de la propiedad").font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                if let text = fields["text"]?.stringValue ?? current.result?.objectValue?["text"]?.stringValue {
                    ReportCopyButtons(markdown: text, title: "Resultado de la propiedad", accent: session.accent)
                    CorpusProse(text, accent: session.accent, session: session)
                }
                if let bytes = fields["bytes"]?.stringValue, let data = Data(base64Encoded: bytes), let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity).accessibilityIdentifier("database-action-image")
                }
                if let id = current.result?.objectValue?["attachment"]?.objectValue?["id"]?.stringValue { PrivateFileButton(session: session, kind: .databaseAttachment, id: id) }
                if kind == "button" { buttonReceipt }
                else if let runs = current.result?.objectValue?["runs"]?.arrayValue {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.objectValue?["status"]?.stringValue ?? "Estado no disponible").font(.subheadline.weight(.semibold))
                            if let completed = run.objectValue?["actionsCompleted"]?.intValue { Text("\(completed) acciones completadas").font(.caption) }
                            if let error = run.objectValue?["error"]?.stringValue { Text(error).font(.caption).foregroundStyle(.red) }
                        }
                    }
                }
                if let error = current.issue ?? fields["error"]?.stringValue { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if current.state == "available" { Label("Aplicado en Nodus", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                else if let saved = try? CompanionDatabaseActionCheckpoint(value), saved.publicationInput != nil {
                    Text("El resultado ya está guardado en el dispositivo. La publicación comprobará la revisión original de la fila y la propiedad.").font(.footnote).foregroundStyle(.secondary)
                    Button(current.state == "recoveryReview" ? "Revisar y publicar resultado" : "Publicar o reanudar resultado") { Task { await publish(saved) } }
                        .buttonStyle(NodusPrimaryButtonStyle(accent: session.accent)).disabled(busy).frame(minHeight: 44).accessibilityIdentifier("database-action-publish")
                } else if fields["buttonResult"]?.objectValue?["pendingWebhook"] != nil {
                    Text("La acción externa no tiene una respuesta confirmada. El registro se conserva y no se vuelve a enviar automáticamente.").font(.footnote).foregroundStyle(.secondary)
                    Button("Conservar sólo los pasos confirmados") { confirmingResolution = true }
                        .frame(minHeight: 44).disabled(busy).accessibilityIdentifier("database-action-resolve-interrupted")
                } else { Text("La petición permanece conservada. No se iniciará otra generación al abrirla.").font(.footnote).foregroundStyle(.secondary) }
                if busy { ProgressView("Publicando resultado guardado…") }
                if let issue { Text(issue).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding(NodusSpace.page).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }.confirmationDialog("Publicar únicamente los pasos confirmados", isPresented: $confirmingResolution, titleVisibility: .visible) {
            Button("Conservar y publicar pasos confirmados") { Task { await resolveInterrupted() } }
            Button("Cancelar", role: .cancel) { }
        } message: {
            Text("Se conservarán \(fields["buttonResult"]?.objectValue?["completedSteps"]?.intValue ?? 0) pasos. La acción externa pudo haberse recibido: no se reenviará ni se ejecutarán los pasos posteriores. Su intento y los recibos originales permanecerán guardados.")
        }.task(id: session.companionPublicationRevision) { await refresh() }.accessibilityIdentifier("database-action-result")
    }
    private var buttonReceipt: some View {
        let receipt = fields["buttonResult"]?.objectValue ?? [:]
        let completed = min(operations.count, max(0, receipt["completedSteps"]?.intValue ?? 0))
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(completed) de \(operations.count) pasos conservados").font(.headline)
            if receipt["resolution"] == .string("publishConfirmedPrefix") {
                Text("Resolución manual: se detuvo antes de la acción externa sin respuesta. No se reenviará. El registro original del intento permanece conservado.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(Array(operations.prefix(completed).enumerated()), id: \.offset) { index, operation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(label(operation)).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if operation.objectValue?["type"] == .string("notify") {
                        Text(operation.objectValue?["title"]?.stringValue ?? "Aviso").font(.callout)
                        if let body = operation.objectValue?["body"]?.stringValue { CorpusProse(body, accent: session.accent, session: session) }
                    }
                    if operation.objectValue?["type"] == .string("create_page"), let rowId = operation.objectValue?["rowId"]?.stringValue, let blocks = operation.objectValue?["blocks"]?.arrayValue {
                        NavigationLink("Abrir editor de bloques") { DatabaseActionPageEditor(session: session, checkpoint: value, rowId: rowId) }
                            .frame(minHeight: 44).accessibilityIdentifier("database-action-edit-page-" + rowId)
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            if let text = block.objectValue?["content"]?.objectValue?["text"]?.stringValue { CorpusProse(text, accent: session.accent, session: session) }
                        }
                    }
                    if operation.objectValue?["type"] == .string("webhook"), let response = receipt["webhooks"]?.objectValue?[String(index)]?.objectValue {
                        Text("HTTP \(response["httpStatus"]?.intValue ?? 0) · intento \(response["attempt"]?.intValue ?? 0)").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(10).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
    private func label(_ operation: JSONValue) -> String {
        switch operation.objectValue?["type"]?.stringValue {
        case "button_click": return "Pulsación registrada"
        case "set_property": return "Propiedad actualizada"
        case "create_page": return "Página creada en el dispositivo"
        case "notify": return "Aviso guardado"
        case "webhook": return "Respuesta de acción externa"
        default: return "Paso guardado"
        }
    }
    private func refresh() async {
        do {
            let (vault, pair, _) = try privateBridgeConnection(session, domain: .writing)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pair.id, vaultId: vault)
            latest = await ledger.all().first { $0.id == request.id }
        } catch { issue = error.localizedDescription }
    }
    private func resolveInterrupted() async {
        busy = true; issue = nil; defer { busy = false }
        do {
            latest = try await DatabasePropertyActions.resolveInterruptedButton(session: session, checkpoint: CompanionDatabaseActionCheckpoint(value))
            await session.synchronizeCompanionChanges(); await refresh()
        } catch { issue = error.localizedDescription }
    }
    private func publish(_ checkpoint: CompanionDatabaseActionCheckpoint) async {
        busy = true; issue = nil; defer { busy = false }
        do {
            latest = try await DatabasePropertyActions.preparePublication(session: session, checkpoint: checkpoint, approveRecovered: current.state == "recoveryReview")
            await session.synchronizeCompanionChanges(); await refresh()
        } catch { issue = error.localizedDescription }
    }
}
