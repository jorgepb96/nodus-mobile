import NodusKit
import NodusUI
import SwiftUI

/// Nested evidence, versions and manuscript sections open in the normal native
/// navigation stack. Long lists grow on demand and retain every item.
struct CollectionDossierBody: View {
    let session: SpaceSession
    let dossier: CollectionDossier
    var onOpenRelated: ((CollectionDescriptor, Row) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            if dossier.fromDevice {
                Label("Sin conexión · contenido de este dispositivo", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DossierValueView(session: session, value: .object(dossier.primary.columns), field: "", linkedCollection: nil, onOpenRelated: onOpenRelated)
            ForEach(dossier.sections.keys.sorted(), id: \.self) { key in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(Self.label(key)).font(.headline)
                        if let count = dossier.sections[key]?.arrayValue?.count { Text(count.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }
                    DossierValueView(session: session, value: dossier.sections[key]!, field: key, linkedCollection: dossier.linkedCollection(for: key), onOpenRelated: onOpenRelated)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    static func label(_ key: String) -> String {
        let labels = ["versions": "Versiones", "textVersions": "Versiones del texto", "evidence": "Evidencias",
            "relations": "Relaciones", "links": "Enlaces", "annotations": "Anotaciones", "segments": "Fragmentos",
            "transcripts": "Transcripciones", "codes": "Códigos", "annotationCodes": "Codificación",
            "items": "Fuentes", "excerpts": "Extractos", "units": "Unidades descriptivas", "repository": "Repositorio",
            "profile": "Perfil", "analysis": "Análisis", "personMentions": "Personas mencionadas", "placeMentions": "Lugares mencionados",
            "itemUnits": "Ubicación de las fuentes", "members": "Miembros", "children": "Elementos dependientes",
            "affiliations": "Afiliaciones", "seat": "Sede", "text": "Manuscrito", "beats": "Hitos narrativos",
            "cast": "Personajes", "snapshots": "Historial", "images": "Imágenes", "rules": "Reglas",
            "options": "Opciones", "blocks": "Bloques", "comments": "Comentarios", "placements": "Ubicaciones",
            "calendar": "Calendario", "subjects": "Asignaturas", "plans": "Planes", "publication": "Publicación",
            "edges": "Relaciones", "occurrences": "Procedencia"]
        return labels[key] ?? FieldNames.label(for: key)
    }
}

private struct DossierValueView: View {
    let session: SpaceSession
    let value: JSONValue
    let field: String
    let linkedCollection: CollectionDescriptor?
    var onOpenRelated: ((CollectionDescriptor, Row) -> Void)?
    @State private var visibleCount = 30

    var body: some View { content }

    private var content: AnyView {
        switch value {
        case .null: return AnyView(EmptyView())
        case .array(let items):
            return AnyView(LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.prefix(visibleCount).enumerated()), id: \.offset) { index, item in
                    if let object = item.objectValue {
                        DisclosureGroup {
                            child(item, field: "", linked: nil)
                        } label: { objectLabel(object, ordinal: index + 1) }
                        .padding(12).nodusGlass(NodusGlass(.thin, tint: session.accent))
                        if let linkedCollection, object[linkedCollection.idField]?.stringValue != nil {
                            link(Row(object), to: linkedCollection)
                        }
                    } else { child(item, field: field, linked: nil) }
                }
                if visibleCount < items.count {
                    Button("Mostrar más (\(items.count - min(visibleCount, items.count)))") { visibleCount += 30 }
                        .frame(minHeight: 44).accessibilityIdentifier("dossier-show-more-\(field)")
                }
                if items.isEmpty { Text("Sin contenido en esta sección").font(.caption).foregroundStyle(.secondary) }
            })
        case .object(let object):
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                if let linkedCollection, object[linkedCollection.idField]?.stringValue != nil { link(Row(object), to: linkedCollection) }
                ForEach(object.keys.filter { !Self.technical($0) }.sorted(), id: \.self) { key in
                    if object[key] != .null, !(object[key]?.stringValue?.isEmpty ?? false) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(CollectionDossierBody.label(key)).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            child(object[key]!, field: key, linked: nil)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            })
        case .string(let text):
            if field.hasSuffix("_json"), let data = text.data(using: .utf8),
               let parsed = try? JSONDecoder.nodus.decode(JSONValue.self, from: data),
               parsed.arrayValue != nil || parsed.objectValue != nil {
                return child(parsed, field: String(field.dropLast(5)), linked: nil)
            }
            if ["content_markdown", "contentMarkdown", "markdown", "body_markdown", "definition_markdown", "normalized_text", "quote", "text", "body", "answer", "explanation"].contains(field) {
                return AnyView(CorpusProse(text, accent: session.accent, session: session))
            }
            return AnyView(Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true))
        default:
            return AnyView(Text(value.stringValue ?? "—").font(.callout).textSelection(.enabled))
        }
    }

    private func child(_ value: JSONValue, field: String, linked: CollectionDescriptor?) -> AnyView {
        AnyView(DossierValueView(session: session, value: value, field: field, linkedCollection: linked, onOpenRelated: onOpenRelated))
    }
    private static func technical(_ key: String) -> Bool {
        key == "id" || key.hasSuffix("_id") || key.hasSuffix("_hash") ||
            ["global_id", "from_id", "to_id", "created_by", "local_path", "file_path", "sort_order"].contains(key)
    }
    private func objectLabel(_ object: [String: JSONValue], ordinal: Int) -> some View {
        let title = ["title", "name", "label", "prompt", "heading", "created_at", "generated_at", "version_no"].compactMap { object[$0]?.stringValue }.first { !$0.isEmpty }
        return Text(title ?? "\(CollectionDossierBody.label(field)) · \(ordinal)").font(.subheadline.weight(.medium)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func link(_ row: Row, to collection: CollectionDescriptor) -> some View {
        if let onOpenRelated {
            Button { onOpenRelated(collection, row) } label: { Label("Abrir dossier", systemImage: "arrow.up.right.square").frame(minHeight: 44) }
        } else {
            NavigationLink { RowDetailView(session: session, collection: collection, row: row) }
                label: { Label("Abrir dossier", systemImage: "arrow.up.right.square").frame(minHeight: 44) }
        }
    }
}
