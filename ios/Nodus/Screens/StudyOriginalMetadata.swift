import NodusKit
import NodusUI
import SwiftUI

struct StudyOriginalSection: View {
    let session: SpaceSession
    let title: String
    let value: JSONValue
    let field: String
    var body: some View {
        DisclosureGroup {
            DossierValueView(session: session, value: value, field: field, linkedCollection: nil)
        } label: {
            HStack { Text(title).font(.headline); if let count = value.arrayValue?.count { Text(count.formatted()).font(.caption).foregroundStyle(.secondary) } }
        }.padding(16).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

/// The original DTO is retained. Known fields receive native reading controls;
/// additional domain fields remain available rather than being dropped by a UI projection.
struct StudyOriginalMetadata: View {
    let session: SpaceSession
    let value: JSONValue
    let excluding: Set<String>
    var body: some View {
        if let raw = value.objectValue {
            FlowLayout(spacing: 8) {
                ForEach(["type", "difficulty", "cognitiveLevel", "status"], id: \.self) { key in
                    if let text = raw[key]?.stringValue, !text.isEmpty { NodusChip(Self.label(text), tint: session.accent, capitalises: false) }
                }
                ForEach(Array((raw["tags"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, value in
                    if let tag = value.stringValue { NodusChip(tag, tint: .secondary, capitalises: false) }
                }
            }
            let rest = raw.filter { !excluding.contains($0.key) && !["type", "difficulty", "cognitiveLevel", "status", "tags"].contains($0.key) && $0.value != .null }
            if !rest.isEmpty { StudyOriginalSection(session: session, title: "Información de la fuente", value: .object(rest), field: "metadata") }
        }
    }
    static func label(_ token: String) -> String {
        ["single_choice": "Elección única", "multiple_choice": "Elección múltiple", "true_false": "Verdadero o falso", "short": "Respuesta corta", "essay": "Desarrollo", "definition": "Definición", "relation": "Relación", "comparison": "Comparación", "commentary": "Comentario", "case": "Caso práctico", "fill_blank": "Completar", "matching": "Emparejar", "ordering": "Ordenar", "pending": "Pendiente", "approved": "Aprobada", "problematic": "Con incidencias", "discarded": "Descartada", "draft": "Borrador", "active": "Activo", "ready": "Preparado", "easy": "Fácil", "medium": "Media", "hard": "Difícil", "remember": "Recordar", "understand": "Comprender", "apply": "Aplicar", "analyze": "Analizar", "synthesize": "Sintetizar"][token] ?? token
    }
}

struct StudyOriginalProvenance: View {
    let session: SpaceSession
    let question: [String: JSONValue]
    let source: [String: JSONValue]
    private var reference: CorpusReference? {
        let key = source["sourceKey"]?.stringValue?.split(separator: ":", maxSplits: 1).map(String.init) ?? []
        let location = source["location"]?.objectValue ?? [:]
        let id: String?, kind: String
        if key.first == "document" {
            id = location["documentId"]?.stringValue ?? question["documentId"]?.stringValue ?? (key.count == 2 ? key[1] : nil); kind = "doc"
        } else if key.first == "material" {
            id = location["materialId"]?.stringValue ?? question["materialId"]?.stringValue ?? (key.count == 2 ? key[1] : nil); kind = "material"
        } else if key.first == "transcript" {
            // A transcript ID is never guessed to be its recording ID.
            id = location["recordingId"]?.stringValue ?? question["recordingId"]?.stringValue; kind = "recording"
        } else { return nil }
        guard let id, !id.isEmpty else { return nil }
        var url = URLComponents(); url.scheme = "nodus"; url.host = "study"; url.path = "/\(kind)/\(id)"
        let names = ["pageNumber": "page", "slideNumber": "slide", "from": "from", "timestampSeconds": "t", "transcriptId": "transcript"]
        url.queryItems = names.compactMap { name, query in location[name]?.stringValue.map { URLQueryItem(name: query, value: $0) } }
        if kind == "recording", location["transcriptId"] == nil, key.count == 2 { url.queryItems?.append(URLQueryItem(name: "transcript", value: key[1])) }
        return url.url.flatMap(CorpusReference.init)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Procedencia").font(.headline)
            if let title = source["title"]?.stringValue, !title.isEmpty { Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true) }
            if let excerpt = source["excerpt"]?.stringValue, !excerpt.isEmpty { CorpusProse(excerpt, accent: session.accent, session: session) }
            if let location = source["location"], location.objectValue?.isEmpty == false { DossierValueView(session: session, value: location, field: "location", linkedCollection: nil) }
            if let reference { NavigationLink { CorpusReferenceView(session: session, reference: reference) } label: { Label("Abrir fuente original", systemImage: "arrow.up.right.square").frame(minHeight: 44) } }
        }
    }
}
