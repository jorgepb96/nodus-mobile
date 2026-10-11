import CryptoKit
import NodusKit
import NodusUI
import Observation
import QuickLook
import SwiftUI
import UIKit
import WebKit

/// One local reader per opened answer. The native chat keeps its composer,
/// history and scrolling; this host has no generation or generic Bridge lane.
struct RichChatAnswerView: View {
    let session:SpaceSession
    let content:String
    let conversationId:String?
    let studyCitations:[JSONValue]
    var desktopRecord:JSONValue? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var reader:RichChatReader?
    @State private var attempt=0
    @State private var downloading=false
    @State private var downloadMessage:String?
    @State private var downloadTask:Task<Void,Never>?
    var body:some View {
        NavigationStack {
            VStack(spacing:0) {
                if let reader {
                    if let issue=reader.issue { NodusNotice(tone:.blocked,title:"Consulta del resultado",message:LocalizedStringKey(issue)).padding(.horizontal) }
                    if reader.loading { ProgressView("Preparando lectura…").padding() }
                    RichChatWebReader(reader:reader,dark:colorScheme == .dark,textScale:textScale).id(attempt)
                    if let downloadMessage { Text(downloadMessage).font(.footnote).foregroundStyle(.secondary).padding() }
                } else { ProgressView("Preparando lectura…") }
            }.navigationTitle("Mensaje").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Listo") { dismiss() } }
                    ToolbarItem(placement:.primaryAction) {
                        Menu {
                            Button("Copiar respuesta",systemImage:"doc.on.doc") { UIPasteboard.general.string=content }
                            Button("Volver a cargar",systemImage:"arrow.clockwise") { reader?.stop();reader=makeReader();attempt += 1 }
                            if session.connection.desktopPairingId != nil {
                                Button("Descargar durante 7 días",systemImage:"arrow.down.circle") { download(days:7) }
                                Button("Descargar durante 30 días",systemImage:"arrow.down.circle") { download(days:30) }
                            }
                        } label: { Image(systemName:downloading ? "clock":"ellipsis.circle").frame(width:44,height:44) }.disabled(downloading).accessibilityLabel("Opciones de la respuesta")
                    }
                }
                .sheet(item:Binding(get:{reader?.source},set:{reader?.source=$0})) { target in
                    switch target {
                    case .study(let value): StudyChatEvidenceView(citation:value,session:session)
                    case .world(let key): WorldChatSourceView(key:key,session:session)
                    case .corpus(let ref): NavigationStack { CorpusReferenceView(session:session,reference:ref).nodusModalClose(accent:session.accent) }
                    }
                }
                .sheet(isPresented:Binding(get:{reader?.shareLease != nil},set:{ if !$0 { reader?.shareLease=nil } })) { if let lease=reader?.shareLease { ReaderImageShareSheet(lease:lease) } }
                .sheet(isPresented:Binding(get:{reader?.previewLease != nil},set:{ if !$0 { reader?.previewLease=nil } })) { if let lease=reader?.previewLease { RichChatFileView(lease:lease,accent:session.accent) } }
        }.tint(session.accent)
            .task { if reader == nil { reader=makeReader() } }
            .onDisappear { downloadTask?.cancel();reader?.stop() }
    }
    private var textScale:Double {
        switch dynamicTypeSize { case .xSmall:0.85;case .small:0.92;case .large:1;case .xLarge:1.12;case .xxLarge:1.24;case .xxxLarge:1.35;case .accessibility1:1.55;case .accessibility2:1.75;case .accessibility3:2;case .accessibility4:2.25;case .accessibility5:2.5;default:1 }
    }
    private func makeReader()->RichChatReader { RichChatReader(session:session,content:content,conversationId:conversationId,studyCitations:studyCitations,desktopRecord:desktopRecord) }
    private func download(days:Int) {
        guard let reader else { return };downloading=true;downloadMessage=nil
        downloadTask=Task { defer { downloading=false;downloadTask=nil };do { try await reader.download(days:days);downloadMessage="Respuesta y archivos guardados durante \(days) días. Los mosaicos de imágenes descargan las zonas que hayas consultado; otras zonas requieren conexión." } catch { if !Task.isCancelled { downloadMessage=error.localizedDescription } } }
    }
}

