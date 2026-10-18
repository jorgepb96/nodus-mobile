import Foundation
import NodusKit
import Testing
@testable import Nodus

@Suite("Native live canonical context options") @MainActor
struct NativeLiveChatOptionsTests {
    @Test("default request includes all three canonical layers and uses the Mac model")
    func defaultRequest() throws {
        let id=UUID().uuidString
        defer { try? FileManager.default.removeItem(at:ChatHistoryStore.directory(spaceId:id)) }
        let options=NativeLiveChatOptions(spaceId:id)
        options.macModel = .object(["provider":.string("codex"),"model":.string("mac-session-model")])
        let request=try options.generation(kind:.research)
        #expect(request.objectValue?["model"] == options.macModel)
        #expect(request.objectValue?["selection"]?.objectValue?["layers"] == .object(["ideas":.bool(true),"documents":.bool(true),"indexed":.bool(true),"web":.bool(true)]))
        #expect(request.objectValue?["researchAnswerVerification"] == nil)
        let bytes=try JSONEncoder.nodus.encode(request)
        #expect(try JSONDecoder.nodus.decode(JSONValue.self,from:bytes) == request)
    }
    @Test("document and indexed switches couple exactly and preserve opaque selection fields")
    func layerCoupling() {
        let id=UUID().uuidString
        defer { try? FileManager.default.removeItem(at:ChatHistoryStore.directory(spaceId:id)) }
        let options=NativeLiveChatOptions(spaceId:id)
        var raw=NativeLiveChatOptions.defaultSelection.objectValue!
        raw["notebookId"] = .string("own-notebook")
        raw["sourceFilter"] = .object(["enabled":.bool(true),"authorIds":.array([.string("author")]),"workIds":.array([])])
        raw["retrieval"] = .object(["preset":.string("deep"),"candidates":.int(120)])
        options.preferences.selection = .object(raw)
        options.setLayer("indexed",enabled:false)
        #expect(!options.layerEnabled("indexed"));#expect(!options.layerEnabled("documents"));#expect(options.layerEnabled("ideas"))
        #expect(options.preferences.selection.objectValue?["passages"] == .bool(false))
        options.setLayer("documents",enabled:true)
        #expect(options.layerEnabled("documents"));#expect(options.layerEnabled("indexed"))
        options.setLayer("ideas",enabled:false)
        for key in ["ideas","themes","contradictions","gaps","readingPath","authors","graph"] { #expect(options.preferences.selection.objectValue?[key] == .bool(false)) }
        for key in ["notebookId","sourceFilter","retrieval"] { #expect(options.preferences.selection.objectValue?[key] == raw[key]) }
    }
    @Test("adoption retains the original selection and saved web false dominates an auto preference")
    func adoption() throws {
        let id=UUID().uuidString
        defer { try? FileManager.default.removeItem(at:ChatHistoryStore.directory(spaceId:id)) }
        let options=NativeLiveChatOptions(spaceId:id)
        var raw=NativeLiveChatOptions.defaultSelection.objectValue!
        raw["layers"] = .object(["ideas":.bool(false),"documents":.bool(false),"indexed":.bool(true),"web":.bool(false)])
        raw["notebookId"] = .string("same-owner-notebook")
        let selection=JSONValue.object(raw)
        options.adoptConversation(CompanionChatDocument(version:1,kind:.research,id:"chat",revision:String(repeating:"a",count:64),data:.object(["selection":selection]),companion:nil))
        #expect(options.preferences.selection == selection)
        #expect(options.preferences.webSearch == "off")
        let request=try options.generation(kind:.research)
        #expect(request.objectValue?["webSearch"] == .string("off"))
        #expect(request.objectValue?["selection"]?.objectValue?["notebookId"] == .string("same-owner-notebook"))
        let reopened=NativeLiveChatOptions(spaceId:id)
        #expect(reopened.preferences.selection == options.preferences.selection)
        #expect(reopened.preferences.webSearch == "off")
        options.setWebSearch(enabled:true)
        #expect(options.preferences.selection.objectValue?["layers"]?.objectValue?["web"] == .bool(true))
        #expect(try options.generation(kind:.research).objectValue?["webSearch"] == .string("auto"))
    }
    @Test("legacy indexed-only normalizes to three layers and preserves explicit web choice")
    func legacyIndexedOnly() {
        let legacy:JSONValue = .object(["layers":.object(["ideas":.bool(true),"documents":.bool(true),"indexedOnly":.bool(true)]),"notebookId":.string("legacy")])
        let normalized=NativeLiveChatOptions.normalizedSelection(legacy,webSearch:"auto")
        #expect(normalized.objectValue?["layers"] == .object(["ideas":.bool(false),"documents":.bool(false),"indexed":.bool(true),"web":.bool(false)]))
        #expect(normalized.objectValue?["passages"] == .bool(true))
        #expect(normalized.objectValue?["notebookId"] == .string("legacy"))
        var raw=legacy.objectValue!,layers=raw["layers"]!.objectValue!;layers["web"] = .bool(true);raw["layers"] = .object(layers)
        #expect(NativeLiveChatOptions.effectiveWeb(.object(raw),saved:"off") == "auto")
        #expect(NativeLiveChatOptions.normalizedSelection(.object(raw),webSearch:"off").objectValue?["layers"]?.objectValue?["web"] == .bool(true))
    }
    @Test("legacy missing indexed follows documents and missing layers respects owning academic context")
    func olderSelections() {
        let old:JSONValue = .object(["layers":.object(["ideas":.bool(true),"documents":.bool(false)])])
        #expect(NativeLiveChatOptions.contextLayers(old)["indexed"] == false)
        let noLayers:JSONValue = .object(["ideas":.bool(false),"documents":.bool(false),"passages":.bool(false)])
        #expect(NativeLiveChatOptions.contextLayers(noLayers,academic:true)["documents"] == true)
        #expect(NativeLiveChatOptions.contextLayers(noLayers,academic:false)["documents"] == false)
    }
    @Test("Mac verification metadata is read-only and omission is unknown, never invented off")
    func verificationMetadata() {
        let id=UUID().uuidString
        defer { try? FileManager.default.removeItem(at:ChatHistoryStore.directory(spaceId:id)) }
        let options=NativeLiveChatOptions(spaceId:id)
        #expect(options.macVerification == nil)
        for value in ["off","legacy","structured"] {
            options.adoptMacVerification(.string(value))
            #expect(options.macVerification?.rawValue == value)
        }
        options.adoptMacVerification(nil)
        #expect(options.macVerification == nil)
        #expect(options.macVerificationLabel == "No disponible en esta versión de Nodus")
        options.adoptMacVerification(.string("unsupported-future"))
        #expect(options.macVerification == nil)
    }
}
