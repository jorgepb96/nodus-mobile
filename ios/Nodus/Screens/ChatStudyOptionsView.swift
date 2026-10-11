import NodusKit
import NodusUI
import SwiftUI

struct ChatStudyOptionsView: View {
    let session: SpaceSession
    @Binding var options: CompanionStudyChatOptions
    var downloadOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var catalogue: CompanionStudyChatSources.Catalogue?
    @State private var offline = false
    @State private var downloaded = Set<String>()
    @State private var query = ""
    @State private var issue: String?
    @State private var loading = true
    @State private var saving = false
    @State private var saved = false
    @State private var days = 7
    @State private var task: Task<Void,Never>?
    var body: some View {
        NavigationStack {
            Form {
                if !downloadOnly {
                    Section("Respuesta") {
                        Picker("Tarea",selection:$options.task) {
                            Text("Responder").tag("answer");Text("Resumir").tag("summary");Text("Explicar").tag("explain")
                            Text("Comparar").tag("compare");Text("Esquema").tag("outline");Text("Cronología").tag("timeline")
                            Text("Tabla").tag("table");Text("Mapa conceptual").tag("concept-map");Text("Glosario").tag("glossary")
                            Text("Análisis crítico").tag("critique");Text("Preguntas de repaso").tag("review-questions")
                        }
                        Picker("Nivel",selection:$options.level) { Text("Sencillo").tag("simple");Text("Normal").tag("standard");Text("Avanzado").tag("advanced") }
                        Picker("Tono",selection:$options.tone) { Text("Claro").tag("clear");Text("Académico").tag("academic");Text("Conciso").tag("concise");Text("Guiado").tag("guided") }
                        Picker("Idioma",selection:$options.language) { Text("Idioma de la app").tag("auto");Text("Español").tag("es");Text("English").tag("en");Text("Français").tag("fr") }
                        Toggle("Permitir conocimiento externo",isOn:$options.allowExternalKnowledge)
                    } footer: { Text("El conocimiento externo se distingue de las fuentes elegidas. Las citas siempre apuntan a sus fragmentos reales.") }
                }
                Section("Fuentes") {
                    if offline { Text("Nodus no está disponible. El chat utilizará únicamente las fuentes que elegiste descargar.").font(.footnote).foregroundStyle(.secondary) }
                    if !downloadOnly {
                        Picker("Alcance",selection:$options.selection.scope) {
                            Text("Biblioteca").tag("library");Text("Curso").tag("course");Text("Asignatura").tag("subject");Text("Tema").tag("topic");Text("Elegir fuentes").tag("manual")
                        }
                        if let catalogue {
                            if options.selection.scope == "course" { namedPicker("Curso",rows:catalogue.courses,selection:$options.selection.courseId) }
                            if options.selection.scope == "subject" { namedPicker("Asignatura",rows:catalogue.subjects,selection:$options.selection.subjectId) }
                            if options.selection.scope == "topic" { namedPicker("Tema",rows:catalogue.topics,selection:$options.selection.topicId) }
                        }
                    }
                    if loading { ProgressView("Cargando fuentes…") }
                    if let issue { NodusNotice(tone:.blocked,title:"No se han podido cargar las fuentes",message:LocalizedStringKey(issue));Button("Reintentar") { task = Task { await load() } } }
                    if options.selection.scope == "manual" || downloadOnly {
                        TextField("Buscar fuentes",text:$query).textInputAutocapitalization(.never)
                        ForEach((catalogue?.sources ?? []).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.subtitle.localizedCaseInsensitiveContains(query) }) { source in
                            let available = source.chunks > 0 && source.available != false && (!offline || downloaded.contains(source.id))
                            Button {
                                if options.selection.sourceKeys.contains(source.id) { options.selection.sourceKeys.removeAll { $0 == source.id } }
                                else if options.selection.sourceKeys.count < 100 { options.selection.sourceKeys.append(source.id) }
                            } label: {
                                HStack(spacing:12) {
                                    Image(systemName:options.selection.sourceKeys.contains(source.id) ? "checkmark.circle.fill":"circle").foregroundStyle(session.accent)
                                    VStack(alignment:.leading,spacing:4) {
                                        Text(source.title).foregroundStyle(.primary)
                                        if !source.subtitle.isEmpty { Text(source.subtitle).font(.caption).foregroundStyle(.secondary) }
                                        if !available { Text(offline ? "Sin descargar":"Requiere preparación en el Mac").font(.caption).foregroundStyle(.secondary) }
                                    }.multilineTextAlignment(.leading)
                                }.frame(minHeight:44)
                            }.buttonStyle(.plain).disabled(!available || saving)
                        }
                    }
                    if let catalogue,catalogue.sources.isEmpty { Text("Todavía no hay fuentes preparadas en este vault.").foregroundStyle(.secondary) }
                }
                if downloadOnly {
                    Section {
                        Picker("Conservar la descarga",selection:$days) { Text("7 días").tag(7);Text("30 días").tag(30) }
                        if saved { Label("Fuentes disponibles sin conexión",systemImage:"checkmark.circle.fill").foregroundStyle(.green) }
                        if saving { ProgressView("Descargando los fragmentos completos…");Button("Cancelar",role:.cancel) { task?.cancel() } }
                        Button("Descargar \(options.selection.sourceKeys.count) fuentes") { task = Task { await download() } }
                            .disabled(options.selection.sourceKeys.isEmpty || loading || offline || saving || saved)
                    } footer: { Text("Hasta 50 MB para el contexto descargado de estudio. Se incluyen los fragmentos ya preparados por el Mac; la app no extrae ni indexa. Tus respuestas y citas no caducan.") }
                }
            }.navigationTitle(downloadOnly ? "Estudio para llevar":"Opciones del chat de estudio").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Listo") { dismiss() }.disabled(saving) } }
                .task { if downloadOnly { options.selection.scope = "manual" };await load() }.onDisappear { task?.cancel() }
        }.tint(session.accent)
    }
    private func namedPicker(_ title: String,rows: [CompanionStudyChatSources.Catalogue.Named],selection: Binding<String?>) -> some View {
        Picker(title,selection:selection) {
            Text("Elegir…").tag(nil as String?)
            ForEach(rows) { row in Text(row.name).tag(Optional(row.id)) }
        }
    }
    private func load() async {
        loading = true;defer { loading = false }
        do { let result = try await CompanionStudyChatSources.catalogue(session:session);catalogue = result.0;offline = result.1;downloaded = result.2;issue = nil }
        catch where error.isCancellation {} catch { issue = error.localizedDescription }
    }
    private func download() async {
        saving = true;issue = nil;defer { saving = false }
        do { try await CompanionStudyChatSources.download(session:session,keys:options.selection.sourceKeys,days:days);saved = true }
        catch where error.isCancellation { issue = "Descarga cancelada. No se ha guardado una copia incompleta." }
        catch { issue = error.localizedDescription }
    }
}

