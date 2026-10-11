import CryptoKit
import NodusKit
import NodusUI
import SwiftUI
import WebKit
import QuickLook

enum DesktopSurface: String { case graph, dictionary, workspace, page, databasePresentation, argument, deepResearch, databaseResearch, immersion, chat, writingWorkshop }

private struct MobileWritingResultTarget: Identifiable {
    let request: DesktopJobLedger.Request
    let checkpoint: JSONValue
    var id: String { request.id }
}

enum MobileSurfaceVaultContext {
    static func descriptor(connection: AppModel.Connection, vault: VaultDescriptor?) -> VaultDescriptor {
        if connection.desktopPairingId != nil {
            let matchingVault = vault?.id == connection.vaultId ? vault : nil
            return VaultDescriptor(id: connection.vaultId, name: matchingVault?.name ?? connection.vaultName,
                type: matchingVault?.type ?? connection.vaultType)
        }
        return VaultDescriptor(id: vault?.id ?? connection.vaultId,
            name: vault?.name ?? connection.vaultName, type: vault?.type ?? connection.vaultType)
    }
}

/// A published space has its own local draft identity. It is never a substitute
/// for a Mac pairing or a private-vault grant.
struct MobileSurfaceStorageScope: Equatable {
    let cacheId: String
    let recordVaultId: String

    init(connectionId: String, pairingId: String?, vaultId: String?) throws {
        if let pairingId {
            guard let vaultId, !vaultId.isEmpty else { throw DesktopBridgeError.permissionDenied }
            cacheId = pairingId
            recordVaultId = vaultId
        } else {
            guard !connectionId.isEmpty else { throw DesktopBridgeError.malformedResponse }
            let identity = SHA256.hash(data: Data(connectionId.utf8)).map { String(format: "%02x", $0) }.joined()
            cacheId = "local-surface-\(identity)"
            recordVaultId = "published-space-\(identity)"
        }
    }
}

extension SpaceSession {
    func surfaceStorageScope() throws -> MobileSurfaceStorageScope {
        try MobileSurfaceStorageScope(connectionId: connection.id,
            pairingId: connection.desktopPairingId, vaultId: vaultId)
    }
}

/// Locally bundled Desktop components; credentials and network access stay in Swift.
struct SharedDesktopSurface: View {
    let session: SpaceSession
    let surface: DesktopSurface
    var initialDatabaseReportId: String? = nil
    var initialPageId: String? = nil
    var initialArgumentMap: JSONValue? = nil
    var initialArgumentSeed: String? = nil
    var initialDatabasePresentation: JSONValue? = nil
    var onOpenDatabaseRow: ((String) -> Void)? = nil
    var pageDownloadedOnly = false
    @Environment(AISettings.self) private var ai
    @Environment(\.colorScheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var destination: SurfaceDestination?
    @State private var citation: CorpusReference?
    @State private var sourceDocument: SourceDocumentTarget?
    @State private var nativeReport: SurfaceDestination?
    @State private var issue: String?
    @State private var surfaceMounted = false
    @State private var reloadRevision = 0
    @State private var exportedURL: URL?
    @State private var exportedLease: PrivateBridgeFileLease?
    @State private var embeddedPreview: URL?
    @State private var embeddedLease: PrivateBridgeFileLease?
    @State private var openingEmbeddedResource = false
    @State private var savedAudio: SavedAudioTarget?
    @State private var writingResult: MobileWritingResultTarget?
    @State private var autonomousStatus: String?
    @State private var offlineCopy = false
    @State private var immersionController: ImmersionProgressController?
    @State private var immersionPlan: ImmersionPlan?
    @State private var showImmersionProgress = false

    var body: some View {
        DesktopWebView(session: session, ai: ai, surface: surface, dark: theme == .dark, textScale: ReadingStyle.sharedSurfaceScale(for: textSize), publicationRevision: session.companionPublicationRevision, corpusRevision: session.publishedRevision, databaseReadingRevision:session.companionDatabaseReadingRevision, initialDatabaseReportId:initialDatabaseReportId, initialPageId:initialPageId, initialArgumentMap:initialArgumentMap, initialArgumentSeed:initialArgumentSeed, initialDatabasePresentation:initialDatabasePresentation, pageDownloadedOnly:pageDownloadedOnly, onReady: { surfaceMounted = true }, onError: { surfaceMounted = true; issue = $0 }, onExport: { exportedLease = $0;exportedURL = $0.url }, onAutonomousStatus: { autonomousStatus = $0 }, onOfflineCopy: { offlineCopy = $0 }, onOpenSource: { sourceDocument = $0 }, onOpenAudio: { savedAudio = $0 }, onOpenWritingResult: { writingResult = $0 }, onImmersionSource: { id, source in
            do {
                guard let plan = ImmersionPlan(Row(["plan": source])) else { throw DesktopBridgeError.malformedResponse }
                let controller = try ImmersionProgressController(session: session, sessionId: id, plan: plan)
                immersionPlan = plan; immersionController = controller
                Task { await controller.load(fetchMacProgress: false) }
            } catch { issue = error.localizedDescription }
        }) { kind, id, location, quote in
            if kind == "databaseRow", let onOpenDatabaseRow { onOpenDatabaseRow(id); return }
            if kind == "pageAsset" {
                guard id.count == 64, id.allSatisfy(\.isHexDigit), !openingEmbeddedResource else { return }
                openingEmbeddedResource = true
                Task { @MainActor in
                    defer { openingEmbeddedResource = false }
                    do { let copy = try await loadPrivateBridgeFile(session, kind: .pageAsset, id: id, downloadedOnly:pageDownloadedOnly); embeddedLease = copy.lease; embeddedPreview = copy.url }
                    catch { issue = error.localizedDescription }
                }; return
            }
            if kind == "deepResearchReport" {
                guard surface == .deepResearch, !id.isEmpty, id.utf8.count <= 1024 else { issue = "El informe solicitado no tiene una identidad válida."; return }
                nativeReport = SurfaceDestination(path: "deep-research", id: id, location: nil, quote: nil); return
            }
            if kind == "citation" {
                guard let url = URL(string:id), let reference = CorpusReference(url) else { issue = "No se pudo abrir la fuente de esta cita."; return }
                citation = reference; return
            }
            if kind == "section" {
                guard NodusRoute(rawValue:id) != nil else { issue = "La sección solicitada no está disponible."; return }
                NotificationCenter.default.post(name:.nodusMobileNavigate,object:nil,userInfo:["connectionId":session.connection.id,"route":id]); return
            }
            if kind == "embeddedResource" {
                guard !openingEmbeddedResource else { return }
                openingEmbeddedResource = true
                Task { @MainActor in
                    defer { openingEmbeddedResource = false }
                    do {
                        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
                        let resource = try await CompanionEmbeddedResource.load(client:DesktopBridgeClient(pairing:pairing,token:token),cache:PrivateBridgeCache(pairingId:pairing.id),vaultId:vault,source:id,domains:Array(pairing.domains))
                        let lease = try PrivateBridgeFileLease.write(resource.data,filename:resource.descriptor.filename)
                        embeddedLease = lease; embeddedPreview = lease.url
                    } catch { issue = error.localizedDescription }
                }
                return
            }
            let path = kind == "databaseRow" ? "database-rows" : kind == "page" ? "pages" : kind == "studyMaterial" ? "study-materials" : kind == "studyDocument" ? "study-docs"
                : kind == "idea" ? "ideas" : kind == "author" ? "authors" : "works"
            destination = SurfaceDestination(path: path, id: id, location: location, quote: quote)
        }
        .id("\(session.connection.id):\(surface.rawValue):\(session.aiExecutionMode.rawValue):\(reloadRevision)")
        .overlay {
            if !surfaceMounted, issue == nil {
                ProgressView("Cargando Nodus…").tint(session.accent)
                    .accessibilityIdentifier("shared-surface-loading")
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
            if let issue {
                HStack(alignment: .top, spacing: 8) {
                    Text(issue).font(.caption).foregroundStyle(Color.nodusDanger)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("shared-surface-error")
                    Button("Reintentar") { self.issue = nil; surfaceMounted = false; reloadRevision += 1 }
                        .frame(minHeight: 44).accessibilityIdentifier("shared-surface-retry")
                    Button { self.issue = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Cerrar aviso")
                }.padding(.leading, 12).padding(.vertical, 4).background(.thinMaterial)
            }
            CompanionResultsButton(session: session, surface: surface, generationStatus: autonomousStatus)
            if surface == .databaseResearch { DatabaseReadingStatusButton(session:session) }
            if surface == .immersion, let controller = immersionController {
                Button { showImmersionProgress = true } label: {
                    Label(controller.state == .conflict ? "Revisar progreso de inmersión" : controller.state == .pending ? "Progreso guardado · pendiente de sincronizar" : "Progreso de inmersión",
                        systemImage: controller.state == .conflict || controller.state == .blocked ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle")
                        .font(.caption).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.horizontal, 12).background(.thinMaterial).accessibilityIdentifier("shared-immersion-private-progress")
            }
            if offlineCopy {
                Label("Sin conexión · contenido de este dispositivo", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial)
                    .accessibilityIdentifier("shared-surface-offline-copy")
            }
            if let autonomousStatus {
                Text(autonomousStatus).font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.thinMaterial).accessibilityIdentifier("autonomous-job-status")
            }
            }
        }
        .sheet(item: $exportedURL,onDismiss:{ exportedLease = nil }) { ActivityShareSheet(items: [$0]) }
        .quickLookPreview($embeddedPreview)
        .onChange(of:embeddedPreview) { _, value in if value == nil { embeddedLease = nil } }
        .sheet(isPresented: $showImmersionProgress) {
            NavigationStack {
                if let controller = immersionController, let plan = immersionPlan {
                    ScrollView { ImmersionProgressStatus(controller: controller, questions: plan.stations.flatMap(\.quiz) + plan.exam,
                        totalSteps: plan.stations.count + 4, accent: session.accent).padding() }
                        .navigationTitle(plan.title).navigationBarTitleDisplayMode(.inline).nodusModalClose(accent: session.accent)
                }
            }.presentationDetents([.large]).presentationDragIndicator(.visible)
        }
        .onChange(of: session.companionImmersionProgressRevision) { _, _ in Task { await immersionController?.reloadLocal() } }
        .sheet(item: $writingResult) { target in
            NavigationStack {
                CompanionGeneratedResultView(session: session, request: target.request, checkpoint: target.checkpoint)
                    .nodusModalClose(accent: session.accent)
            }
            .presentationDetents([.fraction(0.68), .large])
            .presentationDragIndicator(.visible)
            .environment(\.dynamicTypeSize, textSize)
            .nodusTextHierarchy()
        }
        .sheet(item: $savedAudio) { target in
            NavigationStack { SavedAudioPlayer(target: target, accent: session.accent).nodusModalClose(accent: session.accent) }
                .environment(\.dynamicTypeSize, textSize)
        }
        .sheet(item: $sourceDocument) { target in
            NavigationStack { SourceDocumentReader(session: session, target: target).nodusModalClose(accent: session.accent) }
                .modifier(SourceReaderSheetSizing())
                .environment(\.dynamicTypeSize, textSize)
                .nodusTextHierarchy()
        }
        .nodusSheet(item: $nativeReport) { target in
            NavigationStack {
                PublishedReportReader(session: session, row: Row(["id": .string(target.id)]))
                    .nodusModalClose(accent: session.accent)
            }
            .environment(\.dynamicTypeSize, textSize)
            .nodusTextHierarchy()
        }
        .sheet(item: $destination) { target in
            NavigationStack {
                Group {
                    if target.path == "pages" {
                        SharedDesktopSurface(session: session, surface: .page, initialPageId: target.id, pageDownloadedOnly:pageDownloadedOnly)
                    } else if target.path == "database-rows" {
                        DatabaseLinkedRowReader(session:session,id:target.id,downloadedOnly:pageDownloadedOnly)
                    } else if target.path == "study-docs" {
                        StudyEvidenceDocument(session: session, id: target.id, location: target.location, quote: target.quote)
                    } else {
                        RowDetailView(session: session, collection: Collections.byPath[target.path],
                            row: Row([Collections.byPath[target.path]?.idField ?? "id": .string(target.id)]))
                    }
                }.nodusModalClose(accent: session.accent)
            }
            .environment(\.dynamicTypeSize, textSize)
            .nodusTextHierarchy()
        }
        .sheet(item:$citation) { reference in
            NavigationStack { CorpusReferenceView(session:session,reference:reference).nodusModalClose(accent:session.accent) }
                .environment(\.dynamicTypeSize,textSize).nodusTextHierarchy()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shared-desktop-\(surface.rawValue)")
    }
}

private struct SourceReaderSheetSizing: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.presentationSizing(.page) }
        else { content.presentationDetents([.large]) }
    }
}

