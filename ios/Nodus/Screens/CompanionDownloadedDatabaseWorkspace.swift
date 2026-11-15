import NodusKit
import NodusUI
import SwiftUI

/// The same native workspace reads a selected complete dossier. Its saved views
/// resolve only from that device's chosen packs; content edits keep their ledger.
struct CompanionDownloadedDatabaseWorkspace:View {
    let session:SpaceSession
    let dossier:CollectionDossier
    @State private var tables:[String:[Row]] = [:]
    @State private var database:PagesDatabasesParity.Database?
    @State private var outbox:OutboxController?
    @State private var issue:String?
    var body:some View {
        Group {
            if let database {DatabaseDetailWorkspace(session:session,database:database,tables:$tables,outbox:outbox,downloadedOnly:true)}
            else if let issue {NodusNotice(tone:.caution,title:"Descarga de base de datos no disponible",message:LocalizedStringKey(issue)).padding(NodusSpace.page)}
            else {ProgressView("Leyendo la base de datos descargada…")}
        }.task(id:dossier.primary.string(dossier.collection.idField)){await load()}
    }
    private func load() async {
        do {
            guard let object=dossier.payload.objectValue else {throw DesktopBridgeError.malformedResponse}
            var source:[String:[Row]]=["db_databases":[dossier.primary]]
            for (key,table) in ["columns":"db_columns","rows":"db_rows","cells":"db_cells","views":"db_views","options":"db_select_options","relations":"db_relations","attachments":"db_attachments"] {
                guard let values=object[key]?.arrayValue else {throw DesktopBridgeError.malformedResponse}
                source[table]=try values.map{value in guard let row=value.objectValue else {throw DesktopBridgeError.malformedResponse};return Row(row)}
            }
            source = try await CompanionDatabaseDownloadedMetadata.merge(session: session, into: source)
            let queue=try await MutationOutbox.open(spaceId:session.connection.storageId,directory:URL.applicationSupportDirectory.appendingPathComponent("spaces",isDirectory:true))
            source=try await queue.companionContentProjection(source)
            guard let identity=dossier.primary.string(dossier.collection.idField),let parent=PagesDatabasesParity.databases(in:source).first(where:{$0.id == identity}) else {throw DesktopBridgeError.malformedResponse}
            try Task.checkCancellation();tables=source;database=parent;outbox=await OutboxController.open(session:session)
        }catch where error.isCancellation {}
        catch{issue=error.localizedDescription}
    }
}
