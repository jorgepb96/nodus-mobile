import NodusKit
import NodusUI
import SwiftUI

struct ChatHistoryScopePicker: View {
    let organisation: CompanionChatOrganisation?
    @Binding var filter:String
    var body:some View {
        Picker("Mostrar",selection:$filter) {
            Text("Todas").tag("all")
            Text("Fijadas").tag("pinned")
            if let organisation {
                ForEach(organisation.projects) { Text(verbatim:$0.name).tag("project:\($0.id)") }
                ForEach(organisation.folders) { folder in Text(verbatim:organisation.folderName(folder.id) ?? folder.name).tag("folder:\(folder.id)") }
                ForEach(organisation.notebooks) { Text("Cuaderno: \($0.name)").tag("notebook:\($0.id)") }
            }
        }.pickerStyle(.menu).frame(minHeight:44)
    }
}

struct ChatConversationOrganizationView: View {
    let conversation:ChatHistoryStore.Conversation
    let store:ChatHistoryStore
    let accent:Color
    @Environment(\.dismiss) private var dismiss
    @State private var title:String
    @State private var placement:CompanionChatPlacement
    @State private var issue:String?
    init(conversation:ChatHistoryStore.Conversation,store:ChatHistoryStore,accent:Color) {
        self.conversation = conversation;self.store = store;self.accent = accent
        _title = State(initialValue:conversation.title);_placement = State(initialValue:conversation.placement ?? CompanionChatPlacement())
    }
    var body:some View {
        NavigationStack {
            Form {
                Section("Conversación") {
                    TextField("Título",text:$title,axis:.vertical).lineLimit(1...3)
                    Toggle("Fijada",isOn:$placement.pinned).disabled(conversation.isArchived)
                }
                if let organisation = store.organisation {
                    Section("Proyecto y carpeta") {
                        Picker("Proyecto",selection:$placement.projectId) {
                            Text("Sin proyecto").tag(Optional<String>.none)
                            ForEach(organisation.projects) { Text(verbatim:$0.name).tag(Optional($0.id)) }
                        }
                        .onChange(of:placement.projectId) { _,value in placement.folderId = nil;if value != nil,organisation.kind != .research { placement.notebookId = nil } }
                        Picker("Carpeta",selection:$placement.folderId) {
                            Text("Sin carpeta").tag(Optional<String>.none)
                            ForEach(organisation.folders.filter{$0.projectId == placement.projectId}) { folder in Text(verbatim:organisation.folderName(folder.id) ?? folder.name).tag(Optional(folder.id)) }
                        }.disabled(placement.projectId == nil)
                        if let project = organisation.projects.first(where:{$0.id == placement.projectId}),!project.instructions.isEmpty {
                            DisclosureGroup("Instrucciones del proyecto") { Text(verbatim:project.instructions).textSelection(.enabled) }
                        }
                    }
                    if organisation.kind != .study {
                        Section("Cuaderno") {
                            Picker("Cuaderno",selection:$placement.notebookId) {
                                Text("Sin cuaderno").tag(Optional<String>.none)
                                ForEach(organisation.notebooks) { Text(verbatim:$0.name).tag(Optional($0.id)) }
                            }.onChange(of:placement.notebookId) { _,value in if value != nil,organisation.kind != .research { placement.projectId = nil;placement.folderId = nil } }
                        }
                    }
                } else { Text("Abre el historial del Mac para consultar sus proyectos, carpetas y cuadernos.").font(.footnote).foregroundStyle(.secondary) }
                if let issue { NodusNotice(tone:.blocked,title:"No se ha podido guardar",message:LocalizedStringKey(issue)) }
            }.navigationTitle("Organizar conversación").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancelar") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Guardar") { do { try store.organize(conversation.id,placement:placement,title:title);dismiss() } catch { issue = error.localizedDescription } }.disabled(title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) }
                }
        }.tint(accent)
    }
}