private struct SurfaceDestination: Identifiable { let path: String; let id: String; let location: String?; let quote: String? }

private struct StudyEvidenceDocument: View {
    let session: SpaceSession
    let id: String
    let location: String?
    let quote: String?
    @State private var row: Row?
    @State private var error: String?
    @Environment(AppPreferences.self) private var preferences
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let row {
                        Text(row.text("title") ?? "").font(.title2.weight(.semibold)).textSelection(.enabled)
                        if let location { Text(location).font(.caption).foregroundStyle(session.accent) }
                        CorpusProse(row.text("content_markdown") ?? "", accent: session.accent, session: session)
                    } else if let error { Text(error).foregroundStyle(.red) }
                    else { ProgressView() }
                }.padding(20).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 76) }
            .task(id: row?.text("content_markdown")) {
                guard let markdown = row?.text("content_markdown"), let quote,
                    let anchor = CorpusProse(markdown, accent: session.accent, session: session).anchor(containing: quote) else { return }
                await Task.yield()
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
        .nodusReadingStyle(ReadingStyle(scale: preferences.readingScale, document: true))
        .navigationTitle(row?.text("title") ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ReadingSizeButtons(accent: session.accent) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("study-evidence-reader")
        .task {
            do {
                guard let collection = Collections.byPath["study-docs"] else { throw DesktopBridgeError.malformedResponse }
                row = try await session.client.item(collection, id: id, in: session.connection.spaceId)
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Preserve native selection handles and the keyboard's editing commands. Only
/// a selection handled by the document's Nodus ribbon replaces the system menu.
private final class ReaderSurfaceWebView: WKWebView {
    var readerSelectionManaged = false
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        if readerSelectionManaged { builder.replaceChildren(ofMenu: .root) { _ in [] } }
    }
    func dismissReaderEditMenu() {
        func dismiss(in view: UIView) {
            for interaction in view.interactions {
                (interaction as? UIEditMenuInteraction)?.dismissMenu()
            }
            view.subviews.forEach { dismiss(in: $0) }
        }
        dismiss(in: self)
    }
}

private struct DesktopWebView: UIViewRepresentable {
    @Environment(\.nodusResidentRouteActive) private var routeActive
    let session: SpaceSession
    let ai: AISettings
    let surface: DesktopSurface
    let dark: Bool
    let textScale: Double
    let publicationRevision: Int
    let corpusRevision: String?
    let databaseReadingRevision:Int
    let initialDatabaseReportId: String?
    let initialPageId: String?
    let initialArgumentMap: JSONValue?
    let initialArgumentSeed: String?
    let initialDatabasePresentation: JSONValue?
    let pageDownloadedOnly: Bool
    let onReady: () -> Void
    let onError: (String) -> Void
    let onExport: (PrivateBridgeFileLease) -> Void
    let onAutonomousStatus: (String?) -> Void
    let onOfflineCopy: (Bool) -> Void
    let onOpenSource: (SourceDocumentTarget) -> Void
    let onOpenAudio: (SavedAudioTarget) -> Void
    let onOpenWritingResult: (MobileWritingResultTarget) -> Void
    let onImmersionSource: (String, JSONValue) -> Void
    let onNavigate: (String, String, String?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session, ai: ai, pageDownloadedOnly:pageDownloadedOnly, onReady: onReady, onError: onError, onExport: onExport, onAutonomousStatus: onAutonomousStatus, onOfflineCopy: onOfflineCopy, onOpenSource: onOpenSource, onOpenAudio: onOpenAudio, onOpenWritingResult: onOpenWritingResult, onImmersionSource: onImmersionSource, onNavigate: onNavigate) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(context.coordinator.images,forURLScheme:"nodus-image")
        config.setURLSchemeHandler(context.coordinator.images,forURLScheme:"nodus-library")
        config.setURLSchemeHandler(context.coordinator.images,forURLScheme:"nodus-archive")
        config.userContentController.add(context.coordinator, name: "nodus")
        var data: [String: Any] = ["surface": surface.rawValue, "pageDownloadedOnly":pageDownloadedOnly, "initialPageId":initialPageId ?? "", "initialDatabaseReportId":initialDatabaseReportId ?? "", "live": session.connection.desktopPairingId != nil, "executionMode": session.aiExecutionMode.rawValue,
            "device": UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "tablet",
            "theme": dark ? "dark" : "light", "accent": session.vaultType?.accentHex ?? "#6366f1", "textScale": textScale, "vaultType": session.vaultType?.rawValue ?? "academic", "language": Locale.current.language.languageCode?.identifier ?? "es"]
        if let initialArgumentMap, let bytes = try? JSONEncoder.nodus.encode(initialArgumentMap), let value = try? JSONSerialization.jsonObject(with: bytes) { data["initialArgumentMap"] = value }
        if let initialArgumentSeed { data["initialArgumentSeed"] = initialArgumentSeed }
        if let initialDatabasePresentation, let bytes = try? JSONEncoder.nodus.encode(initialDatabasePresentation), let value = try? JSONSerialization.jsonObject(with: bytes) { data["initialDatabasePresentation"] = value }
        if let json = try? JSONSerialization.data(withJSONObject: data), let text = String(data: json, encoding: .utf8) {
            let bootstrap = """
            window.nodusMobileConfig=\(text);
            window.nodusMobileSubscriptions=new Map();
            window.nodusMobilePending=new Map();window.nodusMobileSequence=0;
            window.nodusMobileCall=(method,...args)=>new Promise((resolve,reject)=>{
              const id=String(++window.nodusMobileSequence);window.nodusMobilePending.set(id,{resolve,reject});
              window.webkit.messageHandlers.nodus.postMessage({id,method,args});
            });
            window.nodusMobileReply=(id,result,error)=>{const p=window.nodusMobilePending.get(id);if(!p)return;window.nodusMobilePending.delete(id);if(error){const failure=new Error(typeof error==='string'?error:error.message);if(typeof error==='object')failure.code=error.code;if(error.code==='cancelled')failure.name='AbortError';p.reject(failure)}else p.resolve(result)};
            window.nodusMobileEvent=()=>{};
            window.nodus=new Proxy({}, {get:(_,method)=>{
              if(method.startsWith('on'))return listener=>{const s=window.nodusMobileSubscriptions.get(method)||new Set();s.add(listener);window.nodusMobileSubscriptions.set(method,s);return()=>s.delete(listener)};
              return (...args)=>window.nodusMobileCall(method,...args);
            }});
            window.addEventListener('error',e=>window.webkit.messageHandlers.nodus.postMessage({id:'error',method:'surfaceError',args:[String(e.message)]}));
            window.addEventListener('unhandledrejection',e=>window.webkit.messageHandlers.nodus.postMessage({id:'error',method:'surfaceError',args:[String(e.reason)]}));
            """
            config.userContentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let view = ReaderSurfaceWebView(frame: .zero, configuration: config)
        view.accessibilityElementsHidden = !routeActive
        view.isHidden = !routeActive
        view.isOpaque = false
        view.scrollView.keyboardDismissMode = .interactive
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.setRouteActive(routeActive)
        if let resource = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "SharedDesktop") {
            let script = resource.deletingLastPathComponent().appendingPathComponent("surface.iife.js")
            do {
                let javascript = try String(contentsOf: script, encoding: .utf8)
                let guarded = "try {\n" + javascript + "\n} catch(e) { window.webkit.messageHandlers.nodus.postMessage({id:'error',method:'surfaceError',args:[String(e.message || e)]}); }"
                config.userContentController.addUserScript(WKUserScript(source: guarded, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

            } catch { context.coordinator.onError(error.localizedDescription) }
            context.coordinator.tasks.append(Task {
                do {
                    let stored = try await context.coordinator.surfaceStorage()
                    let seed = String(decoding: try JSONEncoder.nodus.encode(stored), as: UTF8.self)
                    let storage = """
                    (()=>{
                      const values=new Map(Object.entries(\(seed)));
                      let sequence=0;
                      const persist=()=>window.webkit.messageHandlers.nodus.postMessage({id:'storage-'+(++sequence),method:'persistSurfaceStorage',args:[Object.fromEntries(values)]});
                      const storage={getItem:key=>values.get(String(key))??null,
                        setItem:(key,value)=>{values.set(String(key),String(value));persist()},
                        removeItem:key=>{values.delete(String(key));persist()},
                        clear:()=>{values.clear();persist()},key:index=>[...values.keys()][index]??null,
                        get length(){return values.size}};
                      Object.defineProperty(window,'localStorage',{get:()=>storage});
                    })();
                    """
                    config.userContentController.addUserScript(WKUserScript(source: storage, injectionTime: .atDocumentStart, forMainFrameOnly: true))
                    let document = try await LocalSurfaceHost.shared.documentURL()
                    try Task.checkCancellation()
                    view.load(URLRequest(url: document))
                }
                catch is CancellationError { }
                catch { context.coordinator.onError(error.localizedDescription) }
            })
        } else {
            view.loadHTMLString("<main role='alert'>Nodus shared components are missing. Rebuild the application.</main>", baseURL: nil)
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        view.accessibilityElementsHidden = !routeActive
        // WebKit publishes its contents from a separate process. Hiding only
        // the container's accessibility descendants leaves stale HTML controls
        // reachable after switching workspaces.
        view.isHidden = !routeActive
        context.coordinator.setRouteActive(routeActive)
        context.coordinator.sendPublicationUpdates()
        context.coordinator.sendCorpusUpdate()
        context.coordinator.sendDatabaseReadingUpdate()
        view.evaluateJavaScript("document.documentElement.classList.toggle('dark',\(dark));document.documentElement.classList.toggle('light',\(!dark));document.documentElement.style.fontSize='\(16 * textScale)px';document.documentElement.style.setProperty('--nodus-mobile-text-scale','\(textScale)');", completionHandler: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "nodus")
        coordinator.tasks.forEach { $0.cancel() }
        coordinator.images.cancelAll()
        coordinator.finishJavaScriptPanel()
        coordinator.session.isSurfaceFullscreen = false
    }
    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        private var javaScriptPanel: UIAlertController?
        private var cancelJavaScriptPanel: (() -> Void)?
        private static let operationDomains: [String: String] = {
            guard let file = Bundle.main.url(forResource: "operations", withExtension: "json", subdirectory: "SharedDesktop"),
                let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let methods = object["operations"] as? [String: [String]] else { return [:] }
            return methods.mapValues { $0.count == 2 ? $0[1] : "unavailable" }
        }()
        weak var webView: WKWebView?
        private var routeActive = true
        func setRouteActive(_ active: Bool) {
            routeActive = active
            // The remote WebKit accessibility process can outlive UIKit's hidden
            // container. Inert removes its HTML controls from focus and VoiceOver
            // without destroying the canvas, draft or scroll position.
            webView?.evaluateJavaScript("if(document.documentElement){document.documentElement.inert=\(!active);if(\(!active))document.activeElement?.blur();}", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            setRouteActive(routeActive)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            navigationFailed(error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            navigationFailed(error)
        }
        private func navigationFailed(_ error: any Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            surfaceReady = false
            onError("No se pudo cargar esta vista: \(error.localizedDescription)")
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            surfaceReady = false
            onError("La vista se ha interrumpido. Reintenta para recuperar el contenido guardado.")
        }
        let session: SpaceSession
        let pageDownloadedOnly:Bool
        let autonomous: AutonomousSurfaceProvider
        let onNavigate: (String, String, String?, String?) -> Void
        let onReady: () -> Void
    let onError: (String) -> Void
            let onExport: (PrivateBridgeFileLease) -> Void
        let onAutonomousStatus: (String?) -> Void
        let onOfflineCopy: (Bool) -> Void
        let onOpenSource: (SourceDocumentTarget) -> Void
        let onOpenAudio: (SavedAudioTarget) -> Void
        let onOpenWritingResult: (MobileWritingResultTarget) -> Void
        let onImmersionSource: (String, JSONValue) -> Void
        private lazy var immersionProgress = ImmersionSurfaceProgressBridge(session: session)
        private lazy var databaseReading = DatabaseResearchSurfaceBridge(session:session,localReader:{ [weak self] id in
            guard let self else { return nil };return try await self.autonomous.databaseLocalReader(id,session:self.session)
        })
        private var databaseReadingRevision = 0
        func sendDatabaseReadingUpdate() {
            guard surfaceReady,routeActive,databaseReadingRevision != session.companionDatabaseReadingRevision else { return }
            databaseReadingRevision = session.companionDatabaseReadingRevision
            webView?.evaluateJavaScript("window.nodusMobileEvent({channel:'mobile:databaseReading:changed',args:[]});",completionHandler:nil)
        }
        lazy var images = MobileCorpusImageScheme(session:session,onError:onError)
        var tasks: [Task<Void, Never>] = []
        var runningJobs: [String: (DesktopBridgeClient, String, String)] = [:]
        private var persistedSurfaceCache: PrivateBridgeCache?
        private var publicationRevision = 0
        private var surfaceReady = false
        private var autonomousGenerationId: String?
        private var corpusRevision: String?
        func sendCorpusUpdate() {
            guard surfaceReady, routeActive, session.connection.desktopPairingId != nil,
                  corpusRevision != session.publishedRevision else { return }
            corpusRevision = session.publishedRevision
            webView?.evaluateJavaScript("window.nodusMobileEvent?.({channel:'mobile:corpus:changed',args:[]});", completionHandler: nil)
        }
        func sendPublicationUpdates() {
            guard surfaceReady, routeActive, publicationRevision != session.companionPublicationRevision,
                  let data = try? JSONEncoder.nodus.encode(session.companionPublicationUpdates) else { return }
            publicationRevision = session.companionPublicationRevision
            let payload = String(decoding: data, as: UTF8.self)
            webView?.evaluateJavaScript("window.nodusMobileEvent?.({channel:'mobile:publication:changed',args:[\(payload)]});", completionHandler: nil)
            if session.companionPublicationUpdates.contains(where: { $0.objectValue?["id"]?.stringValue == autonomousGenerationId && $0.objectValue?["state"] == .string("available") }) { onAutonomousStatus(nil) }
        }
        init(session: SpaceSession, ai: AISettings, pageDownloadedOnly:Bool, onReady: @escaping () -> Void, onError: @escaping (String) -> Void, onExport: @escaping (PrivateBridgeFileLease) -> Void, onAutonomousStatus: @escaping (String?) -> Void, onOfflineCopy: @escaping (Bool) -> Void, onOpenSource: @escaping (SourceDocumentTarget) -> Void, onOpenAudio: @escaping (SavedAudioTarget) -> Void, onOpenWritingResult: @escaping (MobileWritingResultTarget) -> Void, onImmersionSource: @escaping (String, JSONValue) -> Void, onNavigate: @escaping (String, String, String?, String?) -> Void) { self.session = session; self.pageDownloadedOnly=pageDownloadedOnly; autonomous = AutonomousSurfaceProvider(settings: ai); self.onReady = onReady; self.onError = onError; self.onExport = onExport; self.onAutonomousStatus = onAutonomousStatus; self.onOfflineCopy = onOfflineCopy; self.onOpenSource = onOpenSource; self.onOpenAudio = onOpenAudio; self.onOpenWritingResult = onOpenWritingResult; self.onImmersionSource = onImmersionSource; self.onNavigate = onNavigate }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                let id = body["id"] as? String, let method = body["method"] as? String,
                let input = body["args"] as? [Any], JSONSerialization.isValidJSONObject(input) else { return }
                        if method == "surfaceError", let error = input.first as? String { onError(error); return }
            if method == "surfaceMounted" {
                surfaceReady = true
                onReady()
                sendPublicationUpdates(); sendCorpusUpdate(); sendDatabaseReadingUpdate()
                try? reply(id, value: .null, error: nil)
                return
            }
            tasks.append(Task {
                do {
                    var args = try JSONDecoder.nodus.decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: input))
                    let pageReads=["getPageDocument","getPageAsset","getSyncedBlockSource","getDatabaseContainer","queryDatabaseContainerRows"]
                    var selectedPageOnly=pageDownloadedOnly
                    if pageReads.contains(method),args.count == 2,let selected=args.last?.boolValue {selectedPageOnly=selectedPageOnly || selected;args.removeLast()}
                    var value: JSONValue
                    var immersionDefinitionFromDevice = false
                    if ["getPageDocument", "savePageDocument", "resolveMobilePageConflict", "getPageAsset", "getSyncedBlockSource", "getDatabaseContainer", "queryDatabaseContainerRows"].contains(method) {
                        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
                        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
                        let pages = try await CompanionPageDocumentStores.shared.store(pairingId: pairing.id, vaultId: vault)
                        if method == "getPageDocument", args.count == 1, let page = args[0].stringValue {
                            if await pages.hasDraft(pageId:page),let owned = await pages.document(pageId: page) { value = owned }
                            else {
                                let authored = await pages.authoredSource(pageId: page)
                                let source: JSONValue
                                if selectedPageOnly, let authored { source = authored; onOfflineCopy(true) }
                                else {
                                    do {
                                        let consulted = try await loadPrivateBridgeValue(session, method: "getMobilePageDocument", args: [.string(page)],downloadedOnly:selectedPageOnly)
                                        let ownRevision = authored?.objectValue?["document"]?.objectValue?["revision"]?.intValue ?? 0
                                        let consultedRevision = consulted.objectValue?["document"]?.objectValue?["revision"]?.intValue ?? 0
                                        let ownPageRevision = authored?.objectValue?["document"]?.objectValue?["page"]?.objectValue?["revision"]?.intValue ?? 0
                                        let consultedPageRevision = consulted.objectValue?["document"]?.objectValue?["page"]?.objectValue?["revision"]?.intValue ?? 0
                                        if let authored, ownRevision > consultedRevision || ownRevision == consultedRevision && ownPageRevision > consultedPageRevision { source = authored; onOfflineCopy(true) }
                                        else { source = consulted }
                                    } catch {
                                        guard isPrivateBridgeOffline(error), let authored else { throw error }
                                        source = authored; onOfflineCopy(true)
                                    }
                                }
                                value = try CompanionPageDocuments.document(source, vaultId: vault, pageId: page)
                                try await pages.refreshAuthoredSource(pageId: page, source: source)
                                try await pages.seed(pageId: page, document: value)
                                value = await pages.document(pageId:page) ?? value
                            }
                        } else if method == "savePageDocument", args.count == 1, let page = args[0].objectValue?["pageId"]?.stringValue {
                            guard pairing.domains.contains(.writing), session.connection.role.canSendChanges else { throw DesktopBridgeError.permissionDenied }
                            value = try await pages.save(pageId: page, input: args[0]); Task { await session.synchronizeCompanionChanges() }
                        } else if method == "resolveMobilePageConflict", args.count == 2, let page = args[0].stringValue, let keep = args[1].boolValue {
                            guard pairing.domains.contains(.writing), session.connection.role.canSendChanges else { throw DesktopBridgeError.permissionDenied }
                            value = try await pages.resolve(pageId: page, keepMobile: keep); Task { await session.synchronizeCompanionChanges() }
                        } else if method == "getPageAsset", args.count == 1, let hash = args[0].stringValue, hash.count == 64, hash.allSatisfy(\.isHexDigit) {
                            let copy = try await loadPrivateBridgeFile(session, kind: .pageAsset, id: hash,downloadedOnly:selectedPageOnly)
                            let bytes = try Data(contentsOf: copy.url)
                            value = .object(["base64": .string(bytes.base64EncodedString()), "mime": .string(copy.descriptor.mime)])
                        } else if method == "getSyncedBlockSource",args.count == 1,let block=args[0].stringValue {
                            let source=try await loadPrivateBridgeValue(session,method:"getMobileSyncedBlockSource",args:[.string(block)],downloadedOnly:selectedPageOnly)
                            guard source.objectValue?["version"] == .int(1),source.objectValue?["vaultId"] == .string(vault),let original=source.objectValue?["source"] else {throw DesktopBridgeError.malformedResponse}
                            guard original == .null || original.objectValue?["block"]?.objectValue?["id"] == .string(block) else {throw DesktopBridgeError.malformedResponse};value=original
                        } else if ["getDatabaseContainer","queryDatabaseContainerRows"].contains(method),args.count == 1 {
                            let action=method == "getDatabaseContainer" ? "definition":"rows"
                            let source=try await CompanionDatabaseViewSource.linkedRead(session:session,action:action,input:args[0],downloadedOnly:selectedPageOnly)
                            let view=action == "definition" ? args[0].stringValue:args[0].objectValue?["viewId"]?.stringValue
                            guard source.objectValue?["version"] == .int(1),source.objectValue?["vaultId"] == .string(vault),source.objectValue?["action"] == .string(action),let data=source.objectValue?["data"],view != nil else {throw DesktopBridgeError.malformedResponse}
                            if action == "definition" {guard data == .null || data.objectValue?["viewId"]?.stringValue == view else {throw DesktopBridgeError.malformedResponse}}
                            else {guard data.objectValue?["rows"]?.arrayValue != nil,data.objectValue?["revision"]?.stringValue != nil else {throw DesktopBridgeError.malformedResponse}}
                            value=data
                        } else { throw DesktopBridgeError.malformedResponse }
                    } else if method == "openMobileDatabaseRow",args.count == 1,let row=args[0].stringValue,!row.isEmpty,row.utf8.count <= 1024 {
                        onNavigate("databaseRow",row,nil,nil);value = .null
                    } else if method == "mobileDatabasePresentationRead", args.count == 1,
                              let request = args[0].objectValue, let action = request["action"]?.stringValue,
                              let database = request["input"]?.objectValue?["databaseId"]?.stringValue {
                        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
                        let response = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileDatabasePresentationRead", args: args)
                        value = try CompanionDatabasePresentationSource.value(response, vault: vault, database: database, action: action)
                    } else if method == "mobileDatabasePresentationSource", args.count == 1, let database = args[0].stringValue,
                              !database.isEmpty, database.utf8.count <= 1024 {
                        value = try await CompanionDatabasePresentationSource.downloaded(session: session, database: database)
                        onOfflineCopy(true)
                    } else if method == "mobileDatabaseChartExport", args.count == 1, let export = args[0].objectValue,
                              let database = export["databaseId"]?.stringValue, !database.isEmpty, database.utf8.count <= 1024,
                              let format = export["format"]?.stringValue, ["svg", "png"].contains(format),
                              let encoded = export["base64"]?.stringValue, encoded.utf8.count <= 28_000_000,
                              let expected = export["sha256"]?.stringValue, let bytes = Data(base64Encoded: encoded), bytes.count <= 20_000_000 {
                        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
                        if pageDownloadedOnly { _ = try await CompanionDatabasePresentationSource.downloaded(session: session, database: database) }
                        else {
                            do { _ = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileDatabasePresentationRead", args: [.object(["action": .string("metadata"), "input": .object(["databaseId": .string(database)])])]) }
                            catch { guard isPrivateBridgeOffline(error) else { throw error }; _ = try await CompanionDatabasePresentationSource.downloaded(session: session, database: database) }
                        }
                        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == expected,
                              format != "png" || UIImage(data: bytes) != nil else { throw DesktopBridgeError.malformedResponse }
                        if format == "svg" {
                            guard let svg = String(data: bytes, encoding: .utf8), svg.contains("<svg"), !svg.contains("<script"), !svg.contains("<foreignObject") else { throw DesktopBridgeError.malformedResponse }
                        }
                        let filename = "Nodus-chart.\(format)"
                        onExport(try PrivateBridgeFileLease.write(bytes, filename: filename))
                        value = .object(["canceled": .bool(false), "path": .string(filename)])
                    } else if method == "openPageResource", args.count == 1, let resource = args[0].objectValue, let source = resource["source"]?.stringValue, let url = URL(string: source) {
                        if url.scheme == "nodus-blob", let hash = url.host, hash.count == 64, hash.allSatisfy(\.isHexDigit) { onNavigate("pageAsset", hash, nil, nil); value = .null }
                        else if CorpusReference(url) != nil { onNavigate("citation", source, nil, nil); value = .null }
                        else if ["https", "http"].contains(url.scheme ?? "") { _ = await UIApplication.shared.open(url); value = .null }
                        else if url.scheme == "data", source.utf8.count <= 4_000_000, let comma = source.firstIndex(of: ",") {
                            let header = String(source[source.startIndex..<comma]), encoded = String(source[source.index(after: comma)...])
                            guard header.hasSuffix(";base64"), let bytes = Data(base64Encoded: encoded), bytes.count <= 2_000_000,
                                  let filename = resource["name"]?.stringValue, !filename.isEmpty, filename.utf8.count <= 200, !filename.contains("/"), !filename.contains("\\"), ![".", ".."].contains(filename) else { throw DesktopBridgeError.malformedResponse }
                            onExport(try PrivateBridgeFileLease.write(bytes, filename: filename)); value = .null
                        } else { throw DesktopBridgeError.permissionDenied }
                    } else if method == "persistSurfaceStorage" {
                        try await persistSurfaceStorage(args.first ?? .null); value = .null
                    } else if method == "openMobileWritingResult", args.count == 1 {
                        guard let identity = args[0].stringValue, UUID(uuidString: identity) != nil,
                              let pairing = session.connection.desktopPairingId, let vault = session.vaultId
                        else { throw DesktopBridgeError.malformedResponse }
                        let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing, vaultId: vault)
                        guard let request = await ledger.all().first(where: { $0.id == identity }),
                              request.method == "saveStudyImprovementFromMobile",
                              CompanionResultCatalogue.contains(request, in: "workspace"),
                              let checkpoint = request.checkpoint,
                              checkpoint.objectValue?["id"]?.stringValue == identity
                        else { throw DesktopBridgeError.malformedResponse }
                        onOpenWritingResult(MobileWritingResultTarget(request: request, checkpoint: checkpoint))
                        value = .bool(true)
                    } else if method == "companionDictionaryCopy", args.isEmpty {
                        value = try await companionDictionaryCopy(session)
                    } else if method == "surfaceOfflineCopy", args.isEmpty {
                        onOfflineCopy(true); value = .null
                    } else if ["surfaceExportFile","surfaceExportPDF"].contains(method),args.count == 1,
                              let export = args[0].objectValue,let reportId = export["reportId"]?.stringValue,
                              let filename = export["filename"]?.stringValue,!filename.isEmpty,filename.utf8.count <= 200,
                              !filename.contains("/"),!filename.contains("\\"),![".",".."].contains(filename) {
                        let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
                        let client = DesktopBridgeClient(pairing:pairing,token:token)
                        _ = try await databaseReading.perform("getDatabaseDeepResearchReport",args:[.string(reportId)],client:client,pairing:pairing,vaultId:vault,onOffline:onOfflineCopy)
                        let bytes:Data
                        if method == "surfaceExportPDF",filename.hasSuffix(".pdf"),let html = export["html"]?.stringValue,html.utf8.count <= 20_000_000,html.contains("<head>") {
                            let policy = "<head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:;\">"
                            bytes = try await ReportDocument.pdf(from:html.replacingOccurrences(of:"<head>",with:policy))
                            guard bytes.count <= 20_000_000 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
                        } else if method == "surfaceExportFile",["md","docx","zip"].contains(URL(fileURLWithPath:filename).pathExtension),
                                  let encoded = export["base64"]?.stringValue,encoded.utf8.count <= 28_000_000,
                                  let expected = export["sha256"]?.stringValue,let data = Data(base64Encoded:encoded),data.count <= 20_000_000,
                                  SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == expected { bytes = data }
                        else { throw DesktopBridgeError.malformedResponse }
                        let lease = try PrivateBridgeFileLease.write(bytes,filename:filename)
                        onExport(lease);value = .object(["canceled":.bool(false),"path":.string(filename)])
                    } else if method == "readerSelectionState", args.count == 1, let selected = input.first as? Bool {
                        (webView as? ReaderSurfaceWebView)?.readerSelectionManaged = selected
                        value = .null
                    } else if ["surfaceVaultContext", "getActiveVault"].contains(method), args.isEmpty {
                        let vault = MobileSurfaceVaultContext.descriptor(connection: session.connection, vault: session.overview?.vault)
                        value = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(vault))
                    } else if method == "surfaceFullscreen", let enabled = input.first as? Bool {
                        session.isSurfaceFullscreen = enabled; value = .null
                    } else if method == "mobileSettings", session.connection.desktopPairingId == nil {
                        value = try autonomous.portableSettings(args.first ?? .null)
                    } else if method == "snapshot" {
                        value = .object(try await session.client.snapshot(in: session.connection.spaceId).document)
                    } else if method == "dictionarySnapshotTables", input.isEmpty {
                        value = .object(try await session.client.snapshot(in: session.connection.spaceId, consultation: .dictionary).dictionaryConsultationTables())
                    } else if method == "sourceConsultationTables", input.isEmpty {
                        value = .object(try await session.client.snapshot(in: session.connection.spaceId, consultation: .sources).sourceConsultationTables())
                    } else if method == "openSourceDocument", args.count == 1 {
                        let target = try JSONDecoder.nodus.decode(SourceDocumentTarget.self, from: JSONEncoder.nodus.encode(args[0]))
                        try target.validate(); onOpenSource(target); value = .null
                    } else if method == "openSavedAudioClip", args.count == 2,
                              let clip = args[0].stringValue, !clip.isEmpty, clip.utf8.count <= 1024,
                              let label = args[1].stringValue, label.utf8.count <= 2048 {
                        let copy = try await loadPrivateBridgeFile(session, kind: .audioClip, id: clip)
                        guard copy.descriptor.mime == "audio/wav", copy.descriptor.byteSize > 0 else { throw DesktopBridgeError.malformedResponse }
                        onOpenAudio(SavedAudioTarget(id: clip, label: label, copy: copy)); value = .null
                    } else if method == "publishedSourceDocument", session.connection.desktopPairingId == nil,
                              let record = args.first?.stringValue, args.count == 2 {
                        let document = try await publishedSourceLibraryDocument(session, id: record)
                        let attachments: JSONValue = document.originalAvailable ? .array([.object([
                            "id": .string("original"), "title": .string(document.originalFileName ?? document.title),
                            "fileName": .string(document.originalFileName ?? "original"),
                            "mimeType": .string(document.originalMimeType ?? "application/octet-stream"), "available": .bool(true)
                        ])]) : .array([])
                        if args[1].stringValue == "getGlobalLibraryItem" {
                            value = .object(["id": .string(document.id), "metadata": .object(["title": .string(document.title)]),
                                "attachments": attachments, "files": .object(document.cleanAvailable ? ["reader": .string("reader.md")] : [:])])
                        } else if args[1].stringValue == "getLibraryReaderDocument" {
                            value = .object(["workId": .string(document.id), "title": .string(document.title),
                                "cleanAvailable": .bool(document.cleanAvailable), "originalAvailable": .bool(document.originalAvailable),
                                "attachments": attachments])
                        } else { throw DesktopBridgeError.permissionDenied }
                    } else if method == "navigate", (2...3).contains(input.count), let kind = input[0] as? String, let record = input[1] as? String {
                        let position = input.count == 3 ? input[2] as? [String: Any] : nil
                        onNavigate(kind, record, position?["location"] as? String, position?["quote"] as? String); value = .null
                    } else if method == "cancelLiveJob", let requestId = input.first as? String {
                        let jobMethod = args.count == 3 ? args[1].stringValue : nil
                        let jobArgs = args.count == 3 ? args[2].arrayValue : nil
                        if let running = runningJobs[requestId] { try await running.0.cancelDurableJob(vaultId: running.1, requestId: requestId) }
                        else {
                            let (vault, pairing, token) = try privateBridgeConnection(session, domain: .writing)
                            try await DesktopBridgeClient(pairing: pairing, token: token).cancelDurableJob(vaultId: vault, requestId: requestId, method: jobMethod, args: jobArgs)
                        }
                        value = .null
                    } else if method == "mobileArgumentMaps", args.isEmpty {
                        value = try await autonomous.argumentMaps(session: session)
                    } else if method == "mobileAcademicSource", args.count == 1 {
                        value = try await CompanionAcademicGeneration.source(session: session, request: args[0])
                    } else if method == "mobileAcademicDownload", args.count == 2, let days = args[1].intValue, [7, 30].contains(days) {
                        try await CompanionAcademicGeneration.download(session: session, request: args[0], days: days); value = .null
                    } else if ["mobileDictionaryCheckpoint", "mobileGenerationCheckpoint"].contains(method) {
                        value = method == "mobileDictionaryCheckpoint" ? try await autonomous.dictionaryCheckpoint(args, session: session) : try await autonomous.generationCheckpoint(args, session: session)
                        let checkpoint = value.objectValue ?? args.last?.objectValue
                        if let state = checkpoint?["state"]?.stringValue {
                            autonomousGenerationId = checkpoint?["id"]?.stringValue
                            switch state {
                            case "accepted": onAutonomousStatus(String(localized: "Request accepted"))
                            case "running": onAutonomousStatus(String(localized: "Generating on this device"))
                            case "saved": onAutonomousStatus(nil) // The native results row carries the pending state.
                            case "available": onAutonomousStatus(nil)
                            case "failed": onAutonomousStatus(checkpoint?["error"]?.stringValue ?? String(localized: "Generation failed"))
                            default: break
                            }
                        }
                    } else if method == "mobileDictionaryGenerationJobs", args.isEmpty {
                        value = try await autonomous.dictionaryPublications(session: session)
                    } else if method == "mobileDatabaseResearchCheckpoints",args.isEmpty {
                        value = try await autonomous.databaseCheckpoints(session:session)
                    } else if method == "getDatabaseResearchOfflineSource" {
                        value = try await autonomous.databaseOfflineSource(args,session:session)
                    } else if method == "getDatabaseResearchOfflineCatalogue",args.isEmpty {
                        value = try await autonomous.databaseOfflineCatalogue(session:session)
                    } else if method == "mobileStructuredCompletion" {
                        value = try await autonomous.complete(args.first ?? .null, session: session)
                    } else if method == "cancelAutonomousGeneration", let generation = args.first?.stringValue {
                        try autonomous.cancel(generation); value = .null
                    } else if session.aiExecutionMode == .autonomous, method == "updateSettings" {
                        try autonomous.updateSettings(args.first ?? .null); value = .null
                    } else if session.aiExecutionMode == .autonomous, ["listModels", "getModelCatalog"].contains(method) {
                        guard let provider = args.first?.stringValue else { throw DesktopBridgeError.malformedResponse }
                        value = try await autonomous.models(provider, includeStatus: method == "getModelCatalog")
                    } else {
                        let creationFields = args.first?.objectValue
                        let localIdeaCreation = method == "createManualIdea"
                        let localCreation = localIdeaCreation || (method == "createNote" &&
                            (creationFields?["kind"] == nil || creationFields?["kind"] == .string("markdown")) &&
                            (creationFields?["source"] == nil || creationFields?["source"] == .null) &&
                            creationFields?["content"] == .string(""))
                        if Self.operationDomains[method] == "research-generation", session.aiExecutionMode != .live, !localCreation,
                           !["cancelDatabaseDeepResearchJob","clearFinishedDatabaseDeepResearchJobs"].contains(method) {
                            throw APIError(status: 409, code: "explicit_mode_required", message: String(localized: "Choose live mode to run this operation on the Mac. The app does not switch execution modes automatically."))
                        }
                        let store = DesktopBridgePairingStore()
                        guard let vaultId = session.vaultId,
                            let pairing = store.pairings().first(where: { $0.id == session.connection.desktopPairingId }),
                            let token = store.credential(for: pairing) else { throw DesktopBridgeError.permissionDenied }
                        let client = DesktopBridgeClient(pairing: pairing, token: token)
                        if ["getContentTranslationOfflineSource", "getContentTranslationGenerationContext", "generateContentTranslation",
                            "beginContentTranslationOnMobile", "saveContentTranslationFromMobile", "failContentTranslationOnMobile"].contains(method) {
                            let target = method == "saveContentTranslationFromMobile" ? args.first?.objectValue?["request"]?.objectValue : args.first?.objectValue
                            if target?["entityKind"] == .string("study_transcript"), !pairing.domains.contains(.studyRecordings) {
                                throw DesktopBridgeError.permissionDenied
                            }
                        }
                        if method == "enqueueDatabaseDeepResearch",args.count == 1,args[0].objectValue != nil {
                            guard !pairing.isExpired,pairing.vaultIds.contains(vaultId),pairing.domains.contains(.researchGeneration),session.aiExecutionMode == .live else { throw DesktopBridgeError.permissionDenied }
                            let requestId = UUID().uuidString
                            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:vaultId)
                            _ = try await ledger.prepare(id:requestId,method:method,args:args)
                            do {
                                let job = try await client.submitJob(vaultId:vaultId,method:method,args:args,idempotencyKey:requestId)
                                guard [DesktopBridgeJob.State.accepted,.running,.saved,.available].contains(job.state) else { throw APIError(status:409,code:"database_request_not_accepted",message:job.error ?? "La solicitud no se pudo aceptar.") }
                                try await ledger.update(id:requestId,job:job)
                                value = .object(["version":.int(1),"requestId":.string(requestId),"bridgeJobId":.string(job.id),"state":.string(job.state.rawValue)])
                            } catch {
                                try? await ledger.disconnected(id:requestId,issue:error.localizedDescription)
                                guard isPrivateBridgeOffline(error) else { throw error }
                                value = .object(["version":.int(1),"requestId":.string(requestId),"bridgeJobId":.null,"state":.string("pending")])
                            }
                            Task { await session.synchronizeCompanionChanges() }
                        } else if DatabaseResearchSurfaceBridge.methods.contains(method) {
                            value = try await databaseReading.perform(method,args:args,client:client,pairing:pairing,vaultId:vaultId,onOffline:onOfflineCopy)
                        } else if ImmersionSurfaceProgressBridge.writeMethods.contains(method) {
                            value = try await immersionProgress.write(method: method, args: args, pairing: pairing, vaultId: vaultId)
                        } else if localCreation || ["getWorkspaceNoteEditorData", "updateWorkspaceNote", "getNotesTree", "resolveMobileWorkspaceConflict", "getIdeaDetail", "getIdeaEdges"].contains(method) {
                            guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
                            let documents = try await CompanionDocumentOutboxes.shared.outbox(pairingId: pairing.id, vaultId: vaultId)
                            if localCreation, args.count == 1 {
                                guard pairing.domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
                                value = localIdeaCreation ? try await documents.createManualIdea(input: args[0]) : try await documents.create(input: args[0])
                                Task { await session.synchronizeCompanionChanges() }
                            } else if method == "updateWorkspaceNote", args.count == 2, let noteId = args[0].stringValue {
                                guard pairing.domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
                                value = try await documents.save(noteId: noteId, input: args[1])
                                Task { await session.synchronizeCompanionChanges() }
                            } else if method == "resolveMobileWorkspaceConflict", args.count == 2,
                                      let noteId = args[0].stringValue, let keepMobile = args[1].boolValue {
                                guard pairing.domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
                                value = try await documents.resolve(noteId: noteId, keepMobile: keepMobile)
                                Task { await session.synchronizeCompanionChanges() }
                            } else if method == "getWorkspaceNoteEditorData", let noteId = args.first?.stringValue,
                                      let local = await documents.editorData(noteId: noteId) {
                                value = local
                            } else if ["getIdeaDetail", "getIdeaEdges"].contains(method), let globalId = args.first?.stringValue,
                                      let local = await documents.pendingIdeaDetail(globalId: globalId) {
                                value = method == "getIdeaDetail" ? local : .array([])
                            } else {
                                let cache = try PrivateBridgeCache(pairingId: pairing.id)
                                let key = try CompanionDocumentOutbox.operationKey(method, args)
                                let cached = try await cache.data(vaultId: vaultId, domain: .corpus, recordId: key)
                                let ownedEditor = method == "getWorkspaceNoteEditorData" && args.count == 1 ? await documents.confirmedEditorData(noteId: args[0].stringValue ?? "") : nil
                                let includeTrashed = args.first == .bool(true)
                                let ownedTree = method == "getNotesTree" ? await documents.confirmedTree(includeTrashed: includeTrashed) : nil
                                var privateReadFromDevice = false
                                let hasDownloadedIdeas = CompanionIdeaCopy.operationMethods.contains(method)
                                    ? try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: CompanionIdeaCopy.recordId) : false
                                let authoredIdeas = CompanionIdeaCopy.operationMethods.contains(method) ? await documents.pendingIdeaCopy(includeConfirmed: true) : nil
                                let hasIdeas = hasDownloadedIdeas || authoredIdeas != nil
                                do {
                                    value = try await client.operation(vaultId: vaultId, method: method, args: args, timeout: cached == nil && !hasIdeas && ownedEditor == nil && ownedTree == nil ? nil : 4)
                                    onOfflineCopy(false)
                                    try await cache.store(JSONEncoder.nodus.encode(value), vaultId: vaultId, domain: .corpus, recordId: key)
                                } catch {
                                    guard isPrivateBridgeOffline(error) else { throw error }
                                    privateReadFromDevice = true
                                    let ideaCopy = hasIdeas ? try await CompanionIdeaCopy.consultable(cache: cache, vaultId: vaultId) : nil
                                    if let local = try ideaCopy?.operation(method, args: args) { value = local }
                                    else if let ownedEditor, (ownedEditor.objectValue?["revision"]?.intValue ?? 0) >= (cached.flatMap { try? JSONDecoder.nodus.decode(JSONValue.self, from: $0) }.flatMap { $0.objectValue?["revision"]?.intValue } ?? -1) { value = ownedEditor }
                                    else if let cached { value = try JSONDecoder.nodus.decode(JSONValue.self, from: cached) }
                                    else if let ownedTree { value = ownedTree }
                                    else { throw error }
                                    onOfflineCopy(true)
                                }
                                if method == "getWorkspaceNoteEditorData", let noteId = args.first?.stringValue { try await documents.seed(noteId: noteId, editorData: value) }
                                if method == "getNotesTree" {
                                    try await documents.rememberTree(value, authoritative: !privateReadFromDevice)
                                    value = await documents.overlayTree(value, includeConfirmedEdits: privateReadFromDevice, includeTrashed: includeTrashed)
                                }
                            }
                        } else if DesktopBridgeClient.jobMethods.contains(method) {
                            let first = input.first as? String
                            if method == "buildArgumentMap", first.flatMap({ UUID(uuidString: $0) }) != nil { args.removeFirst() }
                            let streamMethod = ["buildArgumentMap", "generateImmersionSession", "researchChatStream", "worldChatStream", "dbChatStream", "streamStudyAssistant", "improveStudyText", "exportDeepResearchArchive"].contains(method)
                            let persistedId = ["saveDictionaryGeneratedVersion", "saveImmersionGeneratedSession", "saveContentTranslationFromMobile", "saveStudyImprovementFromMobile", "saveMobileAcademicResult"].contains(method) ? args.first?.objectValue?["requestId"]?.stringValue : nil
                            let requestId = (persistedId ?? (streamMethod ? first : nil)).flatMap { UUID(uuidString: $0) == nil ? nil : $0 } ?? UUID().uuidString
                            let ledger = try await DesktopJobLedgers.shared.ledger(pairingId: pairing.id, vaultId: vaultId)
                            _ = try await ledger.prepare(id: requestId, method: method, args: args)
                            let job: DesktopBridgeJob
                            do { job = try await client.submitJob(vaultId: vaultId, method: method, args: args, idempotencyKey: requestId) }
                            catch { try? await ledger.disconnected(id: requestId, issue: error.localizedDescription); throw error }
                            try await ledger.update(id: requestId, job: job)
                            runningJobs[requestId] = (client, vaultId, job.id)
                            defer { runningJobs[requestId] = nil }
                            do {
                                value = try await client.awaitJob(vaultId: vaultId, job: job, onState: { try await ledger.update(id: requestId, job: $0) }) { events in
                                    await MainActor.run {
                                        if !events.isEmpty, let data = try? JSONEncoder.nodus.encode(events) {
                                            // Deliver the ordered batch in one WebKit call.
                                            // A live turn can contain thousands of deltas.
                                            self.webView?.evaluateJavaScript("\(String(decoding: data, as: UTF8.self)).forEach(event => window.nodusMobileEvent(event));", completionHandler: nil)
                                        }
                                    }
                                }
                            } catch {
                                // Preserve the accepted request and its stable idempotency key.
                                // Reopening Jobs reconnects to this job rather than generating twice.
                                try? await ledger.disconnected(id: requestId, issue: error.localizedDescription)
                                throw error
                            }
                        } else {
                            let cache = try PrivateBridgeCache(pairingId: pairing.id)
                            let key = "operation:\(method):" + SHA256.hash(data: try JSONEncoder.nodus.encode(args)).map { String(format: "%02x", $0) }.joined()
                            let cached = Self.operationDomains[method] == "corpus" ? try await cache.data(vaultId: vaultId, domain: .corpus, recordId: key) : nil
                            let hasCatalogue = args.isEmpty && ["listWritingWorkshopDrafts", "listImmersionSessions"].contains(method)
                            let hasDictionary = ["listDictionaryEntries", "listDictionaryFacets", "listDictionaryEvidence"].contains(method)
                                ? try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: "companion:dictionary:v1") : false
                            let hasVerification = method == "verifyCitations" && args.count == 1
                                ? try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: "companion:citations:v1") : false
                            let hasDownloadedIdeas = CompanionIdeaCopy.operationMethods.contains(method)
                                ? try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: CompanionIdeaCopy.recordId) : false
                            let authoredIdeas = CompanionIdeaCopy.operationMethods.contains(method)
                                ? try await CompanionIdeaCopy.authored(cache: cache, vaultId: vaultId) : nil
                            let hasIdeas = hasDownloadedIdeas || authoredIdeas != nil
                            // A new autonomous request has no exact cached
                            // context yet. Its selected source still gives it
                            // the same short offline deadline as a cached read.
                            let portableSource: (String, [JSONValue])?
                            if let request = args.first?.objectValue, method == "getStudyImprovementGenerationContext",
                               let id = request["noteId"]?.stringValue ?? request["documentId"]?.stringValue {
                                portableSource = ("getStudyImprovementOfflineSource", [.object([request["noteId"]?.stringValue != nil ? "noteId" : "documentId": .string(id)])])
                            } else if let request = args.first?.objectValue, method == "getContentTranslationGenerationContext",
                                      let kind = request["entityKind"]?.stringValue, let id = request["entityId"]?.stringValue {
                                portableSource = ("getContentTranslationOfflineSource", [.object(["entityKind": .string(kind), "entityId": .string(id)])])
                            } else if let request = args.first?.objectValue, method == "getImmersionGenerationContext", let topic = request["topic"]?.stringValue {
                                portableSource = ("getImmersionOfflineSource", [.object(["topic": .string(topic.trimmingCharacters(in: .whitespacesAndNewlines)),
                                    "language": request["language"] ?? .string("es")])])
                            } else { portableSource = nil }
                            let hasPortableSource: Bool
                            if let (sourceMethod, sourceArgs) = portableSource {
                                hasPortableSource = try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus,
                                    recordId: CompanionDocumentOutbox.operationKey(sourceMethod, sourceArgs))
                            } else { hasPortableSource = false }
                            do {
                                value = try await client.operation(vaultId: vaultId, method: method, args: args, timeout: cached == nil && !hasDictionary && !hasVerification && !hasIdeas && !hasPortableSource ? nil : 4)
                                onOfflineCopy(false)
                                if Self.operationDomains[method] == "corpus" {
                                    var reusable = value
                                    if method == "getImmersionSession", var definition = value.objectValue {
                                        definition["progress"] = nil; reusable = .object(definition)
                                    }
                                    try await cache.store(JSONEncoder.nodus.encode(reusable), vaultId: vaultId, domain: .corpus, recordId: key)
                                }
                            } catch {
                                guard Self.operationDomains[method] == "corpus", isPrivateBridgeOffline(error) else { throw error }
                                let catalogue = hasCatalogue ? try await companionDownloadedCatalogue(cache, vaultId: vaultId, method: method) : nil
                                let verification = hasVerification ? try await companionCitationVerification(cache, vaultId: vaultId, refs: args[0]) : nil
                                let ideaCopy = hasIdeas ? try await CompanionIdeaCopy.consultable(cache: cache, vaultId: vaultId) : nil
                                let idea = try ideaCopy?.operation(method, args: args)
                                if let catalogue { value = catalogue }
                                else if let idea { value = idea }
                                else if let cached { value = try JSONDecoder.nodus.decode(JSONValue.self, from: cached) }
                                else if let verification { value = verification }
                                else { throw error }
                                if method == "getImmersionSession" { immersionDefinitionFromDevice = true }
                                onOfflineCopy(true)
                            }
                            if method == "getSettings", session.aiExecutionMode == .autonomous { value = try autonomous.portableSettings(value) }
                        }
                        if method == "getImmersionSession", args.count == 1, let id = args[0].stringValue {
                            value = try await immersionProgress.read(value, id: id, client: client, pairing: pairing, vaultId: vaultId, fetchMacProgress: !immersionDefinitionFromDevice)
                            if pairing.domains.contains(.writing), let plan = value.objectValue?["plan"] { onImmersionSource(id, plan) }
                        }
                        if ["exportWritingWorkshopDraft", "exportDeepResearchArchive", "exportImmersionSessionPdf", "exportDatabaseDeepResearchReport"].contains(method), case .object(var file) = value,
                           let exportId = file["exportId"]?.stringValue, let name = file["filename"]?.stringValue, let hash = file["sha256"]?.stringValue {
                            let bytes = try await client.exportedFile(vaultId: vaultId, id: exportId, sha256: hash)
                            let lease = try PrivateBridgeFileLease.write(bytes,filename:URL(fileURLWithPath:name).lastPathComponent)
                            onExport(lease);file["path"] = .string(lease.url.lastPathComponent);value = .object(file)
                        }
                    }
                    try reply(id, value: value, error: nil)
                } catch is CancellationError {
                    try? reply(id, value: .null, error: String(localized: "Generation cancelled"), errorCode: "cancelled")
                } catch { try? reply(id, value: .null, error: "\(method): \(error.localizedDescription)", errorCode: isPrivateBridgeOffline(error) ? "offline" : nil) }
            })
        }
        func surfaceStorage() async throws -> JSONValue {
            let scope = try session.surfaceStorageScope()
            let cache = try surfaceCache(scope.cacheId)
            guard let bytes = try await cache.data(vaultId: scope.recordVaultId, domain: .writing, recordId: "surface-storage:v1") else { return .object([:]) }
            return try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
        }
        private func persistSurfaceStorage(_ value: JSONValue) async throws {
            guard let object = value.objectValue, object.count <= 1000,
                object.allSatisfy({ $0.key.utf8.count <= 1024 && $0.value.stringValue != nil }) else { throw DesktopBridgeError.permissionDenied }
            let bytes = try JSONEncoder.nodus.encode(value)
            guard bytes.count <= 20_000_000 else { throw DesktopBridgeError.malformedResponse }
            let scope = try session.surfaceStorageScope()
            let cache = try surfaceCache(scope.cacheId)
            try await cache.store(bytes, vaultId: scope.recordVaultId, domain: .writing, recordId: "surface-storage:v1")
        }
        private func surfaceCache(_ pairing: String) throws -> PrivateBridgeCache {
            if let persistedSurfaceCache { return persistedSurfaceCache }
            let cache = try PrivateBridgeCache(pairingId: pairing)
            persistedSurfaceCache = cache
            return cache
        }
        private func reply(_ id: String, value: JSONValue, error: String?, errorCode: String? = nil) throws {
            let issue: JSONValue = error.map { message in
                errorCode.map { .object(["code": .string($0), "message": .string(message)]) } ?? .string(message)
            } ?? .null
            let envelope: JSONValue = .array([.string(id), value, issue])
            let text = String(decoding: try JSONEncoder.nodus.encode(envelope), as: UTF8.self)
            webView?.evaluateJavaScript("window.nodusMobileReply(...\(text));", completionHandler: nil)
        }
        func finishJavaScriptPanel() {
            let cancel = cancelJavaScriptPanel
            cancelJavaScriptPanel = nil
            javaScriptPanel?.dismiss(animated: false)
            javaScriptPanel = nil
            cancel?()
        }
        func webView(_ view: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo) async -> Bool {
            await withCheckedContinuation { continuation in
                presentJavaScriptConfirm(view, message: message, frame: frame) { continuation.resume(returning: $0) }
            }
        }
        private func presentJavaScriptConfirm(_ view: WKWebView, message: String,
            frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            guard frame.isMainFrame, let url = frame.request.url, LocalSurfaceHost.shared.owns(url),
                var presenter = view.window?.rootViewController, javaScriptPanel == nil else { completionHandler(false); return }
            while let next = presenter.presentedViewController { presenter = next }
            guard !(presenter is UIAlertController) else { completionHandler(false); return }
            let panel = UIAlertController(title: "Nodus", message: message, preferredStyle: .alert)
            let finish: (Bool) -> Void = { [weak self] accepted in
                guard self?.cancelJavaScriptPanel != nil else { return }
                self?.cancelJavaScriptPanel = nil; self?.javaScriptPanel = nil
                completionHandler(accepted)
            }
            cancelJavaScriptPanel = { completionHandler(false) }
            panel.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in finish(false) })
            panel.addAction(UIAlertAction(title: String(localized: "Accept"), style: .default) { _ in finish(true) })
            javaScriptPanel = panel
            presenter.present(panel, animated: true)
        }
        func webView(_ view: WKWebView, willPresentEditMenuWithAnimator animator: any UIEditMenuInteractionAnimating) {
            // WebKit may present before the asynchronous selection-state message
            // reaches Swift. Recheck the actual range and keep handles intact.
            animator.addCompletion {
                view.evaluateJavaScript("(()=>{const s=window.getSelection();if(!s||s.isCollapsed||!s.rangeCount)return false;const node=s.getRangeAt(0).commonAncestorContainer;const root=(node.nodeType===1?node:node.parentElement)?.closest('[data-reader-managed-selection]');if(!root)return false;document.dispatchEvent(new Event('nodus-reader-selection'));return true})()") { value, _ in
                    if value as? Bool == true { (view as? ReaderSurfaceWebView)?.dismissReaderEditMenu() }
                }
            }
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if LocalSurfaceHost.shared.owns(url) { return .allow }
            if url.scheme == "about" { return .allow }
            if ["nodus-library","nodus-archive"].contains(url.scheme ?? "") {
                guard (try? CompanionEmbeddedResource.identity(url.absoluteString)) != nil else { return .cancel }
                if action.targetFrame?.isMainFrame == false { return .allow }
                onNavigate("embeddedResource",url.absoluteString,nil,nil); return .cancel
            }
            if ["https", "http"].contains(url.scheme ?? "") { _ = await UIApplication.shared.open(url) }
            return .cancel
        }
    }
}
