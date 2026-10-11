import NodusKit
import NodusUI
import SwiftUI

struct NativeLiveChatOptionsView:View {
    let session:SpaceSession
    let options:NativeLiveChatOptions
    let conversationId:String?
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProvider=""
    @State private var query=""
    @State private var mutationIssue:String?
    private var research:Bool { CompanionChatKind(vaultType:session.vaultType) == .research }
    @Bindable private var bound:NativeLiveChatOptions
    init(session:SpaceSession,options:NativeLiveChatOptions,conversationId:String?) {
        self.session=session;self.options=options;self.conversationId=conversationId;self._bound=Bindable(options)
    }
    var body:some View {
        NavigationStack {
            Form {
                Section {
                    Text(options.modelName(options.effectiveModel)).font(.callout).textSelection(.enabled)
                    NavigationLink("Elegir modelo") { modelList(council:false) }
                    Button("Usar la elección actual del Mac") { options.preferences.model=nil;options.preferences.thinkingEffort="standard";Task { await options.load(session:session,conversationId:conversationId) } }
                    if options.loading { ProgressView("Consultando Nodus…") }
                    if let issue=options.issue { Text(issue).font(.footnote).foregroundStyle(.red);Button("Reintentar") { Task { await options.load(session:session,conversationId:conversationId) } } }
                } header: { Text("Modelos del Mac") } footer: { Text("La generación se ejecuta en tu Mac con sus proveedores, modelos locales y sesiones de suscripción. La pregunta quedará pendiente si se pierde la conexión.") }
                Section("Respuesta") {
                    Picker("Prompt",selection:Binding(get:{options.preferences.systemPromptId},set:{options.preferences.systemPromptId=$0;options.preferences.useMacPrompt=false})) {
                        Text("Predeterminado").tag(nil as String?)
                        ForEach(options.prompts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Razonamiento",selection:$bound.preferences.thinkingEffort) {
                        if options.preferences.thinkingEffort == "standard" { Text("Según el Mac").tag("standard") }
                        ForEach(options.efforts,id:\.self) { Text(effortName($0)).tag($0) }
                    }
                    if research { Toggle("Búsqueda web",isOn:Binding(get:{options.preferences.webSearch == "auto"},set:{options.preferences.webSearch=$0 ? "auto":"off"})) }
                }
                if research { researchSections }
                if !options.attachments.isEmpty {
                    Section("Adjuntos de esta conversación") {
                        ForEach(options.attachments) { file in Toggle(file.name,isOn:selected(file.id,\NativeLiveChatOptions.Preferences.attachmentIds)) }
                    }
                }
                if let issue=mutationIssue { Text(issue).foregroundStyle(.red) }
            }
            .navigationTitle("Opciones del chat live").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Listo") { do { try options.persist();dismiss() } catch { mutationIssue=error.localizedDescription } }.accessibilityIdentifier("nodus-chat-options-close") } }
            .task { await options.load(session:session,conversationId:conversationId) }
        }.tint(session.accent)
    }
    @ViewBuilder private var researchSections:some View {
        Section {
            Toggle("Ideas y relaciones",isOn:layer("ideas"))
            Toggle("Documentos y pasajes",isOn:layer("documents"))
            Picker("Cuaderno",selection:Binding<String?>(get:{options.preferences.selection.objectValue?["notebookId"]?.stringValue},set:{setSelection("notebookId",$0.map(JSONValue.string) ?? .null)})) {
                Text("Todo el vault").tag(nil as String?)
                ForEach(options.notebooks) { Text($0.name).tag(Optional($0.id)) }
            }
            if session.vaultType != .academic { NavigationLink("Secciones y grafo") {
                Form {
                    Section("Secciones") {
                        ForEach(["ideas","themes","contradictions","gaps","readingPath","authors","documents","passages","graph"],id:\.self) { key in Toggle(sectionName(key),isOn:flag(key)) }
                    }
                    Section("Grafo") {
                        ForEach(["ideaNodes","themeNodes","ideaEdges","authorGraph"],id:\.self) { key in Toggle(sectionName(key),isOn:nestedFlag("graphParts",key)) }
                    }
                }.navigationTitle("Secciones del contexto")
            } }
            Toggle("Filtrar por fuentes",isOn:nestedFlag("sourceFilter","enabled"))
            if options.preferences.selection.objectValue?["sourceFilter"]?.objectValue?["enabled"] == .bool(true) {
                NavigationLink("Autores") { sourceList(options.authors,key:"authorIds",title:"Autores") }
                NavigationLink("Obras") { sourceList(options.works,key:"workIds",title:"Obras") }
            }
            NavigationLink("Profundidad de consulta") { retrievalForm }
        } header: { Text("Contexto") } footer: { Text("Un filtro activo sin fuentes seleccionadas no consulta ninguna obra. El cuaderno conserva sus restricciones y las fuentes preparadas por el Mac.") }
        Section {
            ForEach(options.skills) { skill in Toggle(skill.name,isOn:selected(skill.id,\NativeLiveChatOptions.Preferences.skillIds)) }
        } header: { Text("Skills") } footer: { Text("Las skills elegidas se invocan para esta pregunta, además de las que Nodus tenga activadas en el Mac.") }
        Section {
            NavigationLink(options.preferences.council.isEmpty ? "Elegir consejo":"\(options.preferences.council.count) modelos") { modelList(council:true) }
            if !options.preferences.council.isEmpty {
                Picker("Presidente",selection:$bound.preferences.chairman) {
                    ForEach(options.preferences.council.indices,id:\.self) { index in Text(options.modelName(options.preferences.council[index])).tag(index) }
                }
                Button("Desactivar Concilium") { options.preferences.council=[];options.preferences.chairman=0 }
            }
        } header: { Text("Concilium") } footer: { Text("Entre dos y cinco modelos distintos. El presidente redacta la síntesis final.") }
    }
    private func modelList(council:Bool) -> some View {
        List {
            Section {
                Picker("Proveedor del Mac",selection:$selectedProvider) {
                    Text("Favoritos").tag("")
                    ForEach(options.providers) { Text($0.name).tag($0.id) }
                }.onChange(of:selectedProvider) { _,provider in if !provider.isEmpty { Task { await options.catalogue(provider:provider,session:session) } } }
                if options.catalogLoading { ProgressView("Cargando catálogo del Mac…") }
                if let issue=options.issue { Text(issue).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                ForEach(options.models.filter { model in
                    (selectedProvider.isEmpty || model.objectValue?["provider"] == .string(selectedProvider)) && (query.isEmpty || options.modelName(model).localizedCaseInsensitiveContains(query))
                },id:\.self) { model in
                    Button {
                        if council {
                            if options.preferences.council.contains(where:{options.modelKey($0) == options.modelKey(model)}) { options.preferences.council.removeAll{options.modelKey($0) == options.modelKey(model)};options.preferences.chairman=min(options.preferences.chairman,max(0,options.preferences.council.count-1)) }
                            else if options.preferences.council.count < 5 { options.preferences.council.append(model) }
                        } else {
                            options.preferences.model=model;options.preferences.thinkingEffort="standard"
                            Task { await options.load(session:session,conversationId:conversationId) }
                        }
                    } label: {
                        HStack {
                            Text(options.modelName(model)).foregroundStyle(.primary).fixedSize(horizontal:false,vertical:true)
                            Spacer(minLength:12)
                            if council ? options.preferences.council.contains(where:{options.modelKey($0) == options.modelKey(model)}):options.effectiveModel == model { Image(systemName:"checkmark").foregroundStyle(session.accent) }
                        }.frame(minHeight:44)
                    }.buttonStyle(.plain)
                }
            }
        }.searchable(text:$query,prompt:"Buscar modelo").navigationTitle(council ? "Consejo de modelos":"Modelo del Mac")
    }
    private var retrievalForm:some View {
        Form {
            Picker("Profundidad",selection:Binding(get:{options.preferences.selection.objectValue?["retrieval"]?.objectValue?["preset"]?.stringValue ?? "agent"},set:{ chooseRetrieval($0) })) {
                Text("Según el agente").tag("agent");Text("Rápida").tag("fast");Text("Equilibrada").tag("balanced");Text("Profunda").tag("deep");Text("Personalizada").tag("custom")
            }
            if let raw=options.preferences.selection.objectValue?["retrieval"]?.objectValue {
                Section("Límites de recuperación") {
                    Stepper("Candidatos: \(raw["candidates"]?.intValue ?? 60)",value:limit("candidates",60),in:1...500)
                    Stepper("Pasajes por ronda: \(raw["passagesPerRound"]?.intValue ?? 12)",value:limit("passagesPerRound",12),in:1...max(1,Int(raw["candidates"]?.intValue ?? 60)))
                    Stepper("Evidencia: \(raw["evidenceTokens"]?.intValue ?? 8000) tokens",value:limit("evidenceTokens",8000),in:256...64000,step:256)
                    Stepper("Rondas: \(raw["rounds"]?.intValue ?? 3)",value:limit("rounds",3),in:1...16)
                    Toggle("Ampliar automáticamente",isOn:Binding(get:{raw["autoExpand"] == .bool(true)},set:{setRetrieval("autoExpand",.bool($0))}))
                }
                Section {
                    Toggle("Umbral manual",isOn:Binding(get:{raw["threshold"]?.objectValue?["mode"] == .string("manual")},set:{ enabled in setRetrieval("threshold",enabled ? .object(["mode":.string("manual"),"value":.double(0.5),"embeddingSpace":.string(""),"metric":.string("cosine")]):.object(["mode":.string("automatic")])) }))
                    if raw["threshold"]?.objectValue?["mode"] == .string("manual") {
                        TextField("Espacio de embeddings",text:Binding(get:{raw["threshold"]?.objectValue?["embeddingSpace"]?.stringValue ?? ""},set:{setThreshold("embeddingSpace",.string($0))})).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Slider(value:Binding(get:{raw["threshold"]?.objectValue?["value"]?.doubleValue ?? 0.5},set:{setThreshold("value",.double($0))}),in:-1...1)
                        Text("\(raw["threshold"]?.objectValue?["value"]?.doubleValue ?? 0.5,format:.number.precision(.fractionLength(2)))").font(.caption).monospacedDigit()
                    }
                } header: { Text("Umbral de similitud") } footer: { Text("El umbral manual debe corresponder al mismo espacio de embeddings preparado en el Mac.") }
            }
        }.navigationTitle("Profundidad de consulta")
    }
    private func sourceList(_ rows:[NativeLiveChatOptions.Named],key:String,title:String) -> some View {
        List(rows) { row in
            Toggle(row.name,isOn:Binding(get:{options.preferences.selection.objectValue?["sourceFilter"]?.objectValue?[key]?.arrayValue?.contains(.string(row.id)) == true},set:{ enabled in
                var filter=options.preferences.selection.objectValue?["sourceFilter"]?.objectValue ?? ["enabled":.bool(true),"authorIds":.array([]),"workIds":.array([])]
                var ids=filter[key]?.arrayValue ?? [];ids.removeAll{$0 == .string(row.id)};if enabled { ids.append(.string(row.id)) };filter[key] = .array(ids);setSelection("sourceFilter",.object(filter))
            })).frame(minHeight:44)
        }.navigationTitle(title)
    }
    private func selected(_ id:String,_ key:WritableKeyPath<NativeLiveChatOptions.Preferences,[String]>) -> Binding<Bool> {
        Binding(get:{options.preferences[keyPath:key].contains(id)},set:{ enabled in options.preferences[keyPath:key].removeAll{$0 == id};if enabled { options.preferences[keyPath:key].append(id) } })
    }
    private func setSelection(_ key:String,_ value:JSONValue) { var raw=options.preferences.selection.objectValue ?? [:];raw[key]=value;options.preferences.selection = .object(raw) }
    private func flag(_ key:String) -> Binding<Bool> { Binding(get:{options.preferences.selection.objectValue?[key] == .bool(true)},set:{setSelection(key,.bool($0))}) }
    private func nestedFlag(_ parent:String,_ key:String) -> Binding<Bool> {
        Binding(get:{options.preferences.selection.objectValue?[parent]?.objectValue?[key] == .bool(true)},set:{ enabled in
            var nested=options.preferences.selection.objectValue?[parent]?.objectValue ?? (parent == "sourceFilter" ? ["enabled":.bool(false),"authorIds":.array([]),"workIds":.array([])]:[:]);nested[key] = .bool(enabled);setSelection(parent,.object(nested))
        })
    }
    private func layer(_ key:String) -> Binding<Bool> {
        Binding(get:{options.preferences.selection.objectValue?["layers"]?.objectValue?[key] == .bool(true)},set:{ enabled in
            var raw=options.preferences.selection.objectValue ?? [:],layers=raw["layers"]?.objectValue ?? [:];layers[key] = .bool(enabled);raw["layers"] = .object(layers)
            for field in key == "ideas" ? ["ideas","themes","contradictions","gaps","readingPath","authors","graph"]:["documents","passages"] { raw[field] = .bool(enabled) }
            if key == "ideas" { raw["graphParts"] = .object(Dictionary(uniqueKeysWithValues:["ideaNodes","themeNodes","ideaEdges","authorGraph"].map { ($0,JSONValue.bool(enabled)) })) }
            options.preferences.selection = .object(raw)
        })
    }
    private func chooseRetrieval(_ preset:String) {
        if preset == "agent" { var raw=options.preferences.selection.objectValue ?? [:];raw["retrieval"]=nil;options.preferences.selection = .object(raw);return }
        let limits=preset == "fast" ? [24,6,4000,1]:preset == "deep" ? [120,24,16000,8]:[60,12,8000,3]
        setSelection("retrieval",.object(["preset":.string(preset),"candidates":.int(Int64(limits[0])),"passagesPerRound":.int(Int64(limits[1])),"evidenceTokens":.int(Int64(limits[2])),"rounds":.int(Int64(limits[3])),"autoExpand":.bool(true),"threshold":.object(["mode":.string("automatic")])]))
    }
    private func setRetrieval(_ key:String,_ value:JSONValue) {
        var raw=options.preferences.selection.objectValue?["retrieval"]?.objectValue ?? [:];raw[key]=value;raw["preset"] = .string("custom")
        if key == "candidates",let count=value.intValue,(raw["passagesPerRound"]?.intValue ?? 12)>count { raw["passagesPerRound"] = .int(Int64(count)) }
        setSelection("retrieval",.object(raw))
    }
    private func limit(_ key:String,_ fallback:Int) -> Binding<Int> { Binding(get:{Int(options.preferences.selection.objectValue?["retrieval"]?.objectValue?[key]?.intValue ?? fallback)},set:{setRetrieval(key,.int(Int64($0)))}) }
    private func setThreshold(_ key:String,_ value:JSONValue) { var raw=options.preferences.selection.objectValue?["retrieval"]?.objectValue?["threshold"]?.objectValue ?? [:];raw[key]=value;setRetrieval("threshold",.object(raw)) }
    private func effortName(_ value:String) -> String { ["none":"Sin razonamiento","off":"Desactivado","minimal":"Mínimo","low":"Bajo","medium":"Medio","high":"Alto","xhigh":"Muy alto","max":"Máximo","ultra":"Ultra","on":"Activado"][value] ?? value }
    private func sectionName(_ value:String) -> String { ["ideas":"Ideas","themes":"Temas","contradictions":"Contradicciones","gaps":"Huecos de investigación","readingPath":"Ruta de lectura","authors":"Autores","documents":"Documentos","passages":"Pasajes","graph":"Grafo","ideaNodes":"Nodos de ideas","themeNodes":"Nodos de temas","ideaEdges":"Relaciones entre ideas","authorGraph":"Grafo de autores"][value] ?? value }
}
