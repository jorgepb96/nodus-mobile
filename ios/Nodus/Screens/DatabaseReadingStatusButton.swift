import NodusKit
import NodusUI
import SwiftUI

struct DatabaseReadingStatusButton:View {
    let session:SpaceSession
    @State private var records:[String:CompanionDatabaseReadingOutbox.Entry] = [:]
    @State private var showing = false
    @State private var issue:String?
    @State private var exported:URL?
    var body:some View {
        Group {
            if !records.isEmpty || issue != nil {
                let pending = records.values.filter { $0.state != .saved }.count
                Button { showing = true } label: {
                    Label(issue != nil ? "No se pudo leer el estado de las anotaciones":pending == 0 ? "Anotaciones sincronizadas con Nodus":"Anotaciones guardadas en el móvil · \(pending) por sincronizar",systemImage:issue != nil ? "exclamationmark.circle":pending == 0 ? "checkmark.circle":"arrow.triangle.2.circlepath")
                        .font(.caption).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading).frame(minHeight:44)
                }.padding(.horizontal,12).background(.thinMaterial).accessibilityIdentifier("database-reading-sync-status")
            }
        }.task(id:session.companionDatabaseReadingRevision) { await refresh() }
            .sheet(isPresented:$showing) {
                NavigationStack {
                    List {
                        if let issue { Text(issue).foregroundStyle(Color.nodusDanger) }
                        ForEach(records.keys.sorted(),id:\.self) { id in
                            if let entry = records[id] {
                                Section(entry.reportTitle) {
                                    Text(label(entry.state)).foregroundStyle(.secondary)
                                    Text("En el móvil: \(entry.draft.annotations.count) anotaciones · \(entry.draft.readAt == nil ? "sin leer":"leído")")
                                    if let detail = entry.issue { Text(detail).foregroundStyle(Color.nodusDanger).fixedSize(horizontal:false,vertical:true) }
                                    if let remote = entry.remote {
                                        Text("En Nodus: \(remote.reading.annotations.count) anotaciones · \(remote.reading.readAt == nil ? "sin leer":"leído")")
                                        if entry.sourceRevision != remote.sourceRevision { Text("El contenido del informe ha cambiado. Las anotaciones anteriores pueden apuntar a otros fragmentos.").font(.caption) }
                                        DisclosureGroup("Revisar las anotaciones del móvil") { annotations(entry.draft.annotations) }
                                        DisclosureGroup("Revisar las anotaciones de Nodus") { annotations(remote.reading.annotations) }
                                        if entry.sourceRevision == remote.sourceRevision {
                                            Button("Conservar mis cambios del móvil") { Task { await resolve(id,useMac:false) } }.frame(minHeight:44)
                                        }
                                        Button("Usar las anotaciones de Nodus",role:.destructive) { Task { await resolve(id,useMac:true) } }.frame(minHeight:44)
                                    }
                                    if entry.state != .saved {
                                        Button("Exportar mis anotaciones") { export(entry,id:id) }.frame(minHeight:44)
                                        Button("Conectar y comprobar") { Task { await review(id) } }.frame(minHeight:44)
                                    }
                                }
                            }
                        }
                    }.navigationTitle("Anotaciones de informes").navigationBarTitleDisplayMode(.inline).nodusModalClose(accent:session.accent)
                        .task(id:session.companionDatabaseReadingRevision) { await refresh() }
                }.nodusTextHierarchy().sheet(item:$exported) { ActivityShareSheet(items:[$0]) }
            }
    }
    private func label(_ state:CompanionDatabaseReadingOutbox.State)->String {
        switch state { case .saved:"Sincronizado con Nodus";case .pending:"Guardado en el móvil · pendiente de sincronizar";case .conflict:"Hay cambios en ambos dispositivos";case .blocked:"Tus cambios se conservan · revisar sincronización" }
    }
    private func annotations(_ values:[JSONValue])->some View {
        ForEach(Array(values.enumerated()),id:\.offset) { _,value in
            VStack(alignment:.leading,spacing:4) {
                Text(value.objectValue?["selectedText"]?.stringValue ?? "").font(.body)
                if let text = value.objectValue?["comment"]?.stringValue { Text(text).foregroundStyle(.secondary) }
            }.padding(.vertical,4).fixedSize(horizontal:false,vertical:true)
        }
    }
    private func journal() async throws -> CompanionDatabaseReadingOutbox {
        let (vault,pairing,_) = try privateBridgeConnection(session,domain:.writing)
        return try await CompanionDatabaseReadingOutboxes.shared.outbox(pairingId:pairing.id,vaultId:vault)
    }
    private func refresh() async {
        do { let store = try await journal(); records = await store.all(); issue = nil }
        catch where error.isCancellation {} catch { records = [:]; issue = error.localizedDescription }
    }
    private func resolve(_ id:String,useMac:Bool) async {
        do { let store = try await journal(); try await store.resolve(id:id,useMac:useMac); session.didChangeDatabaseReading(); await session.synchronizeCompanionChanges(); await refresh() }
        catch { issue = error.localizedDescription }
    }
    private func review(_ id:String) async {
        do {
            let (vault,pairing,token) = try privateBridgeConnection(session,domain:.writing)
            let remote = try await DesktopBridgeClient(pairing:pairing,token:token).databaseResearchReading(vaultId:vault,reportId:id)
            let store = try await journal(); try await store.review(remote); session.didChangeDatabaseReading(); await refresh()
        } catch { issue = error.localizedDescription }
    }
    private func export(_ entry:CompanionDatabaseReadingOutbox.Entry,id:String) {
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Nodus-Anotaciones-\(UUID().uuidString).json")
            try JSONEncoder.nodus.encode(entry).write(to:url,options:[.atomic,.completeFileProtection]); exported = url
        } catch { issue = error.localizedDescription }
    }
}
