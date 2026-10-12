import NodusKit
import SwiftUI

struct LiveJobsView: View {
    let session: SpaceSession
    @State private var pending: [DesktopJobLedger.Request] = []
    @State private var jobs: [DesktopBridgeJob] = []
    @State private var issue: String?
    @State private var loading = false
    var body: some View {
        List {
            if let issue { Section { Text(issue).foregroundStyle(.red) } }
            if loading { ProgressView() }
            ForEach(pending) { request in
                let job = jobs.first { $0.id == request.jobId }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title(request.method, args: request.args)).font(.headline)
                    Text(request.cancellationRequested == true && ["pending", "accepted", "running", "saved"].contains(request.state)
                        ? "Cancelación pendiente de confirmar con el Mac"
                        : request.checkpoint != nil && request.state == "pending"
                        ? "Guardado en este dispositivo · pendiente de sincronizar"
                        : status(job?.state.rawValue ?? request.state)).font(.subheadline)
                    Text(request.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    if let checkpoint = request.checkpoint {
                        NavigationLink("Abrir resultado guardado") {
                            CompanionGeneratedResultView(session: session, request: request, checkpoint: checkpoint)
                        }.frame(minHeight: 44).accessibilityIdentifier("companion-generated-result-\(request.id)")
                    } else if ["runMobileSpaceAction", "buildArgumentMap"].contains(request.method), let result = request.result, result != .null {
                        NavigationLink("Consultar resultado") {
                            CompanionGeneratedResultView(session: session, request: request, checkpoint: .object(["preview": result]))
                        }.frame(minHeight: 44).accessibilityIdentifier("companion-action-result-\(request.id)")
                    }
                    if let error = job?.error ?? request.issue { Text(error).font(.caption).foregroundStyle(.red) }
                    if ["pending", "accepted", "running", "saved"].contains(job?.state.rawValue ?? request.state)
                        || (job?.state == .interrupted && ["enqueueDeepResearchJob", "enqueueDatabaseDeepResearch"].contains(request.method)) {
                        HStack {
                            Button("Recuperar solicitud") { Task { await recover(request) } }
                                .disabled(loading || request.cancellationRequested == true || (session.aiExecutionMode != .live && !DesktopBridgeClient.isProviderFreeJob(method: request.method, args: request.args)))
                            Button("Cancelar", role: .destructive) { Task { await cancel(request) } }
                                .disabled(loading || request.cancellationRequested == true)
                        }
                    }
                    if job?.state == .interrupted { Text("Review the result in the vault before starting this generation again.").font(.caption) }
                }.padding(.vertical, 5)
            }
            if pending.isEmpty, !loading, issue == nil { ContentUnavailableView("No pending requests", systemImage: "tray") }
        }
        .navigationTitle("Trabajos y resultados")
        .accessibilityIdentifier("live-job-ledger")
        .task(id: session.companionPublicationRevision) { await refresh() }
        .refreshable { await refresh() }
    }
    private func connection() throws -> (DesktopBridgePairing, DesktopBridgeClient, String) {
        let store = DesktopBridgePairingStore()
        guard let vault = session.vaultId, let pair = store.pairings().first(where: { $0.id == session.connection.desktopPairingId }),
            let token = store.credential(for: pair) else { throw DesktopBridgeError.permissionDenied }
        return (pair, DesktopBridgeClient(pairing: pair, token: token), vault)
    }
    private func refresh() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let (pair, client, vault) = try connection()
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pair.id, vaultId: vault)
            pending = await ledger.all()
            jobs = try await client.listJobs(vaultId: vault)
            for request in pending { if let job = jobs.first(where: { $0.id == request.jobId }) { try await ledger.update(id: request.id, job: job) } }
            pending = await ledger.all(); issue = nil
        } catch { issue = error.localizedDescription }
    }
    private func recover(_ request: DesktopJobLedger.Request) async {
        guard request.cancellationRequested != true,
              session.aiExecutionMode == .live || DesktopBridgeClient.isProviderFreeJob(method: request.method, args: request.args) else { return }
        do {
            let (pair, client, vault) = try connection()
            let job = try await client.submitJob(vaultId: vault, method: request.method, args: request.args, idempotencyKey: request.id)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pair.id, vaultId: vault)
            try await ledger.update(id: request.id, job: job)
            await refresh()
        } catch { issue = error.localizedDescription }
    }
    private func cancel(_ request: DesktopJobLedger.Request) async {
        do { let (_, client, vault) = try connection(); try await client.cancelDurableJob(vaultId: vault, requestId: request.id); await refresh() }
        catch { await refresh(); issue = error.localizedDescription }
    }
    private func title(_ method: String, args: [JSONValue]) -> String {
        if ["localAcademicGeneration", "localWorkshopGeneration"].contains(method) { return "Respuesta anterior del móvil" }
        if method == "runMobileSpaceAction", let kind = args.first?.objectValue?["kind"]?.stringValue {
            return ["idea.delete": "Eliminar idea", "idea.saveToNotes": "Guardar idea en notas", "deepResearch.saveToNotes": "Guardar investigación en notas", "hypothesis.saveToNotes": "Guardar hipótesis", "projects.create": "Crear proyecto", "projects.update": "Guardar proyecto", "projects.section.update": "Guardar sección", "projects.chapter.import": "Importar capítulo", "pages.restoreRevision": "Restaurar versión", "databases.importCSV": "Importar CSV", "worldbuilding.entityDelete": "Eliminar entidad", "worldbuilding.continuity": "Revisar continuidad", "author.synthesis.generate": "Síntesis de autor", "authors.matrix.generate": "Matriz de autores", "argumentMap.generate": "Mapa de argumentos", "writing.generate": "Asistencia de escritura", "worldbuilding.proseReview": "Revisión de prosa"][kind] ?? "Cambios de contenido"
        }
        return ["generateMobileWorldMap":"Imagen y geografía del mapa", "saveMobileDatabaseResearchReport":"Informe de datos del móvil", "saveDictionaryGeneratedVersion": "Definición del diccionario", "saveImmersionGeneratedSession": "Inmersión del móvil", "saveContentTranslationFromMobile": "Traducción del móvil", "saveStudyImprovementFromMobile": "Asistencia de escritura del móvil", "startDictionaryGeneration": "Diccionario", "enqueueDeepResearchJob": "Deep Research", "enqueueDatabaseDeepResearch": "Deep Research de datos", "worldChatStream": "Chat del mundo", "dbChatStream": "Chat de bases de datos", "streamStudyAssistant": "Chat de estudio", "exportDatabaseDeepResearchReport": "Exportar informe de datos", "exportWritingWorkshopDraft": "Exportar informe", "exportDeepResearchArchive": "Descargar informes", "exportImmersionSessionPdf": "Exportar inmersión", "generateImmersionSession": "Inmersión", "generateWritingWorkshopDraft": "Informe", "generateContentTranslation": "Traducción", "generateReportImage": "Imagen del informe", "researchChat": "Chat", "researchChatStream": "Chat", "improveStudyText": "Asistencia de escritura", "buildArgumentMap": "Mapa de argumentos", "scanDictionaryNewEvidence": "Evidencias del diccionario", "generateConversationTitle": "Título de conversación"][method] ?? method
    }
    private func status(_ state: String) -> String {
        ["pending": "Pendiente de enviar al Mac", "accepted": "Aceptado por el Mac", "running": "Ejecutándose en el Mac", "saved": "Resultado guardado", "available": "Resultado disponible", "failed": "No se pudo completar", "interrupted": "Interrumpido al reiniciar el Mac", "cancelled": "Cancelado"][state] ?? state
    }
}
