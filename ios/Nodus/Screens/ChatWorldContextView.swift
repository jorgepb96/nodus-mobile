import NodusKit
import NodusUI
import SwiftUI

struct ChatWorldOptionsView: View {
    let session: SpaceSession
    @Binding var options: CompanionWorldChatOptions
    var downloadOnly = false
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [CompanionWorldChatSources.Entry] = []
    @State private var offline = false
    @State private var loading = true
    @State private var query = ""
    @State private var issue: String?
    @State private var days = 7
    @State private var saving = false
    @State private var saved = false
    @State private var task: Task<Void,Never>?
    var body: some View {
        NavigationStack {
            List {
                if !downloadOnly {
                    Section {
                        Picker("Foco de la pregunta",selection:$options.selection.scope) { Text("Detectar por nombres").tag("auto");Text("Elegir elementos").tag("manual") }
                        if options.selection.scope == "auto" { Toggle("Mantener el último foco",isOn:$options.selection.keepFocus) }
                        if !options.focus.isEmpty { Text(options.focus.map(\.title).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
                    } footer: { Text("Las reglas, posiciones, pertenencias y secretos se calculan para el momento de la pregunta, igual que en Nodus.") }
                }
                if offline { Text("Solo están disponibles los elementos que elegiste descargar. Los cálculos siguen utilizando el contexto temporal de esa captura.").font(.footnote).foregroundStyle(.secondary) }
                if loading { ProgressView("Cargando elementos…") }
                if let issue { NodusNotice(tone:.blocked,title:"No se ha podido cargar el mundo",message:LocalizedStringKey(issue));Button("Reintentar") { task = Task { await load() } } }
                if options.selection.scope == "manual" || downloadOnly {
                    Section {
                        ForEach(entries.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { entry in
                            Button {
                                if options.selection.entryKeys.contains(entry.key) { options.selection.entryKeys.removeAll { $0 == entry.key } }
                                else if options.selection.entryKeys.count < (downloadOnly ? 100:6) { options.selection.entryKeys.append(entry.key) }
                            } label: {
                                HStack(spacing:12) {
                                    Image(systemName:options.selection.entryKeys.contains(entry.key) ? "checkmark.circle.fill":"circle").foregroundStyle(session.accent)
                                    Text(entry.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                }.frame(minHeight:44)
                            }.buttonStyle(.plain).disabled(saving || saved)
                        }
                    } header: { Text("Elementos del mundo") } footer: { Text(downloadOnly ? "Descarga juntos los personajes, lugares o escenas que quieras comparar sin conexión.":"Hasta seis elementos por pregunta, como en Nodus. Las referencias a sus reglas y conexiones se incluyen en el contexto.") }
                }
                if entries.isEmpty,!loading,issue == nil { Text("Todavía no hay elementos en este mundo.").foregroundStyle(.secondary) }
                if downloadOnly {
                    Section {
                        Picker("Conservar la descarga",selection:$days) { Text("7 días").tag(7);Text("30 días").tag(30) }
                        if saving { ProgressView("Descargando fichas y contexto…");Button("Cancelar",role:.cancel) { task?.cancel() } }
                        if saved { Label("Mundo disponible sin conexión",systemImage:"checkmark.circle.fill").foregroundStyle(.green) }
                        Button("Descargar \(options.selection.entryKeys.count) elementos") { task = Task { await download() } }.disabled(loading || saving || saved || offline || options.selection.entryKeys.isEmpty)
                    } footer: { Text("Hasta 50 MB de contexto temporal. Se conservan las fichas elegidas y las relaciones que necesitan los cálculos; tus conversaciones no caducan.") }
                }
            }.navigationTitle(downloadOnly ? "Mundo para llevar":"Contexto del mundo").navigationBarTitleDisplayMode(.inline)
                .searchable(text:$query,prompt:"Buscar elementos")
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Listo") { dismiss() }.disabled(saving) } }
                .task { if downloadOnly { options.selection.scope = "manual" };await load() }.onDisappear { task?.cancel() }
        }.tint(session.accent)
    }
    private func load() async {
        loading = true;defer { loading = false }
        do { let catalogue = try await CompanionWorldChatSources.catalogue(session:session);entries = catalogue.0;offline = catalogue.1;issue = nil }
        catch where error.isCancellation {} catch { issue = error.localizedDescription }
    }
    private func download() async {
        saving = true;issue = nil;defer { saving = false }
        do { try await CompanionWorldChatSources.download(session:session,keys:options.selection.entryKeys,days:days);saved = true }
        catch where error.isCancellation { issue = "Descarga cancelada. No se ha guardado una captura incompleta." }
        catch { issue = error.localizedDescription }
    }
}

struct WorldChatFactsView: View {
    let facts: JSONValue
    let session: SpaceSession
    private var computed: [String:JSONValue] { facts.objectValue?["computed"]?.objectValue ?? [:] }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Estos datos los calcula Nodus antes de responder. El modelo redacta a partir de ellos.").font(.footnote).foregroundStyle(.secondary)
                    if let day = facts.objectValue?["worldDay"]?.doubleValue { Text("Día \(Int(day))") }
                }
                factsSection("Reglas y excepciones",key:"effectiveRules",title:"rule",detail:"scope",extra:"overriddenBy")
                factsSection("Presencia",key:"presenceAt",title:"personName",detail:"placeName")
                factsSection("Pertenencias",key:"memberships",title:"personName",detail:"groupName")
                factsSection("Secretos y conocimiento",key:"knowersAt",title:"secretTitle",detail:nil,extra:"people")
                factsSection("Avances de la escena",key:"beatsAtScene",title:"sceneTitle",detail:"threadTitle",extra:nil,text:"text")
                factsSection("Continuidad",key:"findings",title:"headline",detail:"severity",extra:"subjects")
                Section("Fragmentos de las fichas") {
                    ForEach(facts.objectValue?["prose"]?.arrayValue ?? [],id:\.self) { source in
                        VStack(alignment:.leading,spacing:8) {
                            Text(source.objectValue?["ref"]?.objectValue?["title"]?.stringValue ?? "Fuente").font(.headline)
                            Text(source.objectValue?["field"]?.stringValue ?? "").font(.caption).foregroundStyle(.secondary)
                            CorpusProse(source.objectValue?["text"]?.stringValue ?? "",accent:session.accent,session:session)
                        }.padding(.vertical,4)
                    }
                }
            }.navigationTitle("Hechos del mundo").navigationBarTitleDisplayMode(.inline).nodusModalClose(accent:session.accent)
        }.tint(session.accent)
    }
    @ViewBuilder private func factsSection(_ heading: String,key: String,title: String,detail: String?,extra: String? = nil,text: String? = nil) -> some View {
        if let rows = computed[key]?.arrayValue,!rows.isEmpty {
            Section(heading) {
                ForEach(rows,id:\.self) { row in
                    VStack(alignment:.leading,spacing:6) {
                        Text(row.objectValue?[title]?.stringValue ?? "").font(.headline)
                        if let detail { Text(row.objectValue?[detail]?.stringValue ?? "").font(.subheadline) }
                        if let extra { Text((row.objectValue?[extra]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
                        if let text { Text(row.objectValue?[text]?.stringValue ?? "").textSelection(.enabled) }
                        if let mark = row.objectValue?["mark"]?.stringValue { Text(mark).font(.caption).foregroundStyle(.secondary) }
                        if let from = row.objectValue?["fromWorldDay"]?.doubleValue { Text("Desde el día \(Int(from))").font(.caption).foregroundStyle(.secondary) }
                        if let to = row.objectValue?["toWorldDay"]?.doubleValue { Text("Hasta el día \(Int(to))").font(.caption).foregroundStyle(.secondary) }
                    }.padding(.vertical,4)
                }
            }
        }
    }
}

struct WorldChatSourceView: View {
    let key: String
    let session: SpaceSession
    @State private var source: JSONValue?
    @State private var issue: String?
    @State private var loading = true
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if loading { ProgressView("Cargando ficha…") }
                    if let issue { NodusNotice(tone:.blocked,title:"No se ha podido cargar la ficha",message:LocalizedStringKey(issue));Button("Reintentar") { Task { await load() } } }
                    if let source {
                        if source.objectValue?["prose"]?.arrayValue?.isEmpty == true { Text("Esta ficha todavía no tiene texto.").foregroundStyle(.secondary) }
                        ForEach(source.objectValue?["prose"]?.arrayValue ?? [],id:\.self) { block in
                            VStack(alignment:.leading,spacing:8) {
                                if let heading = block.objectValue?["heading"]?.stringValue { Text(heading).font(.headline) }
                                CorpusProse(block.objectValue?["text"]?.stringValue ?? "",accent:session.accent,session:session)
                            }
                        }
                    }
                }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            }.navigationTitle(source?.objectValue?["entry"]?.objectValue?["title"]?.stringValue ?? "Ficha del mundo").navigationBarTitleDisplayMode(.inline)
                .nodusModalClose(accent:session.accent).task { await load() }
        }.tint(session.accent)
    }
    private func load() async {
        loading = true;defer { loading = false }
        do { source = try await CompanionWorldChatSources.source(session:session,key:key);issue = nil }
        catch where error.isCancellation {} catch { issue = error.localizedDescription }
    }
}
