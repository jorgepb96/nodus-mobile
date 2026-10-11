import NodusKit
import NodusUI
import SwiftUI

struct CompanionDatabaseResearchDownloadsView: View {
    let session:SpaceSession
    @State private var items:[JSONValue] = []
    @State private var selected = Set<String>()
    @State private var catalogueRevision:String?
    @State private var days = 7
    @State private var loading = false
    @State private var saved = false
    @State private var issue:String?
    @State private var progress:Int?
    @State private var task:Task<Void,Never>?
    @State private var query = ""
    var body:some View {
        List {
            Section {
                Picker("Conservar la descarga",selection:$days) { Text("7 días").tag(7); Text("30 días").tag(30) }.disabled(progress != nil)
            } footer: { Text("Elige los informes que quieras llevar contigo. Se conservan sus secciones, gráficos y evidencias. Tus anotaciones y cambios pendientes se guardan aparte y no caducan.") }
            if loading { ProgressView("Cargando informes del Mac…") }
            if let issue { Section { Text(issue).foregroundStyle(Color.nodusDanger); if progress == nil { Button("Reintentar") { Task { await load() } } } } }
            if let progress { Section { ProgressView(value:Double(progress),total:Double(max(1,selected.count))); Button("Cancelar",role:.cancel) { task?.cancel() } } }
            if saved { Label("Informes disponibles sin conexión",systemImage:"checkmark.circle.fill").foregroundStyle(.green) }
            if !loading,items.isEmpty,issue == nil { Text("Todavía no hay informes de datos guardados.").foregroundStyle(.secondary) }
            ForEach(items.filter { query.isEmpty || ($0.objectValue?["title"]?.stringValue ?? "").localizedStandardContains(query) },id:\.databaseReportIdentity) { item in
                if let id = item.objectValue?["id"]?.stringValue {
                    Button { if !selected.insert(id).inserted { selected.remove(id) } } label: {
                        HStack(spacing:12) { Image(systemName:selected.contains(id) ? "checkmark.circle.fill":"circle").foregroundStyle(session.accent)
                            Text(item.objectValue?["title"]?.stringValue ?? "Informe").foregroundStyle(.primary).multilineTextAlignment(.leading) }.frame(minHeight:44)
                    }.disabled(progress != nil || saved).accessibilityIdentifier("companion-download-database-report-\(id)")
                }
            }
        }.navigationTitle("Informes de datos para llevar").navigationBarTitleDisplayMode(.inline).searchable(text:$query,prompt:"Buscar")
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Descargar") { task = Task { await download() } }.disabled(selected.isEmpty || loading || progress != nil || saved) } }
            .task { await load() }.onDisappear { task?.cancel() }
    }
    private func connection() throws -> (String,DesktopBridgePairing,DesktopBridgeClient,PrivateBridgeCache) {
        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
        return (vault,pairing,DesktopBridgeClient(pairing:pairing,token:token),try PrivateBridgeCache(pairingId:pairing.id))
    }
    private func load() async {
        loading = true; issue = nil; saved = false; selected = []; defer { loading = false }
        do { let (vault,_,client,_) = try connection(); let catalogue = try await CompanionDatabaseResearchCopy.catalogue(client:client,vaultId:vault)
            items = catalogue.items; catalogueRevision = catalogue.revision
        } catch where error.isCancellation {} catch { issue = error.localizedDescription }
    }
    private func download() async {
        progress = 0; issue = nil; defer { progress = nil }
        do {
            let (vault,pairing,client,cache) = try connection()
            let catalogue = try await CompanionDatabaseResearchCopy.catalogue(client:client,vaultId:vault)
            guard catalogue.revision == catalogueRevision,selected.isSubset(of:Set(catalogue.items.compactMap { $0.objectValue?["id"]?.stringValue })) else { throw DesktopBridgeError.malformedResponse }
            var reports:[JSONValue] = [],records:[PrivateBridgeCache.ReadPackRecord] = [],bytes = 0,images = Set<String>()
            for id in selected.sorted() {
                try Task.checkCancellation()
                let value = try await client.operation(vaultId:vault,method:"getMobileDatabaseResearchReader",args:[.string(id)])
                let source = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Source.self,from:JSONEncoder.nodus.encode(value)); try source.validate(id:id)
                reports.append(value); bytes += try JSONEncoder.nodus.encode(value).count
                guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                if pairing.domains.contains(.writing) {
                    let reading = try await client.databaseResearchReading(vaultId:vault,reportId:id)
                    guard reading.sourceRevision == source.sourceRevision else { throw DesktopBridgeError.malformedResponse }
                    let journal = try await CompanionDatabaseReadingOutboxes.shared.outbox(pairingId:pairing.id,vaultId:vault)
                    try await journal.seed(reading)
                }
                for image in try CompanionCorpusImage.sources(in:source.report) where images.insert(image).inserted {
                    let file = try await CompanionCorpusImage.load(client:client,cache:cache,vaultId:vault,source:image,domains:Array(pairing.domains))
                    let data = try JSONEncoder.nodus.encode(file); bytes += data.count
                    guard bytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                    records.append(.init(domain:.corpus,recordId:CompanionCorpusImage.recordId(source:image),data:data))
                }
                let latest = try await client.operation(vaultId:vault,method:"getMobileDatabaseResearchReader",args:[.string(id)])
                guard latest.objectValue?["sourceRevision"] == .string(source.sourceRevision) else { throw DesktopBridgeError.malformedResponse }
                progress = (progress ?? 0) + 1
            }
            let copy:JSONValue = .object(["version":.int(1),"reports":.array(reports)])
            _ = try CompanionDatabaseResearchCopy(copies:[copy])
            let data = try JSONEncoder.nodus.encode(copy)
            // Replace the provisional body count with the complete serialized pack.
            let imageBytes = records.reduce(0) { $0 + $1.data.count }
            guard data.count + imageBytes <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            records.append(.init(domain:.corpus,recordId:CompanionDatabaseResearchCopy.recordId,data:data))
            let jobs = try await client.operation(vaultId:vault,method:"listDatabaseDeepResearchJobs",args:[])
            let jobData = try JSONEncoder.nodus.encode(jobs)
            guard data.count + imageBytes + jobData.count <= PrivateBridgeCache.defaultReadLimitBytes,jobs.arrayValue != nil else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            records.append(.init(domain:.corpus,recordId:try CompanionDocumentOutbox.operationKey("listDatabaseDeepResearchJobs",[]),data:jobData))
            try Task.checkCancellation()
            let final = try await CompanionDatabaseResearchCopy.catalogue(client:client,vaultId:vault)
            guard final.revision == catalogue.revision else { throw DesktopBridgeError.malformedResponse }
            let packId = try PrivateBridgeCache.readPackSelectionId(vaultId:vault,recordIds:selected.map { "database-report:\($0)" })
            try await cache.saveReadPack(id:packId,vaultId:vault,title:"Informes de datos · \(selected.count)",expiresAt:Date().addingTimeInterval(Double(days)*86_400),records:records)
            session.didChangeCompanionDownloads(); saved = true
        } catch where error.isCancellation { issue = "Descarga cancelada. No se ha creado una copia incompleta." }
        catch { issue = error.localizedDescription }
    }
}
private extension JSONValue { var databaseReportIdentity:String { objectValue?["id"]?.stringValue ?? "" } }
