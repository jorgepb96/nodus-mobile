import NodusKit
import NodusUI
import SwiftUI

/// Binds dates, roles and kinship to the actual named neighbours in the response.
/// Downloaded readers supply their own callback, so navigation remains within
/// explicit selected copies and never opens a socket from this component.
struct GenealogyDossierContextView: View {
    let session: SpaceSession
    let dossier: CollectionDossier
    var onOpenRelated: ((CollectionDescriptor, Row) -> Void)?
    @State private var limits: [String: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            if dossier.sections["evidenceAccess"]?.objectValue?["state"] == .string("requires-primary-source-files") {
                NodusNotice(tone: .caution, title: "Evidence requires permission",
                    message: "Link your workspace again from your Mac to consult genealogy evidence.")
                    .accessibilityIdentifier("genealogy-evidence-permission")
            }
            ForEach(GenealogyDossierContext.bibliographySources(dossier)) { source in
                if let target = source.target, let collection = Collections[source.collectionPath] {
                    destination(target, collection: collection, title: String(localized: "Open bibliography source"))
                        .accessibilityIdentifier("genealogy-evidence-source-\(source.id)")
                }
            }
            ForEach(GenealogyDossierContext.sections(dossier)) { section in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(title(section.id)).font(.headline)
                        Text(section.entries.count.formatted()).font(.caption).foregroundStyle(.secondary)
                    }
                    let limit = limits[section.id] ?? 30
                    ForEach(section.entries.prefix(limit)) { entry in
                        VStack(alignment: .leading, spacing: 10) {
                            if let target = entry.target, let collection = Collections[entry.collectionPath] {
                                destination(target, collection: collection, title: entry.title ?? collection.presenter.title(target))
                                    .accessibilityIdentifier("genealogy-context-neighbour-\(section.id)-\(target.string(collection.idField) ?? "")")
                            }
                            DossierValueView(session: session, value: .object(entry.association.columns), field: "", linkedCollection: nil, onOpenRelated: onOpenRelated)
                            if let path = entry.associationPath, let collection = Collections[path], entry.association.string(collection.idField) != nil {
                                destination(entry.association, collection: collection, title: String(localized: "Open the full record"))
                                    .accessibilityIdentifier("genealogy-context-relationship-\(entry.association.string(collection.idField) ?? "")")
                            }
                        }
                        .padding(12).nodusGlass(NodusGlass(.thin, tint: session.accent))
                    }
                    if limit < section.entries.count {
                        Button("Mostrar más (\(section.entries.count - limit))") { limits[section.id] = limit + 30 }
                            .frame(minHeight: 44).accessibilityIdentifier("genealogy-context-more-\(section.id)")
                    }
                }
                .accessibilityIdentifier("genealogy-context-\(section.id)")
            }
        }
    }
    private func title(_ key: String) -> LocalizedStringKey {
        switch key {
        case "relationships": "Relationships"
        case "placeLinks": "Places"
        case "personLinks": "Persons"
        case "participantRows": "Participants"
        default: "Related records"
        }
    }
    @ViewBuilder private func destination(_ row: Row, collection: CollectionDescriptor, title: String) -> some View {
        if let onOpenRelated {
            Button { onOpenRelated(collection, row) } label: { Label(title, systemImage: collection.icon).frame(minHeight: 44, alignment: .leading) }
        } else {
            NavigationLink { RowDetailView(session: session, collection: collection, row: row) }
                label: { Label(title, systemImage: collection.icon).frame(minHeight: 44, alignment: .leading) }
        }
    }
}
