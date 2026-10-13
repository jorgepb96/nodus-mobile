import Foundation
import NodusKit
import NodusUI
import SwiftUI

/// Reads only an explicitly identified authored result. This does not probe the
/// Mac, turn consulted data into a mirror, or borrow another grant's sources.
@MainActor
enum CompanionDeepResearchResult {
    static func checkpoint(session: SpaceSession, id: String) async throws -> JSONValue? {
        guard id.hasPrefix("mobile-dr-"), UUID(uuidString: String(id.dropFirst(10))) != nil else { return nil }
        let identity = String(id.dropFirst(10)), scope = try session.surfaceStorageScope()
        let cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: "autonomous:deepResearch:index:v1")
        let entities = try bytes.map { try JSONDecoder.nodus.decode([String].self, from: $0) } ?? []
        for entity in entities {
            let key = try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)
            guard let data = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: key) else { continue }
            let value = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
            if value.objectValue?["id"] == .string(identity) {
                guard value.objectValue?["context"]?.objectValue?["vaultId"] == .string(scope.recordVaultId),
                      value.objectValue?["report"]?.objectValue?["draft"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                return value
            }
        }
        if session.connection.desktopPairingId != nil {
            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId)
            if let archived = await ledger.all().first(where: { $0.id == identity && ["localDeepResearchGeneration", "saveMobileDeepResearchReport"].contains($0.method) })?.checkpoint,
               archived.objectValue?["context"]?.objectValue?["vaultId"] == .string(scope.recordVaultId),
               archived.objectValue?["report"]?.objectValue?["draft"]?.objectValue != nil { return archived }
        }
        throw APIError(status: 404, code: "mobile_report_missing", message: "El informe escrito en este dispositivo no está disponible. Su identidad no se sustituirá por otro informe.")
    }
    static func detail(session: SpaceSession, id: String) async throws -> DeepResearchReportDetail? {
        guard let checkpoint = try await checkpoint(session: session, id: id), let fields = checkpoint.objectValue,
              let report = fields["report"]?.objectValue, let draft = report["draft"]?.objectValue else { return nil }
        let row: JSONValue = .object(["id": .string(id), "title": draft["title"] ?? .string("Informe"),
            "objective": fields["request"]?.objectValue?["objective"] ?? .null, "draft": .object(draft),
            "meta": report["meta"] ?? .null, "model": fields["request"]?.objectValue?["model"] ?? .null,
            "created_at": fields["createdAt"] ?? .null, "updated_at": fields["createdAt"] ?? .null])
        return try JSONDecoder.nodus.decode(DeepResearchReportDetail.self, from: JSONEncoder.nodus.encode(JSONValue.object([
            "report": row, "image": .null, "translations": .array([]), "annotations": .array([]), "revision": .null
        ])))
    }
    static func draft(session: SpaceSession, id: String) async throws -> JSONValue? {
        try await checkpoint(session: session, id: id)?.objectValue?["report"]?.objectValue?["draft"]
    }
}

/// A captured generation candidate is consulted as captured evidence, without
/// presenting its summary as a complete live source or recreating corpus rows.
struct CompanionDeepResearchCitationView: View {
    let session: SpaceSession
    let reportId: String
    let reference: CorpusReference
    @State private var captured: JSONValue?
    @State private var failure: String?
    var body: some View {
        Group {
            if let captured {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Fuente conservada al escribir este informe", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                        Text("Esta vista conserva el material consultado durante la investigación; puede incluir extractos o resúmenes y no sustituye al documento completo.").font(.caption).foregroundStyle(.secondary)
                        DossierValueView(session: session, value: captured, field: "", linkedCollection: nil)
                    }.padding(16)
                }
            } else if let failure { ContentUnavailableView("Fuente no conservada", systemImage: "doc.questionmark", description: Text(failure)) }
            else { ProgressView() }
        }
        .environment(\.authoredResearchReaderID, reportId)
        .environment(\.downloadedReaderOnly, true)
        .navigationTitle("Fuente citada").nodusPageBackdrop(accent: session.accent)
        .task(id: "\(reportId)|\(reference.recordId)") {
            do {
                guard let value = try await CompanionDeepResearchResult.checkpoint(session: session, id: reportId) else { throw DesktopBridgeError.malformedResponse }
                let groups = ["idea": "ideas", "work": "works", "passage": "passages", "gap": "gaps", "contradiction": "contradictions", "debate": "contradictions"]
                let kind = reference.kind, identity = reference.recordId
                func find(_ node: JSONValue) -> JSONValue? {
                    if let object = node.objectValue {
                        if let group = groups[kind], let rows = object[group]?.arrayValue,
                           let match = rows.first(where: { $0.objectValue?["id"] == .string(identity) || $0.objectValue?["nodus_id"] == .string(identity) }) { return match }
                        for (key, child) in object where key != "request" && key != "report" && key != "input" {
                            if let found = find(child) { return found }
                        }
                    } else if let array = node.arrayValue {
                        for child in array { if let found = find(child) { return found } }
                    }
                    return nil
                }
                guard let result = find(value) else { throw APIError(status: 404, code: "captured_source_missing", message: "Esta cita no tiene un extracto conservado en el informe. No se buscará otra fuente ni se abrirá una conexión para sustituirla.") }
                captured = result
            } catch { failure = error.localizedDescription }
        }
    }
}