enum RichChatSource:Identifiable {
    case study(JSONValue),world(String),corpus(CorpusReference)
    var id:String { switch self { case .study(let value):"study:\(value.objectValue?["id"]?.stringValue ?? "")";case .world(let key):"world:\(key)";case .corpus(let ref):"corpus:\(ref.id)" } }
}

@Observable @MainActor final class RichChatReader {
    let session:SpaceSession,content:String,conversationId:String?,studyCitations:[JSONValue]
    let desktopRecord:JSONValue?
    var loading=true
    var issue:String?
    var shareLease:PrivateBridgeFileLease?
    var previewLease:PrivateBridgeFileLease?
    var source:RichChatSource?
    @ObservationIgnored weak var webView:WKWebView?
    @ObservationIgnored private var records:[String:Int]=[:]
    @ObservationIgnored private var originalImages:[String:ReaderImageSource.Content]=[:]
    @ObservationIgnored private var tasks:[String:Task<Void,Never>]=[:]
    @ObservationIgnored private var stopped=false
    init(session:SpaceSession,content:String,conversationId:String?,studyCitations:[JSONValue],desktopRecord:JSONValue? = nil) { self.session=session;self.content=content;self.conversationId=conversationId;self.studyCitations=studyCitations;self.desktopRecord=desktopRecord }
    var kind:CompanionChatKind { CompanionChatKind(vaultType:session.vaultType) }
    func stop() { stopped=true;tasks.values.forEach{$0.cancel()};tasks.removeAll();webView?.stopLoading();webView=nil;originalImages.removeAll() }
    private func connection() throws -> (String,DesktopBridgePairing,DesktopBridgeClient,PrivateBridgeCache) {
        let (vault,pairing,token)=try privateBridgeConnection(session,domain:.corpus)
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        return (vault,pairing,DesktopBridgeClient(pairing:pairing,token:token),try PrivateBridgeCache(pairingId:pairing.id))
    }
    private func base(_ values:[String:JSONValue]) throws -> JSONValue {
        guard let conversationId,!conversationId.isEmpty else { throw APIError(status:409,code:"chat_not_saved",message:"Guarda primero la conversación para consultar sus archivos.") }
        return .object(values.merging(["kind":.string(kind.rawValue),"conversationId":.string(conversationId)]) { _,new in new })
    }
    private func key(_ request:JSONValue,method:String) throws -> String {
        "companion:chat-reader:v1:"+SHA256.hash(data:try JSONEncoder.nodus.encode(.object(["request":request,"method":.string(method),"language":.string(Prompts.interfaceLanguage)]))).map{String(format:"%02x",$0)}.joined()
    }
    private func read(_ request:JSONValue,method:String) async throws -> JSONValue {
        let (vault,pairing,client,cache)=try connection(),key=try key(request,method:method)
        let prior=try await cache.data(vaultId:vault,domain:.corpus,recordId:key)
        let value:JSONValue
        do {
            value=try await client.operation(vaultId:vault,method:method,args:[request,.string(Prompts.interfaceLanguage)],timeout:request.objectValue?["action"] == .string("metadata") ? 4:75)
            guard try JSONEncoder.nodus.encode(value).count<=12*1024*1024 else { throw DesktopBridgeError.malformedResponse }
            let saved=try JSONEncoder.nodus.encode(JSONValue.object(["request":request,"value":value]));try await cache.store(saved,vaultId:vault,domain:.corpus,recordId:key);records[key]=saved.count
        } catch {
            guard isPrivateBridgeOffline(error),let prior else { throw error }
            let saved=try JSONDecoder.nodus.decode(JSONValue.self,from:prior)
            guard saved.objectValue?["request"]==request,let result=saved.objectValue?["value"],prior.count<=12*1024*1024+4096 else { throw DesktopBridgeError.malformedResponse }
            value=result;records[key]=prior.count
        }
        guard let required=value.objectValue?["requiredDomains"]?.arrayValue,required.contains(.string("corpus")),required.allSatisfy({ item in pairing.domains.contains(where:{$0.rawValue==item.stringValue}) }) else { throw DesktopBridgeError.permissionDenied }
        return value
    }
    func input(dark:Bool,textScale:Double) async throws -> JSONValue {
        guard !stopped,content.utf8.count<=20*1024*1024 else { throw DesktopBridgeError.malformedResponse }
        var legacy:[JSONValue]=[]
        let owner=try CompanionChatAssetRequest.owner(kind:kind,conversationId:conversationId ?? "",vaultId:session.vaultId ?? "")
        if session.connection.desktopPairingId != nil,conversationId != nil {
            do {
                let metadata=try await read(base(["action":.string("metadata")]),method:"getMobileChatReadResource")
                guard metadata.objectValue?["owner"] == .string(owner),let fences=metadata.objectValue?["legacyFences"]?.arrayValue,fences.count<=256,fences.allSatisfy({$0.stringValue != nil}) else { throw DesktopBridgeError.malformedResponse };legacy=fences
            } catch {
                // New local conversations can render prose before their first Mac
                // acknowledgement. Failed original assets still report their error.
                issue="No se ha podido actualizar el catálogo de lectores: \(error.localizedDescription)"
            }
        }
        let fields=desktopRecord?.objectValue ?? [:],record=JSONValue.object(fields.filter{["attachments","concilium","skills"].contains($0.key)})
        return .object(["content":.string(content),"language":.string(Prompts.interfaceLanguage),"dark":.bool(dark),"accent":.string(session.vaultType?.accentHex ?? "#6366f1"),"textScale":.number(textScale),"owner":.string(owner),"legacyFences":.array(legacy),"desktopRecord":record])
    }
    private func asset(_ source:String) async throws -> CompanionChatAsset {
        let (vault,pairing,client,cache)=try connection()
        guard let conversationId else { throw DesktopBridgeError.permissionDenied }
        let request=CompanionChatAssetRequest(kind:kind,conversationId:conversationId,source:source)
        let result=try await CompanionChatAsset.load(client:client,cache:cache,vaultId:vault,request:request,domains:Array(pairing.domains))
        records[try request.recordId]=try JSONEncoder.nodus.encode(result).count;return result
    }
    private func image(_ source:String) async throws -> ReaderImageSource.Content {
        if let saved=originalImages[source] { return saved }
        let key="companion:chat-reader-image:v1:"+SHA256.hash(data:Data(source.utf8)).map{String(format:"%02x",$0)}.joined()
        let connection=try? connection()
        let result:ReaderImageSource.Content
        do { result=try await ReaderImageSource.load(source,session:session) }
        catch {
            guard isPrivateBridgeOffline(error),let (vault,_,_,cache)=connection,let bytes=try await cache.data(vaultId:vault,domain:.corpus,recordId:key),let value=try JSONDecoder.nodus.decode(JSONValue.self,from:bytes).objectValue,let encoded=value["data"]?.stringValue,let data=Data(base64Encoded:encoded),let mime=value["mimeType"]?.stringValue,data.count<=ReaderImageSource.maximumBytes else { throw error }
            result=ReaderImageSource.Content(data:data,mime:mime)
        }
        guard result.data.count<=ReaderImageSource.maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        if let (vault,_,_,cache)=connection {
            if source.hasPrefix("nodus-image://") {
                let sourceKey=CompanionCorpusImage.recordId(source:source)
                guard let bytes=try await cache.data(vaultId:vault,domain:.corpus,recordId:sourceKey) else { throw PrivateBridgeCache.ReadPackError.invalidSelection };records[sourceKey]=bytes.count
            } else if source.hasPrefix("nodus-library://") || source.hasPrefix("nodus-archive://") {
                let sourceKey=CompanionEmbeddedResource.recordId(source:source)
                guard let bytes=try await cache.data(vaultId:vault,domain:.corpus,recordId:sourceKey) else { throw PrivateBridgeCache.ReadPackError.invalidSelection };records[sourceKey]=bytes.count
            } else {
                let stored=try JSONEncoder.nodus.encode(JSONValue.object(["data":.string(result.data.base64EncodedString()),"mimeType":.string(result.mime)]))
                records[key]=stored.count;try await cache.store(stored,vaultId:vault,domain:.corpus,recordId:key)
            }
        }
        // Original bytes remain bounded even when a long answer has many images.
        if originalImages.values.reduce(0,{$0+$1.data.count})+result.data.count>64*1024*1024 { originalImages.removeAll() }
        originalImages[source]=result;return result
    }
    func receive(_ message:WKScriptMessage) {
        guard !stopped,message.frameInfo.isMainFrame,let value=message.body as? [String:Any],let id=value["id"] as? String,id.count<=20,let method=value["method"] as? String,let args=value["args"] as? [Any],args.count<=4,tasks[id]==nil else { return }
        tasks[id]=Task { [weak self] in
            guard let self else { return };defer { tasks[id]=nil }
            do { let result=try await dispatch(method,args:args);try Task.checkCancellation();try await reply(id,result:result,error:nil) }
            catch { guard !Task.isCancelled,!stopped else { return };issue=error.localizedDescription;try? await reply(id,result:.null,error:error.localizedDescription) }
        }
    }
    private func reply(_ id:String,result:JSONValue,error:String?) async throws {
        guard !stopped,let webView else { return }
        let value=try JSONSerialization.jsonObject(with:JSONEncoder.nodus.encode(result),options:[.fragmentsAllowed])
        _=try await webView.callAsyncJavaScript("window.nodusChatReadReply(id,result,error);",arguments:["id":id,"result":value,"error":error as Any? ?? NSNull()],in:nil,contentWorld:.page)
    }
    private func dispatch(_ method:String,args:[Any]) async throws -> JSONValue {
        func string(_ index:Int) throws -> String { guard args.indices.contains(index),let value=args[index] as? String,value.utf8.count<=20*1024*1024 else { throw DesktopBridgeError.malformedResponse };return value }
        switch method {
        case "readError": issue=try string(0);return .null
        case "copyText": UIPasteboard.general.string=try string(0);return .null
        case "copyRenderedImage","shareRenderedImage":
            let encoded=try string(0),mime=try string(1)
            guard encoded.utf8.count<=12*1024*1024,["image/png","image/svg+xml"].contains(mime),let bytes=Data(base64Encoded:encoded),!bytes.isEmpty,bytes.count<=8*1024*1024 else { throw DesktopBridgeError.malformedResponse }
            if method=="copyRenderedImage" { guard mime=="image/png" else { throw DesktopBridgeError.malformedResponse };UIPasteboard.general.image=try ReaderRasterImage.preview(bytes) }
            else { guard mime=="image/svg+xml",let svg=String(data:bytes,encoding:.utf8),svg.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("<svg") else { throw DesktopBridgeError.malformedResponse };shareLease=try PrivateBridgeFileLease.write(bytes,filename:string(2)) };return .null
        case "openCitation":
            guard let url=URL(string:try string(0)),url.scheme=="nodus" else { throw DesktopBridgeError.malformedResponse }
            if url.host=="study",url.pathComponents.count==3,url.pathComponents[1]=="evidence",let ref=studyCitations.first(where:{$0.objectValue?["id"] == .string(url.lastPathComponent)}) { source = .study(ref) }
            else if url.host=="world",url.pathComponents.count==3 { source = .world("\(url.pathComponents[1]):\(url.lastPathComponent)") }
            else if let ref=CorpusReference(url) { source = .corpus(ref) }
            else { throw APIError(status:422,code:"citation_unavailable",message:"Esta referencia no contiene un destino compatible.") };return .null
        case "openExternal":
            guard let url=URL(string:try string(0)),["https","http"].contains(url.scheme),url.user==nil,url.password==nil else { throw DesktopBridgeError.malformedResponse };await UIApplication.shared.open(url);return .null
        case "readStoredArtifact":
            let source=try string(0)
            guard let conversationId,let vault=session.vaultId else { throw DesktopBridgeError.permissionDenied }
            try CompanionChatAssetRequest(kind:kind,conversationId:conversationId,source:source).validate(vaultId:vault,scheme:"nodus-artifact")
            func contains(_ value:JSONValue)->Bool {
                switch value { case .string(let text):text.contains(source);case .array(let values):values.contains(where:contains);case .object(let values):values.values.contains(where:contains);default:false }
            }
            guard content.contains(source)||desktopRecord.map(contains)==true else { throw DesktopBridgeError.permissionDenied }
            return try await read(base(["source":.string(source)]),method:"getMobileChatResultArtifact")
        case "readLegacyResult": return try await read(base(["action":.string("legacy"),"fence":.string(string(0)),"payload":.string(string(1))]),method:"getMobileChatReadResource")
        case "fetchCapabilityTile": return try await read(base(["action":.string("tile"),"capabilityId":.string(string(0)),"service":.string(string(1)),"path":.string(string(2))]),method:"getMobileChatReadResource")
        case "readCapabilityMedia","readCapabilityModel":
            let result=try await asset(string(0));return .object(["data":.string(result.data.base64EncodedString()),"mimeType":.string(result.descriptor.mime),"name":.string(result.descriptor.filename)])
        case "downloadCapabilityFile": let result=try await asset(string(0));previewLease=try PrivateBridgeFileLease.write(result.data,filename:result.descriptor.filename);return .null
        case "getChatImageMetadata":
            let source=try string(0)
            if source.hasPrefix("nodus-image://chat/") {
                let value=try await read(base(["action":.string("imageMetadata"),"source":.string(source)]),method:"getMobileChatReadResource")
                guard let metadata=value.objectValue?["metadata"],metadata.objectValue?.values.allSatisfy({$0.stringValue != nil})==true else { throw DesktopBridgeError.malformedResponse };return metadata
            }
            let image=try await image(source);return .object(["mimeType":.string(image.mime),"bytes":.string(String(image.data.count))])
        case "readImage":
            let image=try await image(string(0))
            if ["image/svg+xml","image/gif"].contains(image.mime) { return .object(["data":.string(image.data.base64EncodedString()),"mimeType":.string(image.mime)]) }
            guard let preview=try ReaderRasterImage.preview(image.data).jpegData(compressionQuality:0.9) else { throw DesktopBridgeError.malformedResponse }
            return .object(["data":.string(preview.base64EncodedString()),"mimeType":.string("image/jpeg")])
        case "copyChatImage": let image=try await image(string(0));UIPasteboard.general.image=try ReaderRasterImage.preview(image.data);return .null
        case "downloadOriginalImage":
            let image=try await image(string(0)),suffix=["image/png":"png","image/jpeg":"jpg","image/gif":"gif","image/svg+xml":"svg","image/webp":"webp","image/avif":"avif"][image.mime]
            guard let suffix else { throw DesktopBridgeError.malformedResponse };shareLease=try PrivateBridgeFileLease.write(image.data,filename:"Nodus-image.\(suffix)");return .null
        default: throw APIError(status:403,code:"reader_action_forbidden",message:"Esta acción no está disponible en la vista de lectura.")
        }
    }
    func download(days:Int) async throws {
        guard !stopped,!loading,[7,30].contains(days),let webView else { throw DesktopBridgeError.malformedResponse }
        let (vault,_,_,cache)=try connection()
        let raw=try await webView.callAsyncJavaScript("return await window.nodusChatReadDownload();",arguments:[:],in:nil,contentWorld:.page)
        guard let result=raw as? [String:Any],let sources=result["sources"] as? [String],sources.count<=128 else { throw DesktopBridgeError.malformedResponse }
        for source in sources { try Task.checkCancellation();if source.hasPrefix("nodus-capability://")||source.hasPrefix("nodus-attachment://") { _=try await asset(source) } else { _=try await image(source) } }
        let body=try JSONEncoder.nodus.encode(JSONValue.object(["content":.string(content),"kind":.string(kind.rawValue),"conversationId":conversationId.map(JSONValue.string) ?? .null,"desktopRecord":desktopRecord ?? .null]))
        let bodyKey="companion:chat-answer:v1:"+SHA256.hash(data:body).map{String(format:"%02x",$0)}.joined()
        guard records.values.reduce(0,+)+content.utf8.count<=50*1024*1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        var selected:[String:Data]=[bodyKey:body]
        for key in records.keys {
            guard let saved=try await cache.data(vaultId:vault,domain:.corpus,recordId:key) else { throw PrivateBridgeCache.ReadPackError.invalidSelection };selected[key]=saved
        }
        guard selected.values.reduce(0,{$0+$1.count})<=50*1024*1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        let id=try PrivateBridgeCache.readPackSelectionId(vaultId:vault,recordIds:[bodyKey])
        let existing=try await cache.readPacks(vaultId:vault).filter{$0.title.hasPrefix("Respuesta ·")&&$0.id != id}.reduce(0,{$0+$1.bytes})
        guard existing+selected.values.reduce(0,{$0+$1.count})<=50*1024*1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        try Task.checkCancellation()
        let expiry=Date().addingTimeInterval(Double(days)*86400)
        _=try await cache.saveReadPack(id:id,vaultId:vault,title:"Respuesta · \(content.prefix(60))",expiresAt:expiry,records:selected.map{PrivateBridgeCache.ReadPackRecord(domain:.corpus,recordId:$0.key,data:$0.value)})
        if let conversationId { try ChatHistoryStore.shared(spaceId:session.connection.storageId).retainTemporaryDownload(conversationId,until:expiry) }
    }
}

