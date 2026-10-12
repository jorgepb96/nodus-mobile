import NodusAI
import NodusKit
import NodusUI
import SwiftUI

/// Explicit image operations on an existing world map. The Mac job owns
/// persistence; dismissing this observer does not pretend to stop a provider.
struct WorldMapGenerationSheet: View {
    let session: SpaceSession
    let mapId: String
    let title: String
    var initialStyle: String = "parchment"
    let onSaved: () -> Void
    @Environment(AISettings.self) private var ai
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "create"
    @State private var style = "parchment"
    @State private var edge = "north"
    @State private var fraction = 0.5
    @State private var extra = ""
    @State private var status: String?
    @State private var issue: String?
    @State private var running = false
    @State private var downloading = false
    @State private var preview: UIImage?
    @State private var publicationPrepared = false
    @State private var record: DesktopJobLedger.Request?
    @State private var observer: Task<Void, Never>?
    private let styles = [("parchment","Pergamino"),("inked_atlas","Atlas a plumilla"),("painted_fantasy","Fantasía pintada"),("watercolour","Acuarela"),("satellite","Satélite"),("blueprint","Plano técnico"),("isometric","Isométrico"),("hand_drawn","Boceto a mano"),("dark_grimoire","Grimorio oscuro"),("nautical_chart","Carta náutica")]
    private var request: JSONValue {
        var value: [String: JSONValue] = ["mapId": .string(mapId), "mode": .string(mode), "extra": .string(extra)]
        if mode == "expand" { value["edge"] = .string(edge); value["fraction"] = .double(fraction) }
        else { value["style"] = .string(style) }
        return .object(value)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    Picker("Operación", selection: $mode) {
                        Text("Generar imagen").tag("create")
                        Text("Otra interpretación").tag("variant")
                        Text("Cambiar estilo").tag("restyle")
                        Text("Ampliar geografía").tag("expand")
                    }
                    if mode == "expand" {
                        Picker("Borde", selection: $edge) { Text("Norte").tag("north"); Text("Sur").tag("south"); Text("Este").tag("east"); Text("Oeste").tag("west") }
                        Picker("Ampliación", selection: $fraction) { Text("25 %").tag(0.25); Text("50 %").tag(0.5); Text("100 %").tag(1.0); Text("200 %").tag(2.0) }
                        Text("La imagen y todas las coordenadas del mapa se ampliarán juntas.").font(.caption)
                    } else { Picker("Estilo", selection: $style) { ForEach(styles, id: \.0) { item in Text(item.1).tag(item.0) } } }
                    TextField("Indicaciones para esta generación", text: $extra, axis: .vertical).lineLimit(3...8)
                }.disabled(running)
                Section {
                    if session.aiExecutionMode == .autonomous {
                        Text("El dispositivo usa su propio proveedor de imagen y las fuentes descargadas. Ampliar o cambiar el estilo requiere Gemini con imagen de referencia.").font(.caption)
                        Menu("Descargar fuentes e imagen para llevar") {
                            Button("7 días") { download(days: 7) }
                            Button("30 días") { download(days: 30) }
                        }.frame(minHeight: 44).disabled(running || downloading)
                    } else {
                        Text("El Mac usará su proveedor y modelo de imagen configurados. El trabajo y su resultado se conservan aunque cierres este panel.").font(.caption)
                    }
                    if let preview { Image(uiImage: preview).resizable().scaledToFit().accessibilityLabel("Resultado de generación conservado en este dispositivo") }
                    Button(record?.state == "available" ? "Generar de nuevo" : "Generar") { start(explicit: true) }
                        .frame(minHeight: 44).disabled(running || downloading || extra.utf16.count > 300 || !session.connection.role.canSendChanges)
                    if running { Button("Cancelar trabajo", role: .destructive) { Task { await cancel() } }.frame(minHeight: 44) }
                    if let status { Text(status).fixedSize(horizontal: false, vertical: true) }
                    if let issue { Text(issue).foregroundStyle(Color.nodusDanger).fixedSize(horizontal: false, vertical: true); Button("Reintentar la misma solicitud") { start(explicit: false) }.frame(minHeight: 44).disabled(running) }
                }
            }.navigationTitle("Generar mapa")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
                .task { style = initialStyle; await recover() }

        }
    }
    private func start(explicit: Bool) {
        guard !running else { return }
        observer = Task { await execute(explicit: explicit) }
    }
    private func restore(_ value: [String: JSONValue]) {
        mode = value["mode"]?.stringValue ?? "create"; style = value["style"]?.stringValue ?? style
        edge = value["edge"]?.stringValue ?? "north"; fraction = value["fraction"]?.doubleValue ?? 0.5; extra = value["extra"]?.stringValue ?? ""
    }
    private func recover() async {
        running = true
        defer { running = false }
        do {
            if session.aiExecutionMode == .autonomous {
                let journal = try await CompanionWorldMapGeneration.journal(session: session)
                if let summary = await journal.summaries().first(where: { $0.objectValue?["request"]?.objectValue?["mapId"] == .string(mapId) }),
                   let scope = summary.objectValue?["scope"]?.stringValue, var checkpoint = try await journal.load(scope: scope) {
                    if let value = checkpoint.value.objectValue?["request"]?.objectValue { restore(value) }
                    if let bytes = checkpoint.publication?.objectValue?["bytes"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) { preview = UIImage(data: bytes) }
                    if checkpoint.value.objectValue?["recoveryReviewRequired"] == .bool(true) { status = "Resultado recuperado. Revisa su publicación en Ajustes antes de enviarlo con la nueva vinculación."; return }
                    if checkpoint.state == .cancelled { status = "Generación cancelada en el dispositivo. Su resultado anterior se conserva."; return }
                    if CompanionWorldMapGeneration.isActive(session: session, mapId: mapId) { status = "Generando imagen en este dispositivo" }
                    if let observing = try await CompanionWorldMapGeneration.observeDevice(session: session, mapId: mapId) { record = observing }
                    else if checkpoint.publication != nil { record = try await CompanionWorldMapGeneration.preparePublication(session: session, checkpoint: checkpoint) }
                    else {
                        if [.accepted,.running].contains(checkpoint.state) { checkpoint = try checkpoint.changing(state: .interrupted, error: "La aplicación se cerró durante la generación. No se repetirá el proveedor automáticamente."); try await journal.put(checkpoint) }
                        status = checkpoint.state.rawValue; issue = checkpoint.value.objectValue?["error"]?.stringValue
                        return
                    }
                    await execute(explicit: false); return
                }
            }
            let (vault,pairing,_) = try privateBridgeConnection(session, domain: session.aiExecutionMode == .autonomous ? .writing : .researchGeneration)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
            guard let prior = await ledger.all().first(where: { $0.method == (session.aiExecutionMode == .autonomous ? "saveMobileWorldMapImage" : "generateMobileWorldMap") && ($0.args.first?.objectValue?["mapId"] ?? $0.args.first?.objectValue?["request"]?.objectValue?["mapId"]) == .string(mapId) }) else { return }
            record = prior
            if let value = (session.aiExecutionMode == .autonomous ? prior.args.first?.objectValue?["request"] : prior.args.first)?.objectValue { restore(value) }
            await execute(explicit: false)
        } catch { issue = error.localizedDescription }
    }
    private func execute(explicit: Bool) async {
        running = true; issue = nil; publicationPrepared = false
        if explicit, session.aiExecutionMode == .autonomous { record = nil }
        defer { running = false }
        do {
            let (vault,pairing,token) = try privateBridgeConnection(session, domain: session.aiExecutionMode == .autonomous ? .writing : .researchGeneration)
            let client = DesktopBridgeClient(pairing: pairing, token: token)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
            let matching = await ledger.all().first { $0.method == "generateMobileWorldMap" && $0.args == [request] && $0.cancellationRequested != true && ["pending","accepted","running","saved"].contains($0.state) }
            let intent: DesktopJobLedger.Request
            if session.aiExecutionMode == .autonomous {
                if !explicit, let record { intent = record }
                else {
                    let captured = try await CompanionWorldMapGeneration.source(session: session, mapId: mapId)
                    let model = try ai.model(for: .image).map { try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode($0)) }
                    let saved = await ledger.all().first { $0.method == "saveMobileWorldMapImage" && $0.cancellationRequested != true && ["pending","accepted","running","saved"].contains($0.state) && $0.args.first?.objectValue?["request"] == request && $0.args.first?.objectValue?["revision"] == .string(captured.revision) && $0.args.first?.objectValue?["model"] == model }
                    if let saved { intent = saved }
                    else { record = nil; status = "Generando imagen en este dispositivo"; intent = try await CompanionWorldMapGeneration.generate(session: session, request: request, ai: ai) }
                }
            } else if let matching { intent = matching }
            else if !explicit, let record { intent = record }
            else { intent = try await ledger.prepare(id: UUID().uuidString.lowercased(), method: "generateMobileWorldMap", args: [request]) }
            guard intent.state != "recoveryReview" else { throw APIError(status: 409, code: "recovery_review_required", message: "Revisa este resultado recuperado en Ajustes antes de publicarlo con la nueva vinculación.") }
            record = intent
            publicationPrepared = intent.method == "saveMobileWorldMapImage"
            if let bytes = intent.args.first?.objectValue?["bytes"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) { preview = UIImage(data: bytes); status = "Imagen conservada en este dispositivo; publicando sin usar modelos del Mac" }
            let job: DesktopBridgeJob
            if let id = intent.jobId { job = try await client.readJob(vaultId: vault, id: id) }
            else { job = try await client.submitJob(vaultId: vault, method: intent.method, args: intent.args, idempotencyKey: intent.id) }
            try await ledger.update(id: intent.id, job: job)
            let result = try await client.awaitJob(vaultId: vault, job: job, onState: { current in
                try await ledger.update(id: intent.id, job: current)
                await MainActor.run { status = "Mac · \(current.state.rawValue)" }
            }, onEvents: { events in
                let phase = events.last(where: { $0.channel == "mobile:worldMap:progress" })?.args.first?.objectValue?["phase"]?.stringValue
                await MainActor.run { if let phase { status = ["context":"Preparando el mapa", "generating":"Generando imagen en el Mac", "saving":"Guardando imagen y coordenadas"][phase] ?? phase } }
            })
            guard result.objectValue?["map"]?.objectValue?["mapId"] == .string(mapId) else { throw DesktopBridgeError.malformedResponse }
            status = result.objectValue?["notice"]?.stringValue ?? "Mapa guardado en el vault"
            record = await ledger.all().first { $0.id == intent.id }
            onSaved()
        } catch {
            if !error.isCancellation {
                if session.aiExecutionMode == .autonomous, publicationPrepared, preview != nil, isPrivateBridgeOffline(error) { status = "Imagen guardada en este dispositivo. La publicación se enviará al reconectar con tu Mac." }
                else { issue = error.localizedDescription.contains("map_generation_source_conflict") ? "El mapa cambió desde esta descarga. Conservamos la imagen generada; actualiza las fuentes antes de generar con el nuevo contexto." : error.localizedDescription }
            }
            if let record, let (vault,pairing,_) = try? privateBridgeConnection(session, domain: session.aiExecutionMode == .autonomous ? .writing : .researchGeneration), let ledger = try? await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault) {
                try? await ledger.disconnected(id: record.id, issue: error.localizedDescription)
            }
        }
    }
    private func download(days: Int) {
        downloading = true; issue = nil
        Task {
            defer { downloading = false }
            do { try await CompanionWorldMapGeneration.download(session: session, mapId: mapId, days: days); status = "Fuentes e imagen descargadas para \(days) días" }
            catch { issue = error.localizedDescription }
        }
    }
    private func cancel() async {
        if session.aiExecutionMode == .autonomous, CompanionWorldMapGeneration.isActive(session: session, mapId: mapId) {
            CompanionWorldMapGeneration.cancelDevice(session: session, mapId: mapId); status = "Cancelación solicitada al proveedor del dispositivo"; return
        }
        guard let record else { status = "No hay un trabajo pendiente que cancelar"; return }
        do {
            let (vault,pairing,token) = try privateBridgeConnection(session, domain: session.aiExecutionMode == .autonomous ? .writing : .researchGeneration)
            let client = DesktopBridgeClient(pairing: pairing, token: token)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
            try await ledger.requestCancellation(id: record.id)
            status = "Cancelación guardada en este dispositivo; comunicándola al Mac"
            let cancelled = try await client.cancelJobRequest(vaultId: vault, method: record.method, args: record.args, idempotencyKey: record.id)
            try await ledger.update(id: record.id, job: cancelled)
            status = "Cancelación solicitada; se impedirá guardar el resultado. El proveedor puede terminar su solicitud en curso."
        } catch { issue = error.localizedDescription }
    }
}
