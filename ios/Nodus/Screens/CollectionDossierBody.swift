import NodusKit
import NodusUI
import SwiftUI

/// Nested evidence, versions and manuscript sections open in the normal native
/// navigation stack. Long lists grow on demand and retain every item.
struct CollectionDossierBody: View {
    let session: SpaceSession
    let dossier: CollectionDossier
    var displayPrimary = true
    var showConnectionState = true
    var onOpenRelated: ((CollectionDescriptor, Row) -> Void)?
    var downloadedOnly = false
    @Environment(\.downloadedReaderOnly) private var inheritedDownloadedOnly
    private var selectedReaderOnly: Bool { downloadedOnly || inheritedDownloadedOnly }
    @State private var selectedPrivateSource: PrivateCorpusReference?

    private var citationHandler: ((URL) -> Bool)? {
        guard selectedReaderOnly else { return nil }
        return openSelectedCitation
    }

    private var sectionKeys: [String] {
        let contextual: Set<String> = session.vaultType == .genealogy
            ? Set(GenealogyDossierContext.sections(dossier).map(\.id)).union(["evidenceAccess"]) : []
        return dossier.sections.keys.filter { !contextual.contains($0) }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NodusSpace.block) {
            if showConnectionState, dossier.fromDevice {
                Label("Sin conexión · contenido de este dispositivo", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if displayPrimary {
                DossierValueView(session: session, value: .object(dossier.primary.columns), field: "", linkedCollection: nil, onOpenRelated: onOpenRelated, onCitation: citationHandler)
            }
            if session.vaultType == .genealogy {
                GenealogyDossierContextView(session: session, dossier: dossier, onOpenRelated: onOpenRelated, downloadedOnly: selectedReaderOnly)
            }
            ForEach(sectionKeys, id: \.self) { key in sectionView(key) }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.downloadedReaderOnly, selectedReaderOnly)
        .nodusSheet(isPresented: Binding(get: { selectedPrivateSource != nil }, set: { if !$0 { selectedPrivateSource = nil } })) {
            if let selectedPrivateSource { PrivateCorpusSourceSheet(session: session, reference: selectedPrivateSource, downloadedOnly: true) }
        }
    }

    private func sectionView(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Self.label(key)).font(.headline)
                if let count = dossier.sections[key]?.arrayValue?.count { Text(count.formatted()).font(.caption).foregroundStyle(.secondary) }
            }
            if key == "documentProfile" {
                Text("Guía de orientación del documento. Las citas se consultan en sus evidencias y pasajes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            DossierValueView(session: session, value: dossier.sections[key]!, field: key, linkedCollection: dossier.linkedCollection(for: key), onOpenRelated: onOpenRelated, onCitation: citationHandler)
        }
    }

    private func openSelectedCitation(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "nodus" else { return false }
        if let reference = PrivateCorpusReference(url) { selectedPrivateSource = reference; return true }
        if let reference = CorpusReference(url), let collection = reference.collection, let onOpenRelated {
            onOpenRelated(collection, Row([collection.idField: .string(reference.recordId)])); return true
        }
        // With no catalogue callback, the native reader inherits selected-only
        // scope and can resolve another explicit copy or its real missing-copy error.
        return false
    }

