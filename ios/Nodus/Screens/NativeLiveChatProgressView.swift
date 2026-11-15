import NodusKit
import NodusUI
import SwiftUI

struct NativeLiveChatProgressView:View {
    let activities:[JSONValue]
    let reasoning:String?
    let concilium:JSONValue?
    let accent:Color
    @State private var showing=false
    private var members:[JSONValue] { concilium?.objectValue?["members"]?.arrayValue ?? [] }
    var body:some View {
        if !activities.isEmpty || reasoning?.isEmpty == false || !members.isEmpty {
            Button { showing=true } label: {
                HStack(spacing:10) {
                    Image(systemName:"sparkle.magnifyingglass")
                    Text(summary).font(.footnote).multilineTextAlignment(.leading).fixedSize(horizontal:false,vertical:true)
                    Spacer(minLength:8);Image(systemName:"chevron.right").font(.caption)
                }.foregroundStyle(accent.nodusReadable).frame(minHeight:44)
            }.buttonStyle(.plain).accessibilityIdentifier("nodus-chat-activity")
                .nodusSheet(isPresented:$showing) {
                    NavigationStack {
                        List {
                            if !members.isEmpty {
                                Section("Concilium") {
                                    ForEach(members.indices,id:\.self) { index in
                                        let raw=members[index].objectValue ?? [:]
                                        VStack(alignment:.leading,spacing:6) {
                                            Text(raw["model"]?.objectValue?["model"]?.stringValue ?? "Modelo del Mac").font(.headline).fixedSize(horizontal:false,vertical:true)
                                            Text(status(raw["status"]?.stringValue ?? "waiting")).font(.caption).foregroundStyle(.secondary)
                                            if let error=raw["error"]?.stringValue { Text(error).font(.footnote).foregroundStyle(.red) }
                                            if let answer=raw["answer"]?.stringValue,!answer.isEmpty { Text(String((answer.components(separatedBy:"```").first ?? "").prefix(1200))).font(.body).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                                        }.padding(.vertical,4)
                                    }
                                }
                            }
                            if !activities.isEmpty {
                                Section("Actividad del Mac") {
                                    ForEach(activities.indices,id:\.self) { index in
                                        let raw=activities[index].objectValue ?? [:]
                                        VStack(alignment:.leading,spacing:4) {
                                            Text(activityName(raw)).font(.callout)
                                            if let subject=raw["subject"]?.stringValue,!subject.isEmpty { Text(subject).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true) }
                                            HStack {
                                                Text(status(raw["status"]?.stringValue ?? "active"))
                                                if let count=raw["count"]?.intValue { Text("· \(count)") }
                                            }.font(.caption).foregroundStyle(.secondary)
                                        }.padding(.vertical,4)
                                    }
                                }
                            }
                            if let reasoning,!reasoning.isEmpty {
                                Section("Razonamiento recibido") { Text(reasoning).font(.body).textSelection(.enabled).fixedSize(horizontal:false,vertical:true) }
                            }
                        }.navigationTitle("Actividad").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("Listo") { showing=false }.accessibilityIdentifier("nodus-chat-activity-close") } }
                    }.tint(accent)
                }
        }
    }
    private var summary:String {
        if !members.isEmpty { return "Concilium · \(members.filter{$0.objectValue?["status"] == .string("complete")}.count) de \(members.count) respuestas · "+status(concilium?.objectValue?["status"]?.stringValue ?? "deliberating") }
        if let current=activities.last(where:{$0.objectValue?["status"] == .string("active")})?.objectValue { return activityName(current) }
        return "Ver actividad y razonamiento del Mac"
    }
    private func status(_ value:String) -> String {
        ["waiting":"Pendiente","thinking":"Generando","active":"En curso","complete":"Completado","completed":"Completado","error":"Error","failed":"Error","cancelled":"Detenido","deliberating":"Deliberando","synthesizing":"Redactando la síntesis"][value] ?? "En curso"
    }
    private func activityName(_ value:[String:JSONValue]) -> String {
        let layer=value["layer"]?.stringValue ?? "",operation=value["operation"]?.stringValue ?? ""
        if layer == "web" { return ["query":"Búsqueda web","fetch":"Leyendo una página web","results":"Resultados de búsqueda","finish":"Consulta web finalizada","reformulate":"Reformulando la búsqueda"][operation] ?? "Consultando la web" }
        if layer == "response" { return operation == "citations" ? "Comprobando las citas":"Redactando la respuesta" }
        return ["scope":"Preparando las fuentes elegidas","ideas":"Consultando ideas","profiles":"Consultando perfiles","nodus":"Consultando la biblioteca","zotero":"Consultando Zotero","context":"Preparando el contexto","graph":"Consultando relaciones","attachments":"Leyendo los adjuntos","tools":"Preparando los resultados"][layer] ?? "Consultando fuentes"
    }
}