private struct RichChatFileView:View {
    let lease:PrivateBridgeFileLease,accent:Color
    @Environment(\.dismiss) private var dismiss
    @State private var sharing=false
    var body:some View {
        NavigationStack {
            Group {
                if QLPreviewController.canPreview(lease.url as NSURL) { RichChatFilePreview(lease:lease) }
                else { ContentUnavailableView("Archivo original",systemImage:"doc",description:Text("Puedes compartirlo para abrirlo con una aplicación compatible.")) }
            }.navigationTitle(lease.url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Listo") { dismiss() } };ToolbarItem(placement:.primaryAction) { Button { sharing=true } label: { Image(systemName:"square.and.arrow.up").frame(width:44,height:44) }.accessibilityLabel("Compartir archivo original") } }
                .sheet(isPresented:$sharing) { ReaderImageShareSheet(lease:lease) }
        }.tint(accent)
    }
}
private struct RichChatFilePreview:UIViewControllerRepresentable {
    let lease:PrivateBridgeFileLease
    func makeCoordinator()->Coordinator { Coordinator(lease) }
    func makeUIViewController(context:Context)->QLPreviewController { let controller=QLPreviewController();controller.dataSource=context.coordinator;return controller }
    func updateUIViewController(_ view:QLPreviewController,context:Context) {}
    final class Coordinator:NSObject,QLPreviewControllerDataSource {
        let lease:PrivateBridgeFileLease
        init(_ lease:PrivateBridgeFileLease) { self.lease=lease }
        func numberOfPreviewItems(in controller:QLPreviewController)->Int { 1 }
        func previewController(_ controller:QLPreviewController,previewItemAt index:Int)->any QLPreviewItem { lease.url as NSURL }
    }
}

private struct RichChatWebReader:UIViewRepresentable {
    let reader:RichChatReader,dark:Bool,textScale:Double
    func makeCoordinator()->Coordinator { Coordinator(reader:reader,dark:dark,textScale:textScale) }
    func makeUIView(context:Context)->WKWebView {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator,name:"chatRead")
        let images=MobileCorpusImageScheme(session:reader.session) { [weak reader] in reader?.issue=$0 };context.coordinator.images=images
        for scheme in ["nodus-image","nodus-library","nodus-archive"] { config.setURLSchemeHandler(images,forURLScheme:scheme) }
        let view=WKWebView(frame:.zero,configuration:config);view.isOpaque=false;view.backgroundColor = .systemBackground;view.navigationDelegate=context.coordinator;reader.webView=view
        guard let url=Bundle.main.url(forResource:"chat-read",withExtension:"html",subdirectory:"SharedDesktop") else { reader.loading=false;reader.issue="El lector compartido no está incluido en esta compilación.";return view }
        context.coordinator.root=url;context.coordinator.deadline=Task { @MainActor [weak reader] in do { try await Task.sleep(for:.seconds(20));guard let reader,reader.loading else { return };reader.loading=false;reader.issue="El lector no ha podido iniciarse. Vuelve a cargar la respuesta." } catch {} }
        view.loadFileURL(url,allowingReadAccessTo:url.deletingLastPathComponent());return view
    }
    func updateUIView(_ view:WKWebView,context:Context) {
        let coordinator=context.coordinator
        guard coordinator.dark != dark || coordinator.textScale != textScale else { return };coordinator.dark=dark;coordinator.textScale=textScale
        guard !reader.loading else { return };Task { await coordinator.render(view) }
    }
    static func dismantleUIView(_ view:WKWebView,coordinator:Coordinator) { coordinator.deadline?.cancel();coordinator.images?.cancelAll();coordinator.reader.stop();view.configuration.userContentController.removeScriptMessageHandler(forName:"chatRead");view.navigationDelegate=nil }
    @MainActor final class Coordinator:NSObject,WKNavigationDelegate,WKScriptMessageHandler {
        let reader:RichChatReader
        var dark:Bool,textScale:Double,root:URL?,deadline:Task<Void,Never>?,images:MobileCorpusImageScheme?
        init(reader:RichChatReader,dark:Bool,textScale:Double) { self.reader=reader;self.dark=dark;self.textScale=textScale }
        func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) { reader.receive(message) }
        func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { Task { await render(webView) } }
        func render(_ view:WKWebView) async {
            do { let value=try await reader.input(dark:dark,textScale:textScale);try Task.checkCancellation();let input=try JSONSerialization.jsonObject(with:JSONEncoder.nodus.encode(value));_=try await view.callAsyncJavaScript("window.nodusChatReadRender(input);",arguments:["input":input],in:nil,contentWorld:.page);reader.loading=false;deadline?.cancel() }
            catch { reader.loading=false;reader.issue=error.localizedDescription;deadline?.cancel() }
        }
        func webView(_ view:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) { decisionHandler(action.request.url==root ? .allow:.cancel) }
        func webView(_ view:WKWebView,didFail navigation:WKNavigation!,withError error:any Error) { reader.loading=false;reader.issue=error.localizedDescription;deadline?.cancel() }
        func webView(_ view:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:any Error) { reader.loading=false;reader.issue=error.localizedDescription;deadline?.cancel() }
        func webViewWebContentProcessDidTerminate(_ view:WKWebView) { reader.loading=false;reader.issue="El lector se ha detenido. Vuelve a cargar la respuesta.";deadline?.cancel() }
    }
}
