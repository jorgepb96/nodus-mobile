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
            "report": row, "image": try await cover(session: session, id: readerID, dataURL: false), "translations": .array([]), "annotations": .array([]), "revision": .null
        ])))
    }
    static func cover(session: SpaceSession, id: String, dataURL: Bool) async throws -> JSONValue {
        guard let fields = try await checkpoint(session: session, id: id)?.objectValue,
              let cover = fields["report"]?.objectValue?["mobileCover"]?.objectValue,
              let bytes = cover["bytes"]?.stringValue, let mime = cover["mime"]?.stringValue,
              mime == "image/jpeg", bytes.utf8.count <= 7_000_000, Data(base64Encoded: bytes) != nil else { return .null }
        if dataURL { return .string("data:\(mime);base64,\(bytes)") }
        return .object(["entityKind": .string("deep_research"), "entityId": .string(id), "requested": .bool(true), "status": .string("ready"), "provider": cover["model"]?.objectValue?["provider"] == .string("gemini") ? .string("google") : cover["model"]?.objectValue?["provider"] ?? .null, "model": cover["model"]?.objectValue?["model"] ?? .null, "style": cover["style"] ?? .null, "visualContext": cover["context"] ?? .null, "prompt": cover["prompt"] ?? .null, "assetRef": .null, "mimeType": .string(mime), "error": .null, "source": .string("ai"), "hasPrevious": .bool(false), "createdAt": fields["createdAt"] ?? .null, "updatedAt": fields["createdAt"] ?? .null])
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
                let route = reference.privateSource?.kind == .recording ? "recording" : reference.specialised?.collectionPath == "study-materials" ? "material" : "doc"
                let target = reference.kind == "study" ? "study:\(route):\(reference.recordId)" : "\(reference.kind):\(reference.recordId)"
                guard let locator = value.objectValue?["citationIndex"]?.objectValue?[target]?.objectValue,
                      let callKey = locator["callKey"]?.stringValue, callKey.hasPrefix("source:"),
                      let path = locator["path"]?.arrayValue, (2...4).contains(path.count),
                      var result = value.objectValue?["calls"]?.objectValue?[callKey]?.objectValue?["output"] else {
                    throw APIError(status: 404, code: "captured_source_missing", message: "Esta cita no tiene un extracto conservado en el informe. No se buscará otra fuente ni se abrirá una conexión para sustituirla.")
                }
                for component in path {
                    switch component {
                    case .string(let field):
                        guard ["entries", "frozen", "snapshot", "ideas", "works", "passages", "gaps", "contradictions", "sources"].contains(field), let next = result.objectValue?[field] else { throw DesktopBridgeError.malformedResponse }
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
                if callKey == "source:study", let sourceID = result.objectValue?["sourceId"], let kind = result.objectValue?["kind"],
                   let entries = value.objectValue?["calls"]?.objectValue?[callKey]?.objectValue?["output"]?.objectValue?["entries"]?.arrayValue {
                    let capturedEntries = entries.filter { $0.objectValue?["sourceId"] == sourceID && $0.objectValue?["kind"] == kind }
                    guard !capturedEntries.isEmpty else { throw DesktopBridgeError.malformedResponse }
                    result = .object(["title": result.objectValue?["title"] ?? .null, "passages": .array(capturedEntries)])
                }
                if callKey == "source:completeGuide", let sourceKey = result.objectValue?["sourceKey"]?.stringValue,
                   let passages = value.objectValue?["calls"]?.objectValue?[callKey]?.objectValue?["output"]?.objectValue?["frozen"]?.objectValue?["snapshot"]?.objectValue?["passages"]?.arrayValue {
                    let selected = passages.filter { passage in
                        guard passage.objectValue?["sourceKey"] == .string(sourceKey), let locator = passage.objectValue?["locator"]?.objectValue else { return false }
                        if let page = reference.specialised?.page { return locator["page"]?.intValue == page }
                        if let slide = reference.specialised?.slide { return locator["slide"]?.intValue == slide }
                        if let from = reference.specialised?.from { return (locator["from"]?.intValue ?? 0) <= from && (locator["to"]?.intValue ?? 0) > from }
                        if let time = reference.privateSource?.timestamp { return (locator["start"]?.doubleValue ?? 0) <= time && (locator["end"]?.doubleValue ?? 0) >= time }
                        return true
                    }
                    guard !selected.isEmpty else { throw DesktopBridgeError.malformedResponse }
                    result = .object(["title": result.objectValue?["title"] ?? .null, "passages": .array(selected)])
                }
                captured = result
            } catch { failure = error.localizedDescription }
        }
    }
}
