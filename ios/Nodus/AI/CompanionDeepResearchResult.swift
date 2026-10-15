import Foundation
import NodusKit
import NodusUI
import SwiftUI

/// Reads only an explicitly identified authored result. This does not probe the
/// Mac, turn consulted data into a mirror, or borrow another grant's sources.
@MainActor
enum CompanionDeepResearchResult {
    static func checkpoint(session: SpaceSession, id: String, publishedReceipt: Bool = false) async throws -> JSONValue? {
        let localID = id.hasPrefix("mobile-dr-")
        guard localID || publishedReceipt else { return nil }
        let identity = localID ? String(id.dropFirst(10)) : id
        guard UUID(uuidString: identity) != nil else { return nil }
        let scope = try session.surfaceStorageScope()
        func matches(_ value: JSONValue) -> Bool {
            if localID { return value.objectValue?["id"] == .string(identity) }
            return value.objectValue?["state"] == .string("available")
                && value.objectValue?["result"]?.objectValue?["id"] == .string(identity)
        }
        let cache = try PrivateBridgeCache(pairingId: scope.cacheId)
        let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: "autonomous:deepResearch:index:v1")
        let entities = try bytes.map { try JSONDecoder.nodus.decode([String].self, from: $0) } ?? []
        let ledger = session.connection.desktopPairingId != nil ? try await DesktopJobLedgers.shared.ledger(pairingId: scope.cacheId, vaultId: scope.recordVaultId) : nil
        for entity in entities {
            let key = try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)
            guard let data = try await cache.data(vaultId: scope.recordVaultId, domain: .researchGeneration, recordId: key) else { continue }
            let stored = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
            let value = await ledger?.generationCheckpoint(recordId: key, generationId: stored.objectValue?["id"]?.stringValue) ?? stored
            if matches(value) {
                guard value.objectValue?["context"]?.objectValue?["vaultId"] == .string(scope.recordVaultId),
                      value.objectValue?["report"]?.objectValue?["draft"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                return value
            }
        }
        if let ledger {
            if let archived = await ledger.all().first(where: { matches($0.checkpoint ?? .null) && ["localDeepResearchGeneration", "saveMobileDeepResearchReport"].contains($0.method) })?.checkpoint,
               archived.objectValue?["context"]?.objectValue?["vaultId"] == .string(scope.recordVaultId),
               archived.objectValue?["report"]?.objectValue?["draft"]?.objectValue != nil { return archived }
        }
        if publishedReceipt && !localID { return nil }
        throw APIError(status: 404, code: "mobile_report_missing", message: "El informe escrito en este dispositivo no está disponible. Su identidad no se sustituirá por otro informe.")
    }
    static func detail(session: SpaceSession, id: String, publishedReceipt: Bool = false) async throws -> DeepResearchReportDetail? {
        guard let checkpoint = try await checkpoint(session: session, id: id, publishedReceipt: publishedReceipt), let fields = checkpoint.objectValue,
              let report = fields["report"]?.objectValue, let draft = report["draft"]?.objectValue else { return nil }
        guard let generationID = fields["id"]?.stringValue, UUID(uuidString: generationID) != nil else { throw DesktopBridgeError.malformedResponse }
        let readerID = publishedReceipt ? "mobile-dr-\(generationID)" : id
        let row: JSONValue = .object(["id": .string(readerID), "title": draft["title"] ?? .string("Informe"),
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
                let target = "\(reference.kind):\(reference.recordId)"
                guard let locator = value.objectValue?["citationIndex"]?.objectValue?[target]?.objectValue,
                      let callKey = locator["callKey"]?.stringValue, callKey.hasPrefix("source:"),
                      let path = locator["path"]?.arrayValue, (2...3).contains(path.count),
                      var result = value.objectValue?["calls"]?.objectValue?[callKey]?.objectValue?["output"] else {
                    throw APIError(status: 404, code: "captured_source_missing", message: "Esta cita no tiene un extracto conservado en el informe. No se buscará otra fuente ni se abrirá una conexión para sustituirla.")
                }
                for component in path {
                    switch component {
                    case .string(let field):
                        guard ["snapshot", "ideas", "works", "passages", "gaps", "contradictions", "sources"].contains(field), let next = result.objectValue?[field] else { throw DesktopBridgeError.malformedResponse }
                        result = next
                    case .int(let position):
                        guard let index = Int(exactly: position), let rows = result.arrayValue, rows.indices.contains(index) else { throw DesktopBridgeError.malformedResponse }
                        result = rows[index]
                    default: throw DesktopBridgeError.malformedResponse
                    }
                }
                if let citation = locator["citation"]?.stringValue {
                    guard let url = URL(string: citation), let capturedReference = CorpusReference(url), capturedReference.kind == reference.kind, capturedReference.recordId == reference.recordId else { throw DesktopBridgeError.malformedResponse }
                } else {
                    guard result.objectValue?["id"] == .string(reference.recordId) else { throw DesktopBridgeError.malformedResponse }
                }
                captured = result
            } catch { failure = error.localizedDescription }
        }
    }
}