struct StudyChatEvidenceView: View {
    let citation: JSONValue
    let session: SpaceSession
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    Text(citation.objectValue?["title"]?.stringValue ?? "Fuente").font(.title3.bold())
                    Text(citation.objectValue?["subtitle"]?.stringValue ?? "").font(.caption).foregroundStyle(.secondary)
                    if let location = citation.objectValue?["location"]?.objectValue {
                        if let page = location["pageNumber"]?.intValue { Text("Página \(page)").font(.caption) }
                        if let slide = location["slideNumber"]?.intValue { Text("Diapositiva \(slide)").font(.caption) }
                        if let seconds = location["timestampSeconds"]?.doubleValue { Text("\(Int(seconds)) s").font(.caption) }
                    }
                    Text(citation.objectValue?["quote"]?.stringValue ?? "").textSelection(.enabled)
                    if let reference { NavigationLink("Abrir la fuente") { CorpusReferenceView(session:session,reference:reference) } }
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }.navigationTitle(citation.objectValue?["id"]?.stringValue ?? "Evidencia").navigationBarTitleDisplayMode(.inline)
                .nodusModalClose(accent:session.accent)
        }.tint(session.accent)
    }
    private var reference: CorpusReference? {
        guard let raw = citation.objectValue,let kind = raw["kind"]?.stringValue,let id = raw["sourceId"]?.stringValue else { return nil }
        let location = raw["location"]?.objectValue ?? [:]
        let route: String,owner: String
        switch kind {
        case "document": route = "doc";owner = location["documentId"]?.stringValue ?? id
        case "material": route = "material";owner = location["materialId"]?.stringValue ?? id
        case "transcript": route = "recording";owner = location["recordingId"]?.stringValue ?? id
        default: return nil
        }
        guard let encoded = owner.addingPercentEncoding(withAllowedCharacters:.urlPathAllowed.subtracting(CharacterSet(charactersIn:"/"))) else { return nil }
        var components = URLComponents(string:"nodus://study/\(route)/\(encoded)")!
        components.queryItems = ["pageNumber":"page","slideNumber":"slide","timestampSeconds":"t","transcriptId":"transcript","from":"from"].compactMap { key,name in
            let value = location[key];let text = value?.stringValue ?? value?.intValue.map { String($0) } ?? value?.doubleValue.map { String($0) }
            return text.map { URLQueryItem(name:name,value:$0) }
        }
        return components.url.flatMap(CorpusReference.init)
    }
}