    static func label(_ key: String) -> String {
        let labels = ["versions": "Versiones", "textVersions": "Versiones del texto", "evidence": "Evidencias", "documentProfile": "Perfil documental",
            "relations": "Relaciones", "links": "Enlaces", "annotations": "Anotaciones", "segments": "Fragmentos",
            "transcripts": "Transcripciones", "codes": "Códigos", "annotationCodes": "Codificación",
            "items": "Fuentes", "excerpts": "Extractos", "units": "Unidades descriptivas", "repository": "Repositorio",
            "profile": "Perfil", "analysis": "Análisis", "personMentions": "Personas mencionadas", "placeMentions": "Lugares mencionados",
            "attempts": "Intentos", "rubric": "Rúbrica", "criteria": "Criterios", "weight": "Peso", "response": "Respuesta", "feedback": "Evaluación", "answers": "Respuestas", "score": "Puntuación", "maxScore": "Puntuación máxima", "isCorrect": "Correcta", "pointsAwarded": "Puntos obtenidos", "responseMs": "Tiempo de respuesta (ms)", "startedAt": "Inicio", "submittedAt": "Entrega", "durationSeconds": "Duración (segundos)", "config": "Configuración", "snapshot": "Contenido de la versión", "reason": "Motivo", "versionNo": "Versión", "generationPrompt": "Instrucciones de generación", "model": "Modelo", "usageCount": "Veces utilizada", "correctCount": "Aciertos", "incorrectCount": "Errores", "omittedCount": "Sin responder", "lastResponse": "Última respuesta", "lastScore": "Última puntuación", "lastMaxScore": "Puntuación máxima de la última respuesta", "lastFeedback": "Última evaluación", "lastAnsweredAt": "Última respuesta registrada", "createdAt": "Creación", "updatedAt": "Actualización", "pageNumber": "Página", "slideNumber": "Diapositiva", "timestampSeconds": "Instante (segundos)", "favorite": "Favorito", "locked": "Protegido", "attemptCount": "Intentos registrados", "availableAt": "Disponible desde", "expected": "Respuesta esperada", "gradable": "Evaluable", "omitted": "Sin responder", "correct": "Correcta", "maxPoints": "Puntos máximos", "confidence": "Confianza", "flagged": "Marcada para revisión",
            "itemUnits": "Ubicación de las fuentes", "members": "Miembros", "children": "Elementos dependientes",
            "affiliations": "Afiliaciones", "seat": "Sede", "text": "Manuscrito", "beats": "Hitos narrativos",
            "cast": "Personajes", "snapshots": "Historial", "images": "Imágenes", "rules": "Reglas",
            "options": "Opciones", "blocks": "Bloques", "comments": "Comentarios", "placements": "Ubicaciones",
            "calendar": "Calendario", "subjects": "Asignaturas", "plans": "Planes", "publication": "Publicación",
            "edges": "Relaciones", "occurrences": "Procedencia", "abilities": "Habilidades", "scenes": "Apariciones en escenas",
            "secrets": "Secretos", "relatedPersons": "Personas relacionadas", "placeLinks": "Vínculos con lugares"]
        return labels[key] ?? FieldNames.label(for: key)
    }
}

struct DossierValueView: View {
    let session: SpaceSession
    let value: JSONValue
    let field: String
    let linkedCollection: CollectionDescriptor?
    var onOpenRelated: ((CollectionDescriptor, Row) -> Void)?
    var onCitation: ((URL) -> Bool)? = nil
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
                return AnyView(CorpusProse(text, accent: session.accent, session: session, onCitation: onCitation))
            }
            return AnyView(Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true))
        case .bool(let value):
            return AnyView(Text(value ? "Sí" : "No").font(.callout))
        default:
            return AnyView(Text(value.stringValue ?? "—").font(.callout).textSelection(.enabled))
        }
    }

    private func child(_ value: JSONValue, field: String, linked: CollectionDescriptor?) -> AnyView {
        AnyView(DossierValueView(session: session, value: value, field: field, linkedCollection: linked, onOpenRelated: onOpenRelated, onCitation: onCitation))
    }
    private static func technical(_ key: String) -> Bool {
        key == "id" || key.hasSuffix("_id") || key.hasSuffix("Id") || key.hasSuffix("_hash") ||
            ["global_id", "from_id", "to_id", "created_by", "local_path", "file_path", "sort_order"].contains(key)
    }
    private func objectLabel(_ object: [String: JSONValue], ordinal: Int) -> some View {
        let title = ["title", "name", "label", "prompt", "heading", "startedAt", "createdAt", "created_at", "generated_at", "versionNo", "version_no"].compactMap { object[$0]?.stringValue }.first { !$0.isEmpty }
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
