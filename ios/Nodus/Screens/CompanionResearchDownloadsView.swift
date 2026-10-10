import SwiftUI
import NodusKit

/// Downloads canonical query results, never a complete workspace backup.
/// Nothing is advertised as available until the entire selected pack commits.
struct CompanionResearchDownloadsView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case reports, dictionary, immersion
        var id: String { rawValue }
        var title: String {
            switch self { case .reports: "Informes"; case .dictionary: "Diccionario"; case .immersion: "Inmersiones" }
        }
    }
    let session: SpaceSession
    @State private var kind = Kind.reports
    @State private var catalogue: [JSONValue] = []
    @State private var catalogueRevision: String?
    @State private var selected = Set<String>()
    @State private var days = 7
    @State private var query = ""
    @State private var loading = false
    @State private var saved = false
    @State private var issue: String?
    @State private var progress: (done: Int, total: Int)?
    @State private var downloadTask: Task<Void, Never>?

    private var visible: [JSONValue] {
        catalogue.filter { query.isEmpty || title($0).localizedStandardContains(query) }
            .sorted { title($0).localizedStandardCompare(title($1)) == .orderedAscending }
    }
    private func title(_ row: JSONValue) -> String {
        let value = row.objectValue
        return value?["title"]?.stringValue ?? value?["name"]?.stringValue ?? value?["topic"]?.stringValue ?? "Sin título"
    }
    var body: some View {
        List {
            Section {
                Picker("Contenido", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.title).tag($0) }
                }.disabled(progress != nil)
                Picker("Conservar la descarga", selection: $days) {
                    Text("7 días").tag(7); Text("30 días").tag(30)
                }.disabled(progress != nil)
            } footer: {
                Text("Solo se descargan los elementos que elijas, con sus traducciones y anotaciones. Sin conexión, la galería muestra el contenido conservado en este dispositivo. Los originales de las fuentes se descargan por separado.")
            }
            if loading { ProgressView("Cargando contenido del Mac…") }
            if let issue {
                Section {
                    Text(issue).foregroundStyle(Color.nodusDanger).accessibilityIdentifier("companion-research-download-error")
                    if progress == nil { Button("Volver a cargar") { Task { await load() } } }
                }
            }
            if let progress {
                Section {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                    Text("Descargando \(progress.done) de \(progress.total)")
                    Button("Cancelar", role: .cancel) { downloadTask?.cancel() }
                }
            }
            if saved { Label("Descarga disponible sin conexión", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            if !loading, catalogue.isEmpty, issue == nil {
                Text("Todavía no hay contenido guardado en esta sección.").foregroundStyle(.secondary)
            }
            Section(kind.title) {
                ForEach(visible, id: \.downloadIdentity) { row in
                    if let id = row.objectValue?["id"]?.stringValue {
                        Button {
                            if !selected.insert(id).inserted { selected.remove(id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(id) ? "checkmark.circle.fill" : "circle").foregroundStyle(session.accent)
                                Text(title(row)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }.frame(minHeight: 44)
                        }.disabled(progress != nil || saved)
                            .accessibilityIdentifier("companion-download-\(kind.rawValue)-\(id)")
                            .accessibilityValue(selected.contains(id) ? "Seleccionado" : "Sin seleccionar")
                    }
                }
            }
        }
        .navigationTitle("Descargar para llevar")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Buscar")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Descargar") { downloadTask = Task { await download() } }
                    .disabled(selected.isEmpty || loading || progress != nil || saved)
                    .accessibilityIdentifier("companion-research-download-start")
            }
        }
        .task(id: kind) { await load() }
        .onDisappear { downloadTask?.cancel() }
    }

    private func connection() throws -> (String, DesktopBridgeClient, PrivateBridgeCache) {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        guard !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
        return (vault, DesktopBridgeClient(pairing: pairing, token: token), try PrivateBridgeCache(pairingId: pairing.id))
    }
    private func load() async {
        loading = true; issue = nil; saved = false; selected = []; catalogue = []; catalogueRevision = nil; query = ""
        let loadingKind = kind
        defer { if kind == loadingKind { loading = false } }
        do {
            let (vault, client, _) = try connection()
            let revision = try await session.client.snapshotRevision(in: session.connection.spaceId)
            let value: [JSONValue]
            if loadingKind == .dictionary || loadingKind == .reports {
                value = try await completePages(client: client, vault: vault,
                    method: loadingKind == .dictionary ? "listDictionaryEntries" : "listWritingWorkshopDownloadCatalogue", request: [:])
            } else {
                let result = try await client.operation(vaultId: vault, method: loadingKind == .reports ? "listWritingWorkshopDrafts" : "listImmersionSessions", args: [])
                guard let rows = result.arrayValue else { throw DesktopBridgeError.malformedResponse }
                value = rows
            }
            guard value.allSatisfy({ $0.objectValue?["id"]?.stringValue?.isEmpty == false }),
                  Set(value.compactMap { $0.objectValue?["id"]?.stringValue }).count == value.count else { throw DesktopBridgeError.malformedResponse }
            try Task.checkCancellation()
            let current = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard current == revision else { throw DesktopBridgeError.malformedResponse }
            if kind == loadingKind { catalogue = value; catalogueRevision = revision }
        } catch is CancellationError { }
        catch { if kind == loadingKind { issue = error.localizedDescription } }
    }
    /// A capped page is still traversed. A changing or incomplete catalogue is
    /// rejected rather than producing a download with missing evidence.
    private func completePages(client: DesktopBridgeClient, vault: String, method: String, request: [String: JSONValue], maxBytes: Int = PrivateBridgeCache.defaultReadLimitBytes) async throws -> [JSONValue] {
        var rows: [JSONValue] = [], ids = Set<String>(), total: Int?, bytes = 0
        repeat {
            try Task.checkCancellation()
            var input = request
            input["offset"] = .int(Int64(rows.count)); input["limit"] = .int(200)
            let value = try await client.operation(vaultId: vault, method: method, args: [.object(input)])
            bytes += try JSONEncoder.nodus.encode(value).count
            guard bytes <= maxBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            guard let page = value.objectValue, let items = page["items"]?.arrayValue,
                  let count = page["total"]?.intValue, count >= 0,
                  page["offset"]?.intValue == rows.count, total == nil || total == count,
                  rows.count + items.count <= count, !items.isEmpty || rows.count == count else { throw DesktopBridgeError.malformedResponse }
            total = count
            for item in items {
                guard let id = item.objectValue?["id"]?.stringValue, !id.isEmpty,
                      ids.insert((item.objectValue?["kind"]?.stringValue ?? "") + ":" + id).inserted else { throw DesktopBridgeError.malformedResponse }
                rows.append(item)
            }
        } while rows.count < total!
        return rows
    }

    private func download() async {
        issue = nil; progress = (0, selected.count)
        defer { progress = nil }
        do {
            let (vault, client, cache) = try connection()
            let revision = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard revision == catalogueRevision else { throw DesktopBridgeError.malformedResponse }
            let chosen = catalogue.filter { selected.contains($0.objectValue?["id"]?.stringValue ?? "") }
            guard chosen.count == selected.count, !chosen.isEmpty else { throw PrivateBridgeCache.ReadPackError.invalidSelection }
            var records: [PrivateBridgeCache.ReadPackRecord] = [], bytes = 0, dictionaryBytes = 0
            var citations = Set<JSONValue>()
            func collectCitations(_ value: JSONValue) {
                let kinds: Set<String> = ["idea", "work", "gap", "contradiction", "passage"]
                switch value {
                case .object(let object):
                    if let kind = object["kind"]?.stringValue, kinds.contains(kind), let id = object["id"]?.stringValue, !id.isEmpty {
                        citations.insert(.object(["kind": .string(kind), "id": .string(id)]))
                    }
                    object.values.forEach(collectCitations)
                case .array(let values): values.forEach(collectCitations)
                case .string(let text) where text.contains("nodus://"):
                    let pattern = #"nodus://(idea|work|gap|contradiction|passage)/[^\s)\]>\"'<>]+"#
                    if let expression = try? NSRegularExpression(pattern: pattern) {
                        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                            guard let range = Range(match.range, in: text), let url = URLComponents(string: String(text[range])),
                                  let kind = url.host, kinds.contains(kind) else { continue }
                            let id = String(url.path.dropFirst())
                            if !id.isEmpty { citations.insert(.object(["kind": .string(kind), "id": .string(id)])) }
                        }
                    }
                default: break
                }
            }
            func add(_ method: String, _ args: [JSONValue], _ value: JSONValue) throws {
                let data = try JSONEncoder.nodus.encode(value)
                bytes += data.count
                guard bytes + dictionaryBytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey(method, args), data: data))
            }
            func fetch(_ method: String, _ args: [JSONValue]) async throws -> JSONValue {
                try Task.checkCancellation()
                let value = try await client.operation(vaultId: vault, method: method, args: args)
                try add(method, args, value)
                if !["getDecorativeImageDataUrl", "getSettings"].contains(method) { collectCitations(value) }
                return value
            }
            _ = try await fetch("getSettings", [])
            if kind == .reports {
                _ = try await fetch("listDeepResearchJobs", [])
            } else if kind == .immersion {
                try add("listImmersionSessions", [], .array(chosen))
            } else {
                _ = try await fetch("listDictionaryGenerationJobs", [])
            }
            var dictionaryEntries: [JSONValue] = [], reports: [JSONValue] = []
            for (index, row) in chosen.enumerated() {
                let id = row.objectValue!["id"]!.stringValue!
                if kind == .dictionary {
                    let detail = try await fetch("getDictionaryEntry", [.string(id)])
                    guard detail.objectValue?["entry"]?.objectValue?["id"]?.stringValue == id else { throw DesktopBridgeError.malformedResponse }
                    let evidence = try await completePages(client: client, vault: vault, method: "listDictionaryEvidence", request: ["entryId": .string(id)], maxBytes: max(0, PrivateBridgeCache.defaultReadLimitBytes - bytes - dictionaryBytes))
                    let versions = try await fetch("listDictionaryVersions", [.string(id)])
                    guard let versionRows = versions.arrayValue,
                          versionRows.allSatisfy({ $0.objectValue?["entryId"]?.stringValue == id }),
                          evidence.allSatisfy({ $0.objectValue?["entryId"]?.stringValue == id }) else { throw DesktopBridgeError.malformedResponse }
                    let entry: JSONValue = .object(["detail": detail, "evidence": .array(evidence), "versions": versions])
                    dictionaryBytes += try JSONEncoder.nodus.encode(entry).count
                    guard bytes + dictionaryBytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                    dictionaryEntries.append(entry)
                    collectCitations(entry)
                    // The Mac prepares the read-only, revision-bound evidence
                    // context; the phone can then generate with its own provider.
                    _ = try await fetch("getDictionaryGenerationContext", [.string(id), .string("off")])
                    let current = try await client.operation(vaultId: vault, method: "getDictionaryEntry", args: [.string(id)])
                    guard current == detail else { throw DesktopBridgeError.malformedResponse }
                } else {
                    let entity = kind == .reports ? "deep_research" : "immersion"
                    let readerMethod = kind == .reports ? "getWritingWorkshopDraft" : "getImmersionSession"
                    let reader: JSONValue
                    if kind == .reports {
                        let report = try await fetch("getWritingWorkshopDraft", [.string(id)])
                        guard report.objectValue?["id"]?.stringValue == id, report.objectValue?["draft"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                        reports.append(report)
                        reader = report
                    } else {
                        let session = try await fetch("getImmersionSession", [.string(id)])
                        guard session.objectValue?["id"]?.stringValue == id, session.objectValue?["plan"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                        reader = session
                        if let topic = session.objectValue?["topic"]?.stringValue,
                           let language = session.objectValue?["language"]?.stringValue {
                            _ = try await fetch("getImmersionOfflineSource", [.object(["topic": .string(topic.trimmingCharacters(in: .whitespacesAndNewlines)), "language": .string(language)])])
                        }
                    }
                    let target: JSONValue = .object(["entityKind": .string(entity), "entityId": .string(id)])
                    let source = try await fetch("getContentTranslationOfflineSource", [target])
                    guard source.objectValue?["version"] == .int(1), source.objectValue?["entityKind"] == .string(entity),
                          source.objectValue?["entityId"] == .string(id), source.objectValue?["source"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                    let current = try await client.operation(vaultId: vault, method: readerMethod, args: [.string(id)])
                    guard current == reader else { throw DesktopBridgeError.malformedResponse }
                    let annotationsId = kind == .reports ? id : "immersion:" + id
                    _ = try await fetch("listWritingDraftAnnotations", [.string(annotationsId)])
                    let translations = try await fetch("listContentTranslations", [.string(entity), .string(id)])
                    guard let translations = translations.arrayValue else { throw DesktopBridgeError.malformedResponse }
                    for translation in translations {
                        guard let translationId = translation.objectValue?["id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
                        let full = try await fetch("getContentTranslation", [.string(translationId)])
                        guard full.objectValue?["entityKind"]?.stringValue == entity, full.objectValue?["entityId"]?.stringValue == id else { throw DesktopBridgeError.malformedResponse }
                    }
                    let image = try await fetch("getDecorativeImage", [.string(entity), .string(id)])
                    if image.objectValue?["status"]?.stringValue == "ready" {
                        let full = try await fetch("getDecorativeImageDataUrl", [.string(entity), .string(id), .bool(false)])
                        try validateImage(full)
                        try add("getDecorativeImageDataUrl", [.string(entity), .string(id)], full)
                        try validateImage(try await fetch("getDecorativeImageDataUrl", [.string(entity), .string(id), .bool(true)]))
                    }
                }
                progress = (index + 1, chosen.count)
            }
            if kind == .reports { try add("listWritingWorkshopDrafts", [], .array(reports)) }
            if !citations.isEmpty {
                func identity(_ ref: JSONValue) -> String {
                    (ref.objectValue?["kind"]?.stringValue ?? "") + ":" + (ref.objectValue?["id"]?.stringValue ?? "")
                }
                let refs = citations.sorted { identity($0) < identity($1) }
                let verified = try await fetch("verifyCitations", [.array(refs)])
                guard let map = verified.objectValue,
                      refs.allSatisfy({ map[($0.objectValue!["kind"]!.stringValue!) + ":" + ($0.objectValue!["id"]!.stringValue!)]?.boolValue != nil }) else { throw DesktopBridgeError.malformedResponse }
                let data = try JSONEncoder.nodus.encode(verified); bytes += data.count
                guard bytes + dictionaryBytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                records.append(.init(domain: .corpus, recordId: "companion:citations:v1", data: data))
                for ref in refs {
                    _ = try await fetch("getCitationPreview", [ref])
                    if ref.objectValue?["kind"]?.stringValue == "passage" {
                        _ = try await fetch("getPassage", [ref.objectValue!["id"]!])
                    }
                }
            }
            if kind == .dictionary {
                for method in ["listAuthors", "listWorks", "listZoteroTags", "listCollectionFacets"] {
                    _ = try await fetch(method, [])
                }
                let data = try JSONEncoder.nodus.encode(JSONValue.object(["version": .int(1), "entries": .array(dictionaryEntries)]))
                dictionaryBytes = 0; bytes += data.count
                guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                records.append(.init(domain: .corpus, recordId: "companion:dictionary:v1", data: data))
            }
            try Task.checkCancellation()
            let current = try await session.client.snapshotRevision(in: session.connection.spaceId)
            guard current == revision else { throw DesktopBridgeError.malformedResponse }
            let packId = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: selected.map { "\(kind.rawValue):\($0)" })
            try await cache.saveReadPack(id: packId, vaultId: vault, title: "\(kind.title) · \(chosen.count)",
                expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: records)
            saved = true
        } catch is CancellationError { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch let error as URLError where error.code == .cancelled { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch { issue = error.localizedDescription }
    }
    private func validateImage(_ value: JSONValue) throws {
        guard case .string(let url) = value, let comma = url.firstIndex(of: ","),
              url[..<comma].hasPrefix("data:image/"), url[..<comma].hasSuffix(";base64"),
              let bytes = Data(base64Encoded: String(url[url.index(after: comma)...])), !bytes.isEmpty else { throw DesktopBridgeError.malformedResponse }
    }
}

private extension JSONValue {
    var downloadIdentity: String { objectValue?["id"]?.stringValue ?? "" }
}
