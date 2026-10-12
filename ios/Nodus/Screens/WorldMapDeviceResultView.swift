import NodusKit
import SwiftUI

struct WorldMapDeviceResultView: View {
    let session: SpaceSession
    let scope: String
    var savedRequest: DesktopJobLedger.Request? = nil
    @State private var showGeneration = false
    @State private var checkpoint: CompanionWorldMapGenerationCheckpoint?
    @State private var issue: String?
    @State private var busy = false
    @State private var receipt: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let checkpoint {
                    Text(checkpoint.value.objectValue?["title"]?.stringValue ?? "Mapa").font(.title2).fixedSize(horizontal: false, vertical: true)
                    if checkpoint.value.objectValue?["recoveryReviewRequired"] == .bool(true) { Text("Resultado recuperado. Revisa su publicación en Ajustes antes de enviarlo con la nueva vinculación.").fixedSize(horizontal: false, vertical: true) }
                    Text(deviceMapState(checkpoint.state.rawValue)).foregroundStyle(.secondary)
                    if let error = checkpoint.value.objectValue?["error"]?.stringValue { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                    if let bytes = checkpoint.publication?.objectValue?["bytes"]?.stringValue.flatMap({ Data(base64Encoded: $0) }), let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Imagen generada y guardada en este dispositivo")
                        if checkpoint.state != .cancelled, checkpoint.value.objectValue?["recoveryReviewRequired"] != .bool(true) {
                            Button("Publicar resultado guardado") { publish(checkpoint) }.frame(minHeight: 44).disabled(busy || !session.connection.role.canSendChanges)
                        }
                    }
                    if CompanionWorldMapGeneration.isActive(session: session, mapId: checkpoint.mapId) {
                        Button("Cancelar generación", role: .destructive) { CompanionWorldMapGeneration.cancelDevice(session: session, mapId: checkpoint.mapId) }.frame(minHeight: 44)
                    }
                    Button("Controles de generación del dispositivo") { showGeneration = true }.frame(minHeight: 44).disabled(!session.connection.role.canSendChanges)
                    NavigationLink("Abrir mapa") { WorldMapView(session: session, initialMapId: checkpoint.mapId) }.frame(minHeight: 44)
                }
                if busy { ProgressView() }
                if let receipt { Text(receipt).fixedSize(horizontal: false, vertical: true) }
                if let issue { Text(issue).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.padding()
        }.navigationTitle("Resultado del dispositivo")
            .sheet(isPresented: $showGeneration) {
                if let checkpoint { WorldMapGenerationSheet(session: session, mapId: checkpoint.mapId, title: checkpoint.value.objectValue?["title"]?.stringValue ?? "Mapa", initialStyle: checkpoint.value.objectValue?["request"]?.objectValue?["style"]?.stringValue ?? "parchment") { } }
            }.task {
            repeat {
                await load()
                guard let checkpoint, [.accepted,.running].contains(checkpoint.state), CompanionWorldMapGeneration.isActive(session: session, mapId: checkpoint.mapId) else { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            } while !Task.isCancelled
        }
    }
    private func load() async {
        do {
            if let savedRequest, let input = savedRequest.args.first?.objectValue {
                if let value = savedRequest.checkpoint { checkpoint = try CompanionWorldMapGenerationCheckpoint(value) }
                else {
                    var value = input; value["version"] = .int(1); value["id"] = input["requestId"]; value["state"] = .string("saved")
                    value["createdAt"] = .string(ISO8601DateFormatter().string(from: savedRequest.createdAt))
                    value["title"] = savedRequest.result?.objectValue?["map"]?.objectValue?["name"] ?? .string("Imagen del mapa")
                    if savedRequest.state == "recoveryReview" { value["recoveryReviewRequired"] = .bool(true) }
                    checkpoint = try CompanionWorldMapGenerationCheckpoint(.object(value))
                }
                return
            }
            let journal = try await CompanionWorldMapGeneration.journal(session: session)
            var value = try await journal.load(scope: scope)
            if let existing = value, [.accepted,.running].contains(existing.state), !CompanionWorldMapGeneration.isActive(session: session, mapId: existing.mapId) {
                value = try existing.changing(state: .interrupted, error: "La aplicación se cerró durante la generación. No se repetirá el proveedor automáticamente.")
                if let value { try await journal.put(value) }
            }
            checkpoint = value
        } catch { issue = error.localizedDescription }
    }
    private func publish(_ checkpoint: CompanionWorldMapGenerationCheckpoint) {
        busy = true; issue = nil
        Task {
            defer { busy = false }
            do {
                let request = try await CompanionWorldMapGeneration.preparePublication(session: session, checkpoint: checkpoint)
                let (vault,pairing,token) = try privateBridgeConnection(session, domain: .writing)
                let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vault)
                let client = DesktopBridgeClient(pairing: pairing, token: token)
                let job: DesktopBridgeJob
                if let id = request.jobId { job = try await client.readJob(vaultId: vault, id: id) }
                else { job = try await client.submitJob(vaultId: vault, method: request.method, args: request.args, idempotencyKey: request.id) }
                try await ledger.update(id: request.id, job: job)
                _ = try await client.awaitJob(vaultId: vault, job: job, onState: { current in try await ledger.update(id: request.id, job: current) }, onEvents: { _ in })
                receipt = "Imagen publicada en el vault sin ejecutar modelos del Mac"
            } catch {
                if isPrivateBridgeOffline(error) { receipt = "Imagen conservada en este dispositivo. Su publicación se enviará al reconectar con el Mac." }
                else { issue = error.localizedDescription.contains("map_generation_source_conflict") ? "El mapa cambió desde esta descarga. La imagen se conserva; actualiza sus fuentes antes de generar con el nuevo contexto." : error.localizedDescription }
            }
        }
    }
}
func deviceMapState(_ value: String) -> String {
    ["accepted":"Solicitud guardada en este dispositivo", "running":"Generando imagen en este dispositivo", "saved":"Imagen guardada en este dispositivo", "failed":"No se pudo completar en el dispositivo", "cancelled":"Generación cancelada", "interrupted":"Generación interrumpida al cerrar la aplicación"][value] ?? value
}
