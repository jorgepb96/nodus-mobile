import CryptoKit
import NodusKit
import SwiftUI
import WebKit

enum DesktopSurface: String { case graph, dictionary, workspace, argument, deepResearch, immersion, chat }

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
    @Environment(AISettings.self) private var ai
    @Environment(\.colorScheme) private var theme
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var destination: SurfaceDestination?
    @State private var sourceDocument: SourceDocumentTarget?
    @State private var issue: String?
    @State private var exportedURL: URL?
    @State private var savedAudio: SavedAudioTarget?
    @State private var autonomousStatus: String?

    var body: some View {
        DesktopWebView(session: session, ai: ai, surface: surface, dark: theme == .dark, textScale: ReadingStyle.sharedSurfaceScale(for: textSize), onError: { issue = $0 }, onExport: { exportedURL = $0 }, onAutonomousStatus: { autonomousStatus = $0 }, onOpenSource: { sourceDocument = $0 }, onOpenAudio: { savedAudio = $0 }) { kind, id, location, quote in
            let path = kind == "studyMaterial" ? "study-materials" : kind == "studyDocument" ? "study-docs"
                : kind == "idea" ? "ideas" : kind == "author" ? "authors" : "works"
            destination = SurfaceDestination(path: path, id: id, location: location, quote: quote)
        }
        .id("\(session.connection.id):\(surface.rawValue):\(session.aiExecutionMode.rawValue)")
        .overlay(alignment: .top) { if let issue { Text(issue).font(.caption).padding().background(.background).foregroundStyle(.red).accessibilityIdentifier("shared-surface-error") } }
        .overlay(alignment: .bottom) { if let autonomousStatus { Text(autonomousStatus).font(.caption).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding().accessibilityIdentifier("autonomous-job-status") } }
        .sheet(item: $exportedURL) { ActivityShareSheet(items: [$0]) }
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
        .sheet(item: $destination) { target in
            NavigationStack {
                Group {
                    if target.path == "study-docs" {
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
    let onError: (String) -> Void
    let onExport: (URL) -> Void
    let onAutonomousStatus: (String?) -> Void
    let onOpenSource: (SourceDocumentTarget) -> Void
    let onOpenAudio: (SavedAudioTarget) -> Void
    let onNavigate: (String, String, String?, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session, ai: ai, onError: onError, onExport: onExport, onAutonomousStatus: onAutonomousStatus, onOpenSource: onOpenSource, onOpenAudio: onOpenAudio, onNavigate: onNavigate) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "nodus")
        let data: [String: Any] = ["surface": surface.rawValue, "live": session.connection.desktopPairingId != nil, "executionMode": session.aiExecutionMode.rawValue,
            "device": UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "tablet",
            "theme": dark ? "dark" : "light", "accent": session.vaultType?.accentHex ?? "#6366f1", "textScale": textScale, "vaultType": session.vaultType?.rawValue ?? "academic", "language": Locale.current.language.languageCode?.identifier ?? "es"]
        if let json = try? JSONSerialization.data(withJSONObject: data), let text = String(data: json, encoding: .utf8) {
            let bootstrap = """
            window.nodusMobileConfig=\(text);
            window.nodusMobileSubscriptions=new Map();
            window.nodusMobilePending=new Map();window.nodusMobileSequence=0;
            window.nodusMobileCall=(method,...args)=>new Promise((resolve,reject)=>{
              const id=String(++window.nodusMobileSequence);window.nodusMobilePending.set(id,{resolve,reject});
              window.webkit.messageHandlers.nodus.postMessage({id,method,args});
            });
            window.nodusMobileReply=(id,result,error)=>{const p=window.nodusMobilePending.get(id);if(!p)return;window.nodusMobilePending.delete(id);if(error){const failure=new Error(typeof error==='string'?error:error.message);if(error.code==='cancelled')failure.name='AbortError';p.reject(failure)}else p.resolve(result)};
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
                    let document = try await LocalSurfaceHost.shared.documentURL(); view.load(URLRequest(url: document))
                }
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
        view.evaluateJavaScript("document.documentElement.classList.toggle('dark',\(dark));document.documentElement.classList.toggle('light',\(!dark));document.documentElement.style.fontSize='\(16 * textScale)px';document.documentElement.style.setProperty('--nodus-mobile-text-scale','\(textScale)');", completionHandler: nil)
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "nodus")
        coordinator.tasks.forEach { $0.cancel() }
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
        let session: SpaceSession
        let autonomous: AutonomousSurfaceProvider
        let onNavigate: (String, String, String?, String?) -> Void
        let onError: (String) -> Void
            let onExport: (URL) -> Void
        let onAutonomousStatus: (String?) -> Void
        let onOpenSource: (SourceDocumentTarget) -> Void
        let onOpenAudio: (SavedAudioTarget) -> Void
        var tasks: [Task<Void, Never>] = []
        var runningJobs: [String: (DesktopBridgeClient, String, String)] = [:]
        private var persistedSurfaceCache: PrivateBridgeCache?
        init(session: SpaceSession, ai: AISettings, onError: @escaping (String) -> Void, onExport: @escaping (URL) -> Void, onAutonomousStatus: @escaping (String?) -> Void, onOpenSource: @escaping (SourceDocumentTarget) -> Void, onOpenAudio: @escaping (SavedAudioTarget) -> Void, onNavigate: @escaping (String, String, String?, String?) -> Void) { self.session = session; autonomous = AutonomousSurfaceProvider(settings: ai); self.onError = onError; self.onExport = onExport; self.onAutonomousStatus = onAutonomousStatus; self.onOpenSource = onOpenSource; self.onOpenAudio = onOpenAudio; self.onNavigate = onNavigate }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                let id = body["id"] as? String, let method = body["method"] as? String,
                let input = body["args"] as? [Any], JSONSerialization.isValidJSONObject(input) else { return }
                        if method == "surfaceError", let error = input.first as? String { onError(error); return }
            tasks.append(Task {
                do {
                    let args = try JSONDecoder.nodus.decode([JSONValue].self, from: JSONSerialization.data(withJSONObject: input))
                    var value: JSONValue
                    if method == "persistSurfaceStorage" {
                        try await persistSurfaceStorage(args.first ?? .null); value = .null
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
                        value = .object(try await session.client.snapshot(in: session.connection.spaceId).dictionaryConsultationTables())
                    } else if method == "sourceConsultationTables", input.isEmpty {
                        value = .object(try await session.client.snapshot(in: session.connection.spaceId).sourceConsultationTables())
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
                    } else if method == "cancelLiveJob", let requestId = input.first as? String, let running = runningJobs[requestId] {
                        _ = try await running.0.cancelJob(vaultId: running.1, id: running.2); value = .null
                    } else if ["mobileDictionaryCheckpoint", "mobileGenerationCheckpoint"].contains(method) {
                        value = method == "mobileDictionaryCheckpoint" ? try await autonomous.dictionaryCheckpoint(args, session: session) : try await autonomous.generationCheckpoint(args, session: session)
                        let checkpoint = args.first?.stringValue == "load" ? value.objectValue : args.last?.objectValue
                        if let state = checkpoint?["state"]?.stringValue {
                            switch state {
                            case "accepted": onAutonomousStatus(String(localized: "Request accepted"))
                            case "running": onAutonomousStatus(String(localized: "Generating on this device"))
                            case "saved": onAutonomousStatus(String(localized: "Saved on this device. Sending to the vault…"))
                            case "available": onAutonomousStatus(nil)
                            case "failed": onAutonomousStatus(checkpoint?["error"]?.stringValue ?? String(localized: "Generation failed"))
                            default: break
                            }
                        }
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
                        if Self.operationDomains[method] == "research-generation", session.aiExecutionMode != .live {
                            throw APIError(status: 409, code: "explicit_mode_required", message: String(localized: "Choose live mode to run this operation on the Mac. The app does not switch execution modes automatically."))
                        }
                        let store = DesktopBridgePairingStore()
                        guard let vaultId = session.vaultId,
                            let pairing = store.pairings().first(where: { $0.id == session.connection.desktopPairingId }),
                            let token = store.credential(for: pairing) else { throw DesktopBridgeError.permissionDenied }
                        let client = DesktopBridgeClient(pairing: pairing, token: token)
                        if ["getWorkspaceNoteEditorData", "updateWorkspaceNote", "getNotesTree", "resolveMobileWorkspaceConflict"].contains(method) {
                            guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
                            let documents = try await CompanionDocumentOutboxes.shared.outbox(pairingId: pairing.id, vaultId: vaultId)
                            if method == "updateWorkspaceNote", args.count == 2, let noteId = args[0].stringValue {
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
                            } else {
                                let cache = try PrivateBridgeCache(pairingId: pairing.id)
                                let key = try CompanionDocumentOutbox.operationKey(method, args)
                                let cached = try await cache.data(vaultId: vaultId, domain: .corpus, recordId: key)
                                do {
                                    value = try await client.operation(vaultId: vaultId, method: method, args: args, timeout: cached == nil ? nil : 4)
                                    try await cache.store(JSONEncoder.nodus.encode(value), vaultId: vaultId, domain: .corpus, recordId: key)
                                } catch {
                                    guard isPrivateBridgeOffline(error), let cached else { throw error }
                                    value = try JSONDecoder.nodus.decode(JSONValue.self, from: cached)
                                }
                                if method == "getWorkspaceNoteEditorData", let noteId = args.first?.stringValue { try await documents.seed(noteId: noteId, editorData: value) }
                                if method == "getNotesTree" { value = await documents.overlayTree(value) }
                            }
                        } else if DesktopBridgeClient.jobMethods.contains(method) {
                            let first = input.first as? String
                            let streamMethod = ["generateImmersionSession", "researchChatStream", "improveStudyText", "exportDeepResearchArchive"].contains(method)
                            let persistedId = ["saveDictionaryGeneratedVersion", "saveImmersionGeneratedSession", "saveContentTranslationFromMobile", "saveStudyImprovementFromMobile"].contains(method) ? args.first?.objectValue?["requestId"]?.stringValue : nil
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
                            do {
                                value = try await client.operation(vaultId: vaultId, method: method, args: args, timeout: cached == nil ? nil : 4)
                                if Self.operationDomains[method] == "corpus" { try await cache.store(JSONEncoder.nodus.encode(value), vaultId: vaultId, domain: .corpus, recordId: key) }
                            } catch {
                                guard Self.operationDomains[method] == "corpus", isPrivateBridgeOffline(error),
                                    let cached else { throw error }
                                value = try JSONDecoder.nodus.decode(JSONValue.self, from: cached)
                            }
                            if method == "getSettings", session.aiExecutionMode == .autonomous { value = try autonomous.portableSettings(value) }
                        }
                        if ["exportWritingWorkshopDraft", "exportDeepResearchArchive", "exportImmersionSessionPdf"].contains(method), case .object(var file) = value,
                           let exportId = file["exportId"]?.stringValue, let name = file["filename"]?.stringValue, let hash = file["sha256"]?.stringValue {
                            let bytes = try await client.exportedFile(vaultId: vaultId, id: exportId, sha256: hash)
                            // A unique directory prevents two same-title reports overwriting each other.
                            let folder = URL.temporaryDirectory.appendingPathComponent("Nodus-exports/\(UUID().uuidString)", isDirectory: true)
                            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                            let url = folder.appendingPathComponent(URL(fileURLWithPath: name).lastPathComponent)
                            try bytes.write(to: url, options: [.atomic, .completeFileProtection])
                            onExport(url); file["path"] = .string(url.lastPathComponent); value = .object(file)
                        }
                    }
                    try reply(id, value: value, error: nil)
                } catch is CancellationError {
                    try? reply(id, value: .null, error: String(localized: "Generation cancelled"), errorCode: "cancelled")
                } catch { try? reply(id, value: .null, error: "\(method): \(error.localizedDescription)") }
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
            if ["https", "http"].contains(url.scheme ?? "") { _ = await UIApplication.shared.open(url) }
            return .cancel
        }
    }
}
