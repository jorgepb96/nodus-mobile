import NodusKit
import NodusUI
import SwiftUI

/// Explicit image operations on an existing world map. The Mac job owns
/// persistence; dismissing this observer does not pretend to stop a provider.
struct WorldMapGenerationSheet: View {
    let session: SpaceSession
    let source: WorldMapReadSource
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "create"
    @State private var style = "parchment"
    @State private var edge = "north"
    @State private var fraction = 0.5
    @State private var extra = ""
    @State private var status: String?
    @State private var issue: String?
    @State private var running = false
    @State private var record: DesktopJobLedger.Request?
    @State private var observer: Task<Void, Never>?
    private let styles = [("parchment","Pergamino"),("inked_atlas","Atlas a plumilla"),("painted_fantasy","Fantasía pintada"),("watercolour","Acuarela"),("satellite","Satélite"),("blueprint","Plano técnico"),("isometric","Isométrico"),("hand_drawn","Boceto a mano"),("dark_grimoire","Grimorio oscuro"),("nautical_chart","Carta náutica")]
    private var mapId: String { source.map.string("mapId") ?? "" }
    private var request: JSONValue {
        var value: [String: JSONValue] = ["mapId": .string(mapId), "mode": .string(mode), "extra": .string(extra)]
        if mode == "expand" { value["edge"] = .string(edge); value["fraction"] = .double(fraction) }
        else { value["style"] = .string(style) }
        return .object(value)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(source.map.text("name") ?? "Mapa") {
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
                        Text("La generación geográfica autónoma aún requiere una fuente de generación y una imagen de referencia descargadas. Este panel no enviará la generación al Mac mientras esté seleccionado el modo autónomo.").font(.callout)
                    } else {
                        Text("El Mac usará su proveedor y modelo de imagen configurados. El trabajo y su resultado se conservan aunque cierres este panel.").font(.caption)
                        Button(record?.state == "available" ? "Generar de nuevo" : "Generar") { start(explicit: true) }
                            .frame(minHeight: 44).disabled(running || extra.count > 300 || !session.connection.role.canSendChanges)
                        if running { Button("Cancelar trabajo", role: .destructive) { Task { await cancel() } }.frame(minHeight: 44) }
                    }
                    if let status { Text(status).fixedSize(horizontal: false, vertical: true) }
                    if let issue { Text(issue).foregroundStyle(Color.nodusDanger).fixedSize(horizontal: false, vertical: true); Button("Reintentar la misma solicitud") { start(explicit: false) }.frame(minHeight: 44).disabled(running) }
                }
            }.navigationTitle("Generar mapa")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cerrar") { dismiss() } } }
                .task { style = source.map.string("style") ?? "parchment"; await recover() }
                .onDisappear { observer?.cancel() }
        }
    }
    private func start(explicit: Bool) {
        guard !running, session.aiExecutionMode == .live else { return }
        observer = Task { await execute(explicit: explicit) }
    }
    private func recover() async {
        guard session.aiExecutionMode == .live else { return }
        do {
            let (vault,pairing,_) = try privateBridgeConnection(session, domain: .researchGeneration)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
            guard let prior = await ledger.all().first(where: { $0.method == "generateMobileWorldMap" && $0.args.first?.objectValue?["mapId"] == .string(mapId) }) else { return }
            record = prior
            // Reopen restores the exact request, never starts another provider call.
            if let value = prior.args.first?.objectValue {
                mode = value["mode"]?.stringValue ?? "create"; style = value["style"]?.stringValue ?? style
                edge = value["edge"]?.stringValue ?? "north"; fraction = value["fraction"]?.doubleValue ?? 0.5; extra = value["extra"]?.stringValue ?? ""
            }
            await execute(explicit: false)
        } catch { issue = error.localizedDescription }
    }
    private func execute(explicit: Bool) async {
        running = true; issue = nil
        defer { running = false }
        do {
            let (vault,pairing,token) = try privateBridgeConnection(session, domain: .researchGeneration)
            let client = DesktopBridgeClient(pairing: pairing, token: token)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
            let matching = await ledger.all().first { $0.method == "generateMobileWorldMap" && $0.args == [request] && $0.cancellationRequested != true && ["pending","accepted","running","saved"].contains($0.state) }
            let intent: DesktopJobLedger.Request
            if let matching { intent = matching }
            else if !explicit, let record { intent = record }
            else { intent = try await ledger.prepare(id: UUID().uuidString.lowercased(), method: "generateMobileWorldMap", args: [request]) }
            record = intent
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
            if !error.isCancellation { issue = error.localizedDescription }
            if let record, let (vault,pairing,_) = try? privateBridgeConnection(session, domain: .researchGeneration), let ledger = try? await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault) {
                try? await ledger.disconnected(id: record.id, issue: error.localizedDescription)
            }
        }
    }
    private func cancel() async {
        guard let record else { return }
        do {
            let (vault,pairing,token) = try privateBridgeConnection(session, domain: .researchGeneration)
            let client = DesktopBridgeClient(pairing: pairing, token: token)
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
            try await ledger.requestCancellation(id: record.id)
            let cancelled = try await client.cancelJobRequest(vaultId: vault, method: record.method, args: record.args, idempotencyKey: record.id)
            try await ledger.update(id: record.id, job: cancelled)
            status = "Cancelación solicitada; se impedirá guardar el resultado. El proveedor puede terminar su solicitud en curso."
        } catch { issue = error.localizedDescription }
    }
}
