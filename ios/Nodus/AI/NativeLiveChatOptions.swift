import Foundation
import NodusKit
import Observation

@Observable @MainActor
final class NativeLiveChatOptions {
    struct Preferences:Codable {
        var model:JSONValue?
        var systemPromptId:String?
        var useMacPrompt:Bool? = true
        var thinkingEffort="standard"
        var selection=NativeLiveChatOptions.defaultSelection
        var webSearch="auto"
        var skillIds:[String]=[]
        var council:[JSONValue]=[]
        var chairman=0
        var attachmentIds:[String]=[]
    }
    struct Named:Identifiable,Hashable {
        let id:String
        let name:String
    }
    var preferences=Preferences()
    private(set) var academicContext=false
    var providers:[Named]=[]
    var models:[JSONValue]=[]
    var skills:[Named]=[]
    var prompts:[Named]=[]
    var notebooks:[Named]=[]
    var authors:[Named]=[]
    var works:[Named]=[]
    var attachments:[Named]=[]
    var efforts:[String]=[]
    enum MacVerification:String { case off, legacy, structured }
    private(set) var macVerification:MacVerification?
    var macVerificationLabel:String {
        switch macVerification {
        case .off: return "Desactivada"
        case .legacy: return "Verificación clásica"
        case .structured: return "Verificación estructurada"
        case nil: return "No disponible en esta versión de Nodus"
        }
    }
    func adoptMacVerification(_ value:JSONValue?) { macVerification=value?.stringValue.flatMap(MacVerification.init(rawValue:)) }
    var macModel:JSONValue?
    var issue:String?
    var loading=false
    var catalogLoading=false
    var loaded=false
    @ObservationIgnored private let file:URL
    @ObservationIgnored private var restored=false
    @ObservationIgnored private var configurationRequest=UUID()
    @ObservationIgnored private var catalogueRequest=UUID()
    nonisolated static let defaultSelection:JSONValue = .object([
        "ideas":.bool(true),"themes":.bool(true),"contradictions":.bool(true),"gaps":.bool(true),"readingPath":.bool(true),"authors":.bool(true),"graph":.bool(true),"documents":.bool(true),"passages":.bool(true),
        "graphParts":.object(["ideaNodes":.bool(true),"themeNodes":.bool(true),"ideaEdges":.bool(true),"authorGraph":.bool(true)]),"layers":.object(["ideas":.bool(true),"documents":.bool(true),"indexed":.bool(true)])
    ])
    init(spaceId:String) {
        file=ChatHistoryStore.directory(spaceId:spaceId).appendingPathComponent("live-options.snapshot")
        if FileManager.default.fileExists(atPath:file.path) {
            do { preferences=try JSONDecoder.nodus.decode(Preferences.self,from:Data(contentsOf:file));restored=true }
            catch { issue="No se han podido leer las opciones guardadas del chat live. Se conserva su archivo." }
        }
    }
    /// Mirrors shared/researchContextLayers.ts. All unrelated selection fields remain opaque.
    nonisolated static func contextLayers(_ selection:JSONValue,academic:Bool=false) -> [String:Bool] {
        let raw=selection.objectValue ?? [:]
        if let saved=raw["layers"]?.objectValue {
            if saved["indexedOnly"] == .bool(true) { return ["ideas":false,"documents":false,"indexed":true] }
            let documents=saved["documents"] == .bool(true)
            return ["ideas":saved["ideas"] == .bool(true),"documents":documents,"indexed":documents || (saved["indexed"] ?? saved["documents"]) == .bool(true)]
        }
        let ideas=["ideas","themes","contradictions","gaps","readingPath","authors","graph"].contains { raw[$0] == .bool(true) }
        let documents=academic || raw["documents"] == .bool(true) || raw["passages"] != .bool(false)
        return ["ideas":ideas,"documents":documents,"indexed":documents]
    }
    nonisolated static func effectiveWeb(_ selection:JSONValue,saved:String) -> String {
        let layers=selection.objectValue?["layers"]?.objectValue
        if let explicit=layers?["web"],case .bool(let enabled)=explicit { return enabled ? "auto":"off" }
        if layers?["indexedOnly"] == .bool(true) { return "off" }
        return saved == "off" ? "off":"auto"
    }
    nonisolated static func normalizedSelection(_ selection:JSONValue,webSearch:String,academic:Bool=false) -> JSONValue {
        var raw=selection.objectValue ?? [:]
        let layers=contextLayers(selection,academic:academic),ideas=layers["ideas"] == true,documents=layers["documents"] == true,indexed=layers["indexed"] == true
        raw["layers"] = .object(["ideas":.bool(ideas),"documents":.bool(documents),"indexed":.bool(indexed),"web":.bool(effectiveWeb(selection,saved:webSearch) == "auto")])
        for key in ["ideas","themes","contradictions","gaps","readingPath","authors","graph"] { raw[key] = .bool(ideas) }
        raw["graphParts"] = .object(Dictionary(uniqueKeysWithValues:["ideaNodes","themeNodes","ideaEdges","authorGraph"].map { ($0,JSONValue.bool(ideas)) }))
        raw["documents"] = .bool(documents);raw["passages"] = .bool(indexed)
        return .object(raw)
    }
    func layerEnabled(_ key:String) -> Bool { Self.contextLayers(preferences.selection,academic:academicContext)[key] == true }
    func setLayer(_ key:String,enabled:Bool) {
        guard ["ideas","documents","indexed"].contains(key) else { return }
        var raw=Self.normalizedSelection(preferences.selection,webSearch:preferences.webSearch,academic:academicContext).objectValue ?? [:]
        var layers=raw["layers"]?.objectValue ?? [:];layers[key] = .bool(enabled)
        if key == "documents",enabled { layers["indexed"] = .bool(true) }
        if key == "indexed",!enabled { layers["documents"] = .bool(false) }
        raw["layers"] = .object(layers)
        preferences.selection=Self.normalizedSelection(.object(raw),webSearch:preferences.webSearch,academic:academicContext)
        preferences.webSearch=Self.effectiveWeb(preferences.selection,saved:preferences.webSearch)
    }
    func setWebSearch(enabled:Bool) {
        var raw=Self.normalizedSelection(preferences.selection,webSearch:preferences.webSearch,academic:academicContext).objectValue ?? [:]
        var layers=raw["layers"]?.objectValue ?? [:];layers["web"] = .bool(enabled);raw["layers"] = .object(layers)
        preferences.selection = .object(raw);preferences.webSearch=enabled ? "auto":"off"
    }
    var effectiveModel:JSONValue? { preferences.model ?? macModel }
    func modelKey(_ value:JSONValue) -> String { (value.objectValue?["provider"]?.stringValue ?? "")+"::"+(value.objectValue?["model"]?.stringValue ?? "") }
    func modelName(_ value:JSONValue?) -> String {
        guard let raw=value?.objectValue,let model=raw["model"]?.stringValue else { return "Modelo del Mac" }
        let provider=raw["provider"]?.stringValue ?? ""
        return model+" · "+(providers.first(where:{$0.id == provider})?.name ?? provider)
    }
    func persist() throws {
        try FileManager.default.createDirectory(at:file.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder.nodus.encode(preferences).write(to:file,options:[.atomic,.completeFileProtection])
    }
    func generation(kind:CompanionChatKind) throws -> JSONValue {
        var result:[String:JSONValue]=["thinkingEffort":.string(preferences.thinkingEffort)]
        if let model=effectiveModel { result["model"]=model }
        if preferences.useMacPrompt == false { result["systemPromptId"] = preferences.systemPromptId.map(JSONValue.string) ?? .null }
        if !preferences.attachmentIds.isEmpty { result["attachmentIds"] = .array(preferences.attachmentIds.map(JSONValue.string)) }
        if kind == .research {
            preferences.webSearch=Self.effectiveWeb(preferences.selection,saved:preferences.webSearch)
            preferences.selection=Self.normalizedSelection(preferences.selection,webSearch:preferences.webSearch,academic:academicContext)
            result["selection"]=preferences.selection;result["webSearch"] = .string(preferences.webSearch)
            result["skillIds"] = .array(preferences.skillIds.map(JSONValue.string))
            if !preferences.council.isEmpty {
                guard (2...5).contains(preferences.council.count),preferences.council.indices.contains(preferences.chairman),Set(preferences.council.map(modelKey)).count == preferences.council.count else { throw APIError(status:400,code:"concilium_invalid",message:"Concilium necesita entre dos y cinco modelos distintos y un presidente.") }
                result["concilium"] = .object(["models":.array(preferences.council),"chairman":.int(Int64(preferences.chairman))])
            }
        }
        try persist();return .object(result)
    }
    func load(session:SpaceSession,conversationId:String? = nil) async {
        academicContext=session.vaultType == .academic
        guard let vault=session.vaultId else { issue=DesktopBridgeError.permissionDenied.localizedDescription;return }
        let identity=UUID();configurationRequest=identity;loading=true
        defer { if configurationRequest == identity { loading=false } }
        do {
            let bridge=try ConnectionClient.companionChat(for:session.connection),kind=CompanionChatKind(vaultType:session.vaultType)
            let config=try await bridge.operation(vaultId:vault,method:"getMobileLiveChatConfiguration",args:[.string(kind.rawValue),preferences.model ?? .null],timeout:30)
            guard configurationRequest == identity else { return }
            guard let raw=config.objectValue,raw["version"] == .int(1),raw["vaultId"] == .string(vault),raw["kind"] == .string(kind.rawValue) else { throw DesktopBridgeError.malformedResponse }
            adoptMacVerification(raw["researchAnswerVerification"])
            providers=Self.named(raw["providers"],name:"name");skills=Self.named(raw["skills"],name:"name")
            macModel=raw["model"] == .null ? nil:raw["model"]
            models=raw["favorites"]?.arrayValue ?? []
            if let current=effectiveModel,!models.contains(current) { models.insert(current,at:0) }
            efforts=raw["efforts"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !restored {
                preferences.selection=raw["selection"] ?? Self.defaultSelection
                preferences.webSearch=raw["webSearch"]?.stringValue ?? "auto"
                preferences.thinkingEffort=raw["thinkingEffort"]?.stringValue ?? "standard"
                restored=true
            }
            preferences.webSearch=Self.effectiveWeb(preferences.selection,saved:preferences.webSearch)
            if preferences.thinkingEffort != "standard",!efforts.contains(preferences.thinkingEffort) { preferences.thinkingEffort=raw["thinkingEffort"]?.stringValue ?? "standard" }
            loaded=true;issue=nil
            let promptState=try await bridge.operation(vaultId:vault,method:"getResearchSystemPrompts",args:[conversationId.map { .string(kind.rawValue+":"+$0) } ?? .null])
            guard configurationRequest == identity else { return }
            prompts=Self.named(promptState.objectValue?["prompts"],name:"name")
            if preferences.useMacPrompt != false { preferences.systemPromptId=promptState.objectValue?["selectedId"]?.stringValue }
            if kind == .research {
                let list=try await bridge.operation(vaultId:vault,method:"listResearchNotebooks",args:[])
                notebooks=Self.named(list,name:"name")
                let sources=try await bridge.operation(vaultId:vault,method:"listResearchContextSources",args:[])
                authors=Self.named(sources.objectValue?["authors"],name:"name");works=Self.named(sources.objectValue?["works"],name:"title")
            }
            if let conversationId {
                let owner:JSONValue = .object(["surface":.string(kind.rawValue),"conversationId":.string(conversationId)])
                let files=try await bridge.operation(vaultId:vault,method:"listResearchAttachments",args:[owner])
                attachments=Self.named(files,name:"name")
            } else { attachments=[];preferences.attachmentIds=[] }
            try persist()
        } catch where error.isCancellation { return }
        catch { if configurationRequest == identity { issue=error.localizedDescription } }
    }
    func catalogue(provider:String,session:SpaceSession) async {
        guard let vault=session.vaultId else { return }
        await catalogue(provider:provider) {
            let bridge=try ConnectionClient.companionChat(for:session.connection)
            return try await bridge.operation(vaultId:vault,method:"getModelCatalog",args:[.string(provider)],timeout:30)
        }
    }
    /// Every selection loads its own catalogue; only the latest intent may update the picker.
    func catalogue(provider:String,request:() async throws -> JSONValue) async {
        let identity=UUID();catalogueRequest=identity;catalogLoading=true
        defer { if catalogueRequest == identity { catalogLoading=false } }
        do {
            let result=try await request()
            guard catalogueRequest == identity else { return }
            guard result.objectValue?["status"] == .string("read"),let rows=result.objectValue?["selectableModels"]?.arrayValue else { throw APIError(status:503,code:"mac_model_catalogue_unavailable",message:"El Mac no ha podido consultar este proveedor. Revisa su conexión o sesión en Nodus.") }
            var available=rows.compactMap { value -> JSONValue? in
                guard let id=value.objectValue?["id"]?.stringValue ?? value.stringValue,!id.isEmpty else { return nil }
                return .object(["provider":.string(provider),"model":.string(id)])
            }
            for model in models where model.objectValue?["provider"]?.stringValue != provider { available.append(model) }
            if let current=effectiveModel,!available.contains(current) { available.insert(current,at:0) }
            models=available;issue=rows.isEmpty ? "El Mac no ha devuelto modelos para este proveedor.":nil
        } catch where error.isCancellation { return }
        catch { if catalogueRequest == identity { issue=error.localizedDescription } }
    }
    private static func named(_ value:JSONValue?,name:String) -> [Named] {
        (value?.arrayValue ?? []).compactMap { value in
            guard let row=value.objectValue,let id=row["id"]?.stringValue,let title=row[name]?.stringValue else { return nil };return Named(id:id,name:title)
        }
    }
    func adoptConversation(_ document:CompanionChatDocument?) {
        preferences.useMacPrompt=true;preferences.systemPromptId=nil
        if let model=document?.data.objectValue?["model"],model != .null { preferences.model=model }
        if let selection=document?.data.objectValue?["selection"],selection.objectValue != nil,document?.kind == .research { preferences.selection=selection;preferences.webSearch=Self.effectiveWeb(selection,saved:preferences.webSearch) }
        preferences.attachmentIds=[]
    }
}
