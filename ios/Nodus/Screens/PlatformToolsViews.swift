import CryptoKit
import NodusAI
import NodusKit
import NodusUI
import Observation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import Vision
import WebKit

// MARK: - Route surface

struct PlatformToolsWorkspaceView: View {
    let session: SpaceSession
    let route: NodusRoute

    var body: some View {
        switch route {
        case .browser: NodusBrowserMobileView(session: session)
        case .radar: NodusRadarMobileView(session: session)
        case .toolkit: NodusToolkitMobileView(session: session)
        default: EmptyView()
        }
    }
}

// MARK: - Browser

private struct BrowserTabRecord: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var url: URL
    var command: Int = 0
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var error: String?
}

private struct BrowserBookmarkRecord: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var url: URL
    var createdAt: Date
}

private struct BrowserHistoryRecord: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var url: URL
    var visitedAt: Date
}

@Observable @MainActor
private final class BrowserWorkspaceStore {
    var tabs: [BrowserTabRecord] = [] { didSet { persistTabs() } }
    var activeId: String? { didSet { persistTabs() } }
    var bookmarks: [BrowserBookmarkRecord] = [] { didSet { persistBookmarks() } }
    var history: [BrowserHistoryRecord] = [] { didSet { persistHistory() } }
    var downloads: [URL] = []
    var blockedMessage: String?

    private let defaults: UserDefaults
    private let prefix: String

    init(accountKey: String) {
        defaults = .standard
        prefix = "nodus.browser.\(accountKey).v2"
        tabs = Self.decode([BrowserTabRecord].self, defaults.data(forKey: "\(prefix).tabs")) ?? []
        bookmarks = Self.decode([BrowserBookmarkRecord].self, defaults.data(forKey: "\(prefix).bookmarks")) ?? []
        history = Self.decode([BrowserHistoryRecord].self, defaults.data(forKey: "\(prefix).history")) ?? []
        activeId = defaults.string(forKey: "\(prefix).active")
        if tabs.isEmpty { open(URL(string: "https://www.google.com")!) }
        if !tabs.contains(where: { $0.id == activeId }) { activeId = tabs.first?.id }
    }

    var active: BrowserTabRecord? { tabs.first { $0.id == activeId } }
    var activeIndex: Int? { tabs.firstIndex { $0.id == activeId } }

    func open(_ url: URL, activate: Bool = true) {
        guard NodusWebURLPolicy.isAllowedBrowserURL(url), tabs.count < 24 else {
            blockedMessage = tabs.count >= 24 ? "The browser supports up to 24 open tabs." : "Nodus blocked a local or unsafe address."
            return
        }
        let tab = BrowserTabRecord(id: UUID().uuidString, title: url.host ?? "New tab", url: url, command: 1)
        tabs.append(tab)
        if activate { activeId = tab.id }
    }

    func navigate(_ input: String) {
        guard let id = activeId, let index = tabs.firstIndex(where: { $0.id == id }),
              let destination = NodusWebURLPolicy.browserDestination(for: input) else {
            blockedMessage = "That address is not available in the isolated browser."
            return
        }
        tabs[index].url = destination; tabs[index].command += 1; tabs[index].error = nil
    }

    func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = id == activeId
        tabs.remove(at: index)
        if tabs.isEmpty { open(URL(string: "https://www.google.com")!); return }
        if wasActive { activeId = tabs[min(index, tabs.count - 1)].id }
    }

    func update(_ id: String, url: URL? = nil, title: String? = nil, loading: Bool? = nil,
                canBack: Bool? = nil, canForward: Bool? = nil, error: String? = nil) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if let url, NodusWebURLPolicy.isAllowedBrowserURL(url) { tabs[index].url = url }
        if let title, !title.isEmpty { tabs[index].title = title }
        if let loading { tabs[index].isLoading = loading }
        if let canBack { tabs[index].canGoBack = canBack }
        if let canForward { tabs[index].canGoForward = canForward }
        tabs[index].error = error
    }

    func recordVisit(tabId: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        history.removeAll { $0.url == tab.url }
        history.insert(.init(id: UUID().uuidString, title: tab.title, url: tab.url, visitedAt: Date()), at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
    }

    func toggleBookmark() {
        guard let tab = active else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == tab.url }) { bookmarks.remove(at: index) }
        else { bookmarks.insert(.init(id: UUID().uuidString, title: tab.title, url: tab.url, createdAt: Date()), at: 0) }
    }

    func addDownload(_ url: URL) { downloads.insert(url, at: 0) }
    private func persistTabs() { defaults.set(try? JSONEncoder().encode(tabs), forKey: "\(prefix).tabs"); defaults.set(activeId, forKey: "\(prefix).active") }
    private func persistBookmarks() { defaults.set(try? JSONEncoder().encode(bookmarks), forKey: "\(prefix).bookmarks") }
    private func persistHistory() { defaults.set(try? JSONEncoder().encode(history), forKey: "\(prefix).history") }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? { data.flatMap { try? JSONDecoder().decode(type, from: $0) } }
}

private struct NodusBrowserMobileView: View {
    let session: SpaceSession
    @State private var store: BrowserWorkspaceStore
    @State private var omnibox = ""
    @State private var findText = ""
    @State private var showingFind = false
    @State private var showingBookmarks = false
    @State private var showingHistory = false
    @State private var showingDownloads = false
    @State private var captureStatus: String?

    init(session: SpaceSession) {
        self.session = session
        _store = State(initialValue: BrowserWorkspaceStore(accountKey: session.isDemo ? "demo" : session.connection.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            browserTabs
            browserToolbar
            if showingFind { findBar }
            if let message = store.blockedMessage ?? store.active?.error {
                Label(message, systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(Color.nodusCaution).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.nodusCaution.opacity(0.09))
            }
            ZStack {
                ForEach(store.tabs) { tab in
                    IsolatedBrowserWebView(store: store, tabId: tab.id)
                        .opacity(tab.id == store.activeId ? 1 : 0)
                        .allowsHitTesting(tab.id == store.activeId)
                        .accessibilityHidden(tab.id != store.activeId)
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-workspace")
        .onChange(of: store.activeId, initial: true) { _, _ in omnibox = store.active?.url.absoluteString ?? "" }
        .onChange(of: store.active?.url) { _, url in omnibox = url?.absoluteString ?? "" }
        .alert("Nodus Browser", isPresented: Binding(get: { captureStatus != nil }, set: { if !$0 { captureStatus = nil } })) {
            Button("OK") { captureStatus = nil }
        } message: { Text(captureStatus ?? "") }
        .sheet(isPresented: $showingBookmarks) { browserList(title: "Bookmarks", rows: store.bookmarks.map { ($0.id, $0.title, $0.url) }) }
        .sheet(isPresented: $showingHistory) { browserList(title: "History", rows: store.history.map { ($0.id, $0.title, $0.url) }, clear: { store.history.removeAll() }) }
        .sheet(isPresented: $showingDownloads) { DownloadsSheet(urls: store.downloads, accent: session.accent) }
    }

    private var browserTabs: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(store.tabs) { tab in
                        HStack(spacing: 5) {
                            Button { store.activeId = tab.id } label: {
                                HStack(spacing: 6) {
                                    if tab.isLoading { ProgressView().controlSize(.mini) } else { Image(systemName: "globe") }
                                    Text(tab.title).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                                }.font(.caption).padding(.leading, 11).frame(height: 36)
                            }.buttonStyle(.plain).accessibilityIdentifier("browser-tab")
                            Button { store.close(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 32, height: 36) }
                                .buttonStyle(.plain).accessibilityLabel("Close \(tab.title)").accessibilityIdentifier("browser-tab-close")
                        }
                        .background(tab.id == store.activeId ? Color(uiColor: .systemBackground) : .clear)
                        .overlay(alignment: .bottom) { Rectangle().fill(tab.id == store.activeId ? session.accent : .clear).frame(height: 2) }
                        .overlay(alignment: .trailing) { Divider().frame(height: 18) }
                    }
                }
            }.scrollIndicators(.hidden)
            Button { store.open(URL(string: "https://www.google.com")!) } label: { Image(systemName: "plus").frame(width: 44, height: 36) }
                .buttonStyle(.plain).accessibilityIdentifier("browser-new-tab")
        }
        .frame(height: 36).background(Color(uiColor: .secondarySystemBackground)).overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser-tab-strip")
    }

    private var browserToolbar: some View {
        HStack(spacing: 5) {
            Button { browserCommand(.back) } label: { Image(systemName: "chevron.left") }.disabled(store.active?.canGoBack != true)
            Button { browserCommand(.forward) } label: { Image(systemName: "chevron.right") }.disabled(store.active?.canGoForward != true)
            Button { browserCommand(.reload) } label: { Image(systemName: store.active?.isLoading == true ? "xmark" : "arrow.clockwise") }
            HStack(spacing: 6) {
                Image(systemName: store.active?.url.scheme == "https" ? "lock.fill" : "exclamationmark.triangle.fill").font(.caption2)
                TextField("Search or enter address", text: $omnibox).textInputAutocapitalization(.never).keyboardType(.URL)
                    .onSubmit { store.navigate(omnibox) }.accessibilityIdentifier("browser-omnibox")
                Button { store.toggleBookmark() } label: { Image(systemName: store.bookmarks.contains(where: { $0.url == store.active?.url }) ? "star.fill" : "star") }
                    .accessibilityIdentifier("browser-add-bookmark")
            }.padding(.horizontal, 9).frame(height: 32).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8)).overlay { RoundedRectangle(cornerRadius: 8).stroke(.separator) }
            Menu {
                Button("Find in page", systemImage: "text.magnifyingglass") { showingFind.toggle() }
                Button("Bookmarks", systemImage: "star") { showingBookmarks = true }
                Button("History", systemImage: "clock") { showingHistory = true }
                Button("Downloads", systemImage: "arrow.down.circle") { showingDownloads = true }
                Button("Capture to Library", systemImage: "books.vertical") { captureCurrentPage() }
                if let url = store.active?.url { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 34, height: 32) }
        }
        .buttonStyle(.borderless).padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color(uiColor: .secondarySystemBackground)).overlay(alignment: .bottom) { Divider() }
    }

    private var findBar: some View {
        HStack {
            TextField("Find in page", text: $findText).textFieldStyle(.roundedBorder).onSubmit { browserFind(forward: true) }
            Button { browserFind(forward: false) } label: { Image(systemName: "chevron.up") }
            Button { browserFind(forward: true) } label: { Image(systemName: "chevron.down") }
            Button { showingFind = false; findText = "" } label: { Image(systemName: "xmark") }
        }.padding(7).background(Color(uiColor: .secondarySystemBackground)).accessibilityIdentifier("browser-find-bar")
    }

    private func browserList(title: String, rows: [(String, String, URL)], clear: (() -> Void)? = nil) -> some View {
        NavigationStack { List(rows, id: \.0) { row in Button { store.navigate(row.2.absoluteString); showingBookmarks = false; showingHistory = false } label: { VStack(alignment: .leading) { Text(row.1); Text(row.2.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1) } } }.navigationTitle(title).toolbar { if let clear { Button("Clear", role: .destructive, action: clear) } } }
    }

    private enum BrowserCommand { case back, forward, reload }
    private func browserCommand(_ command: BrowserCommand) {
        guard let id = store.activeId else { return }
        NotificationCenter.default.post(name: .nodusBrowserCommand, object: id, userInfo: ["command": String(describing: command)])
    }
    private func browserFind(forward: Bool) {
        guard let id = store.activeId else { return }
        NotificationCenter.default.post(name: .nodusBrowserFind, object: id, userInfo: ["text": findText, "forward": forward])
    }
    private func captureCurrentPage() {
        guard let tab = store.active else { return }
        Task {
            do { try await BrowserLibraryCapture.capture(tab: tab, session: session); captureStatus = "Saved to your global Library." }
            catch { captureStatus = error.localizedDescription }
        }
    }
}

private extension Notification.Name {
    static let nodusBrowserCommand = Notification.Name("nodus.browser.command")
    static let nodusBrowserFind = Notification.Name("nodus.browser.find")
}

private struct IsolatedBrowserWebView: UIViewRepresentable {
    let store: BrowserWorkspaceStore
    let tabId: String

    func makeCoordinator() -> Coordinator { Coordinator(store: store, tabId: tabId) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator; web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true; web.isInspectable = false
        context.coordinator.attach(web)
        return web
    }
    func updateUIView(_ web: WKWebView, context: Context) {
        guard let tab = store.tabs.first(where: { $0.id == tabId }), context.coordinator.appliedCommand != tab.command else { return }
        context.coordinator.appliedCommand = tab.command
        web.load(URLRequest(url: tab.url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30))
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let store: BrowserWorkspaceStore; let tabId: String; weak var web: WKWebView?
        var appliedCommand = 0
        nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
        init(store: BrowserWorkspaceStore, tabId: String) { self.store = store; self.tabId = tabId }
        deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
        func attach(_ web: WKWebView) {
            self.web = web
            observers.append(NotificationCenter.default.addObserver(forName: .nodusBrowserCommand, object: tabId, queue: .main) { [weak self] note in
                guard let command = note.userInfo?["command"] as? String else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if command.contains("back") { self.web?.goBack() }
                    else if command.contains("forward") { self.web?.goForward() }
                    else if self.web?.isLoading == true { self.web?.stopLoading() } else { self.web?.reload() }
                }
            })
            observers.append(NotificationCenter.default.addObserver(forName: .nodusBrowserFind, object: tabId, queue: .main) { [weak self] note in
                guard let text = note.userInfo?["text"] as? String else { return }
                let backwards = (note.userInfo?["forward"] as? Bool) == false
                Task { @MainActor [weak self] in
                    let configuration = WKFindConfiguration(); configuration.backwards = backwards
                    if let web = self?.web { _ = try? await web.find(text, configuration: configuration) }
                }
            })
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url, NodusWebURLPolicy.isAllowedBrowserURL(url) else {
                store.blockedMessage = "Nodus blocked a local address or unsupported scheme."
                return .cancel
            }
            if action.targetFrame == nil { store.open(url); return .cancel }
            return .allow
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { store.update(tabId, loading: true, canBack: webView.canGoBack, canForward: webView.canGoForward) }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { store.update(tabId, url: webView.url, title: webView.title, loading: false, canBack: webView.canGoBack, canForward: webView.canGoForward); store.recordVisit(tabId: tabId) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { store.update(tabId, loading: false, error: error.localizedDescription) }
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            response.canShowMIMEType ? .allow : .download
        }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
            let folder = URL.documentsDirectory.appendingPathComponent("Nodus Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(suggestedFilename)
            try? FileManager.default.removeItem(at: destination)
            store.addDownload(destination)
            return destination
        }
    }
}

private enum BrowserLibraryCapture {
    @MainActor
    static func capture(tab: BrowserTabRecord, session: SpaceSession) async throws {
        guard !session.isDemo else { return }
        let accountId = try await session.client.me().user.id
        let directory = URL.applicationSupportDirectory.appendingPathComponent("global-library", isDirectory: true)
        let catalog = try await AccountLibraryCatalog.open(accountId: accountId, directory: directory)
        let outbox = try await AccountLibraryOutbox.open(accountId: accountId, directory: directory)
        let item = AccountLibraryItem(metadata: .init(title: tab.title, itemType: "webpage", url: tab.url.absoluteString, tags: ["browser-capture"]), deviceId: LibraryDeviceIdentity.current)
        let version = try await catalog.upsertItem(item, deviceId: LibraryDeviceIdentity.current)
        _ = try await outbox.enqueue(.record(version), title: tab.title)
        _ = try? await outbox.flush(using: session.client)
    }
}

private struct DownloadsSheet: View {
    let urls: [URL]; let accent: Color
    var body: some View { NavigationStack { Group { if urls.isEmpty { ContentUnavailableView("No downloads", systemImage: "arrow.down.circle") } else { List(urls, id: \.self) { url in ShareLink(item: url) { Label(url.lastPathComponent, systemImage: "doc") } } } }.navigationTitle("Downloads").tint(accent) } }
}

// MARK: - Radar

@Observable @MainActor
private final class RadarWorkspaceStore {
    var follows: [RadarFollowRecord] = [] { didSet { save() } }
    var updates: [RadarUpdateRecord] = [] { didSet { save() } }
    var lastCheckedAt: Date? { didSet { save() } }
    var checking = false
    var message: String?
    private let defaults: UserDefaults
    private let key: String
    private let demo: Bool

    init(accountKey: String, demo: Bool) {
        defaults = .standard; key = "nodus.radar.\(accountKey).v1"; self.demo = demo
        if let data = defaults.data(forKey: key), let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            follows = snapshot.follows; updates = snapshot.updates; lastCheckedAt = snapshot.lastCheckedAt
        } else if demo {
            let history = RadarFollowRecord(id: "radar-history", type: .topic, title: "Digital history", value: "digital history", cadence: .daily, sourceNames: ["OpenAlex", "Crossref"])
            let archives = RadarFollowRecord(id: "radar-archives", type: .journal, title: "Archival Science", value: "Archival Science", cadence: .weekly, sourceNames: ["Crossref"])
            follows = [history, archives]
            updates = [
                .init(id: "radar-demo-1", followId: history.id, followTitle: history.title, title: "Knowledge graphs for historical research", authors: "Elena Martín · David Chen", summary: "A reproducible workflow links archival descriptions, entities and interpretive claims.", source: "OpenAlex", url: URL(string: "https://openalex.org"), detectedAt: Date().addingTimeInterval(-3_600)),
                .init(id: "radar-demo-2", followId: archives.id, followTitle: archives.title, title: "New issue: Records, context and trustworthy AI", authors: "Archival Science", summary: "Six contributions on provenance, auditability and machine-assisted description.", source: "Crossref", url: URL(string: "https://www.crossref.org"), detectedAt: Date().addingTimeInterval(-86_400), isRead: true),
            ]
        }
    }

    var unreadCount: Int { updates.count { !$0.isRead } }
    func add(_ follow: RadarFollowRecord) { follows.insert(follow, at: 0) }
    func remove(_ follow: RadarFollowRecord) { follows.removeAll { $0.id == follow.id }; updates.removeAll { $0.followId == follow.id } }
    func toggleRead(_ id: String) { if let index = updates.firstIndex(where: { $0.id == id }) { updates[index].isRead.toggle() } }
    func markAllRead() { for index in updates.indices { updates[index].isRead = true } }
    func markSaved(_ id: String) { if let index = updates.firstIndex(where: { $0.id == id }) { updates[index].savedToLibrary = true } }

    func checkNow() async {
        guard !checking else { return }
        checking = true; defer { checking = false }
        if demo {
            lastCheckedAt = Date(); message = "All sources are up to date."
            return
        }
        var fetched: [RadarUpdateRecord] = []
        for follow in follows where follow.enabled {
            do { fetched.append(contentsOf: try await RadarFetcher.updates(for: follow)) }
            catch { message = error.localizedDescription }
        }
        updates = RadarProjection.merge(updates, incoming: fetched)
        lastCheckedAt = Date()
        if fetched.isEmpty, message == nil { message = "No new updates were detected." }
    }

    private func save() { defaults.set(try? JSONEncoder().encode(Snapshot(follows: follows, updates: updates, lastCheckedAt: lastCheckedAt)), forKey: key) }
    private struct Snapshot: Codable { var follows: [RadarFollowRecord]; var updates: [RadarUpdateRecord]; var lastCheckedAt: Date? }
}

private enum RadarFetcher {
    private struct OpenAlexResponse: Decodable {
        struct Work: Decodable { let id: String; let title: String?; let publication_year: Int?; let doi: String? }
        let results: [Work]
    }
    static func updates(for follow: RadarFollowRecord) async throws -> [RadarUpdateRecord] {
        if follow.type == .rss || follow.type == .website {
            guard let url = URL(string: follow.value), NodusWebURLPolicy.isAllowedRadarSource(url) else { throw RadarFetchError.unsafeURL }
            let (data, response) = try await ephemeralSession.data(from: url)
            guard let finalURL = response.url, NodusWebURLPolicy.isAllowedRadarSource(finalURL), data.count <= 5_000_000 else { throw RadarFetchError.unsafeURL }
            let source = String(decoding: data.prefix(500_000), as: UTF8.self)
            let expression = try NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            let titles = expression.matches(in: source, range: range).prefix(20).compactMap { match -> String? in
                guard match.numberOfRanges > 1, let titleRange = Range(match.range(at: 1), in: source) else { return nil }
                return String(source[titleRange]).replacingOccurrences(of: "<![CDATA[", with: "").replacingOccurrences(of: "]]>", with: "")
            }
            return titles.dropFirst().enumerated().map { offset, title in
                .init(id: stableId("\(follow.id):\(title)"), followId: follow.id, followTitle: follow.title, title: title, source: follow.type == .rss ? "RSS" : "Web monitor", url: finalURL, detectedAt: Date().addingTimeInterval(TimeInterval(-offset)))
            }
        }
        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = [.init(name: "search", value: follow.value), .init(name: "per-page", value: "10"), .init(name: "sort", value: "publication_date:desc")]
        let (data, response) = try await ephemeralSession.data(from: components.url!)
        guard let finalURL = response.url, finalURL.host == "api.openalex.org", data.count <= 5_000_000 else { throw RadarFetchError.unsafeURL }
        return try JSONDecoder().decode(OpenAlexResponse.self, from: data).results.compactMap { work in
            guard let title = work.title, !title.isEmpty else { return nil }
            return .init(id: stableId(work.doi ?? work.id), followId: follow.id, followTitle: follow.title, title: title, authors: work.publication_year.map(String.init) ?? "", source: "OpenAlex", url: URL(string: work.doi ?? work.id))
        }
    }
    private static var ephemeralSession: URLSession { let config = URLSessionConfiguration.ephemeral; config.httpCookieAcceptPolicy = .never; config.timeoutIntervalForResource = 20; return URLSession(configuration: config) }
    private static func stableId(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private enum RadarFetchError: LocalizedError { case unsafeURL; var errorDescription: String? { "Radar only checks public HTTPS sources." } }
}

private struct NodusRadarMobileView: View {
    let session: SpaceSession
    @State private var store: RadarWorkspaceStore
    @State private var tab: RadarTab = .inbox
    @State private var query = ""
    @State private var unreadOnly = false
    @State private var showingFollow = false
    @State private var selectedUpdate: RadarUpdateRecord?
    @State private var saving = false

    private enum RadarTab: String, CaseIterable { case inbox = "Inbox", following = "Following", sources = "Sources" }
    init(session: SpaceSession) {
        self.session = session
        _store = State(initialValue: RadarWorkspaceStore(accountKey: session.isDemo ? "demo" : session.connection.id, demo: session.isDemo))
    }
    var body: some View {
        VStack(spacing: 0) {
            radarHeader
            Picker("Radar view", selection: $tab) { ForEach(RadarTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            switch tab {
            case .inbox: inbox
            case .following: following
            case .sources: sources
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier("radar-view")
        .sheet(isPresented: $showingFollow) { RadarFollowEditor(accent: session.accent) { store.add($0) } }
        .sheet(item: $selectedUpdate) { update in RadarUpdateReader(update: update, accent: session.accent) { saveToLibrary(update) } }
        .alert("Nodus Radar", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) { Button("OK") { store.message = nil } } message: { Text(store.message ?? "") }
    }
    private var radarHeader: some View {
        DesktopPageHeader(title: "Radar", subtitle: store.lastCheckedAt.map { "Last checked \($0.formatted(date: .omitted, time: .shortened)) · \(store.unreadCount) unread" } ?? "Account-wide research monitoring", systemImage: "dot.radiowaves.left.and.right", accent: session.accent) {
            HStack {
                Button { Task { await store.checkNow() } } label: { Label(store.checking ? "Checking…" : "Check now", systemImage: "arrow.clockwise") }.disabled(store.checking).accessibilityIdentifier("radar-check-now")
                Button { showingFollow = true } label: { Label("Follow", systemImage: "plus") }.buttonStyle(.borderedProminent).tint(session.accent).accessibilityIdentifier("radar-follow-open")
            }.buttonStyle(.bordered)
        }.padding(16)
    }
    private var inbox: some View {
        VStack(spacing: 0) {
            HStack { TextField("Search updates", text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("radar-inbox-search"); Toggle("Unread", isOn: $unreadOnly).toggleStyle(.button).accessibilityIdentifier("radar-unread-toggle"); Button("Mark all read") { store.markAllRead() } }
                .font(.caption).padding(12)
            let values = RadarProjection.filtered(store.updates, query: query, unreadOnly: unreadOnly)
            if values.isEmpty { ContentUnavailableView("No radar updates", systemImage: "dot.radiowaves.left.and.right", description: Text("Follow a topic, author, journal, paper, feed or website.")) }
            else { List(values) { update in Button { store.toggleRead(update.id); selectedUpdate = store.updates.first { $0.id == update.id } } label: { RadarUpdateRow(update: update, accent: session.accent) }.buttonStyle(.plain).swipeActions { Button { saveToLibrary(update) } label: { Label("Library", systemImage: "books.vertical") }.tint(session.accent) } }.listStyle(.plain).accessibilityIdentifier("radar-inbox") }
        }
    }
    private var following: some View {
        Group { if store.follows.isEmpty { ContentUnavailableView("Nothing followed yet", systemImage: "plus.circle") } else { List { ForEach(store.follows) { follow in HStack { Image(systemName: radarIcon(follow.type)).foregroundStyle(session.accent); VStack(alignment: .leading) { Text(follow.title).font(.subheadline.weight(.semibold)); Text("\(follow.type.rawValue.capitalized) · \(follow.cadence.rawValue) · \(follow.value)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(store.updates.count { $0.followId == follow.id })").monospacedDigit().foregroundStyle(.secondary) }.swipeActions { Button(role: .destructive) { store.remove(follow) } label: { Label("Remove", systemImage: "trash") } } } }.listStyle(.plain).accessibilityIdentifier("radar-following") } }
    }
    private var sources: some View {
        List { sourceRow("OpenAlex", "Works, authors, topics and citations", true); sourceRow("Crossref", "DOIs, journals and publication metadata", true); sourceRow("ORCID", "Author identity", true); sourceRow("RSS", "Public HTTPS feeds", true); sourceRow("Web monitor", "Public HTTPS pages", true); sourceRow("Desktop Bridge", "Private and Mac-only monitors", false) }.listStyle(.plain).accessibilityIdentifier("radar-sources")
    }
    private func sourceRow(_ name: String, _ detail: String, _ available: Bool) -> some View { HStack { Image(systemName: available ? "checkmark.circle.fill" : "desktopcomputer").foregroundStyle(available ? Color.nodusSuccess : session.accent); VStack(alignment: .leading) { Text(name); Text(detail).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(available ? "Ready" : "On Mac").font(.caption2).foregroundStyle(.secondary) } }
    private func saveToLibrary(_ update: RadarUpdateRecord) {
        guard !saving else { return }; saving = true
        Task { defer { saving = false }; do { try await RadarLibraryCapture.capture(update: update, session: session); store.markSaved(update.id); store.message = "Saved to your global Library." } catch { store.message = error.localizedDescription } }
    }
    private func radarIcon(_ type: RadarFollowType) -> String { switch type { case .topic: "lightbulb"; case .search: "magnifyingglass"; case .author: "person"; case .journal: "book"; case .paper: "quote.opening"; case .rss: "dot.radiowaves.up.forward"; case .website: "globe" } }
}

private struct RadarUpdateRow: View {
    let update: RadarUpdateRecord; let accent: Color
    var body: some View { HStack(alignment: .top, spacing: 11) { Circle().fill(update.isRead ? Color.clear : accent).frame(width: 7, height: 7).padding(.top, 7); VStack(alignment: .leading, spacing: 4) { HStack { Text(update.followTitle).font(.caption2.weight(.semibold)).foregroundStyle(accent); Spacer(); Text(update.detectedAt, style: .relative).font(.caption2).foregroundStyle(.secondary) }; Text(update.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary); if !update.authors.isEmpty { Text(update.authors).font(.caption).foregroundStyle(.secondary) }; Text(update.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2); HStack { Label(update.source, systemImage: "network"); if update.savedToLibrary { Label("Saved", systemImage: "checkmark") } }.font(.caption2).foregroundStyle(.secondary) } }.padding(.vertical, 4) }
}

private struct RadarFollowEditor: View {
    @Environment(\.dismiss) private var dismiss
    let accent: Color; let onSave: (RadarFollowRecord) -> Void
    @State private var type: RadarFollowType = .topic; @State private var title = ""; @State private var value = ""; @State private var cadence: RadarCadence = .daily
    var body: some View { NavigationStack { Form { Picker("Type", selection: $type) { ForEach(RadarFollowType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }; TextField("What to follow", text: $value).textInputAutocapitalization(.never).accessibilityIdentifier("radar-follow-value"); TextField("Display title (optional)", text: $title).accessibilityIdentifier("radar-follow-title-input"); Picker("Cadence", selection: $cadence) { Text("Daily").tag(RadarCadence.daily); Text("Weekly").tag(RadarCadence.weekly) }.pickerStyle(.segmented) }.navigationTitle("Follow research").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { let clean = value.trimmingCharacters(in: .whitespacesAndNewlines); onSave(.init(type: type, title: title.isEmpty ? clean : title, value: clean, cadence: cadence, sourceNames: type == .rss ? ["RSS"] : type == .website ? ["Web monitor"] : ["OpenAlex", "Crossref"])); dismiss() }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).tint(accent).accessibilityIdentifier("radar-follow-save") } } } }
}

private struct RadarUpdateReader: View {
    @Environment(\.dismiss) private var dismiss
    let update: RadarUpdateRecord; let accent: Color; let onSave: () -> Void
    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 16) { Text(update.followTitle.uppercased()).font(.caption.weight(.bold)).foregroundStyle(accent); Text(update.title).font(.title2.bold()); if !update.authors.isEmpty { Text(update.authors).foregroundStyle(.secondary) }; Text(update.summary.isEmpty ? "Radar found this result in \(update.source). Open the source to inspect the complete record." : update.summary).font(.body).lineSpacing(4); if let url = update.url { Link(destination: url) { Label("Open source", systemImage: "arrow.up.right.square") } } }.frame(maxWidth: 720, alignment: .leading).padding(24) }.navigationTitle("Radar update").toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button { onSave() } label: { Image(systemName: update.savedToLibrary ? "checkmark" : "books.vertical") }; Button("Done") { dismiss() } } }.tint(accent) } }
}

private enum RadarLibraryCapture {
    @MainActor
    static func capture(update: RadarUpdateRecord, session: SpaceSession) async throws {
        guard !session.isDemo else { return }
        let accountId = try await session.client.me().user.id
        let directory = URL.applicationSupportDirectory.appendingPathComponent("global-library", isDirectory: true)
        let catalog = try await AccountLibraryCatalog.open(accountId: accountId, directory: directory)
        let outbox = try await AccountLibraryOutbox.open(accountId: accountId, directory: directory)
        let metadata = AccountLibraryMetadata(title: update.title, itemType: "journalArticle", creators: update.authors.isEmpty ? [] : [.init(name: update.authors)], abstract: update.summary, url: update.url?.absoluteString, tags: ["radar", update.followTitle])
        let item = AccountLibraryItem(id: "nodus:radar:\(update.id)", metadata: metadata, deviceId: LibraryDeviceIdentity.current)
        let version = try await catalog.upsertItem(item, deviceId: LibraryDeviceIdentity.current)
        _ = try await outbox.enqueue(.record(version), title: update.title); _ = try? await outbox.flush(using: session.client)
    }
}

// MARK: - Toolkit

private enum ToolkitPage: String, CaseIterable, Identifiable {
    case home, apps, convert, protect, translate, presenter, ocr
    var id: String { rawValue }
    var title: String { switch self { case .home: "Tools"; case .apps: "Apps"; case .convert: "Convert"; case .protect: "Protect"; case .translate: "Translate"; case .presenter: "Presenter"; case .ocr: "OCR" } }
    var icon: String { switch self { case .home: "wrench.and.screwdriver"; case .apps: "square.grid.2x2"; case .convert: "arrow.triangle.2.circlepath"; case .protect: "lock.shield"; case .translate: "character.bubble"; case .presenter: "play.rectangle"; case .ocr: "doc.text.viewfinder" } }
    var detail: String { switch self { case .home: ""; case .apps: "Focused local utilities in an isolated runtime."; case .convert: "Merge PDFs, build PDFs from images, extract text and create checksums."; case .protect: "Encrypt a PDF locally with an owner and reader password."; case .translate: "Translate text with the provider configured on this device."; case .presenter: "Present PDFs fullscreen with page controls and AirPlay mirroring."; case .ocr: "Recognize text in images and PDFs using Apple Vision." } }
}

private struct NodusToolkitMobileView: View {
    @Environment(AISettings.self) private var ai
    let session: SpaceSession
    @State private var page: ToolkitPage = .home

    var body: some View {
        Group {
            switch page {
            case .home: toolkitHome
            case .apps: ToolkitAppsMobileView(session: session, onBack: { page = .home })
            case .convert: ToolkitConvertMobileView(session: session, onBack: { page = .home })
            case .protect: ToolkitProtectMobileView(session: session, onBack: { page = .home })
            case .translate: ToolkitTranslateMobileView(session: session, ai: ai, onBack: { page = .home })
            case .presenter: ToolkitPresenterMobileView(session: session, onBack: { page = .home })
            case .ocr: ToolkitOCRMobileView(session: session, onBack: { page = .home })
            }
        }
        .nodusPageBackdrop(accent: session.accent)
        .accessibilityIdentifier(page == .home ? "toolkit-home" : "toolkit-\(page.rawValue)-page")
    }

    private var toolkitHome: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DesktopPageHeader(title: "Tools", subtitle: "Local utilities for research, teaching and study", systemImage: "wrench.and.screwdriver", accent: session.accent)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(ToolkitPage.allCases.filter { $0 != .home }) { tool in
                        Button { page = tool } label: {
                            VStack(alignment: .leading, spacing: 11) {
                                Image(systemName: tool.icon).font(.title3).foregroundStyle(session.accent.nodusReadable).frame(width: 48, height: 48).background(session.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                                Text(tool.title).font(.headline).foregroundStyle(.primary)
                                Text(tool.detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Label("Available on this device", systemImage: "iphone.and.arrow.forward").font(.caption2.weight(.medium)).foregroundStyle(session.accent)
                            }.padding(18).frame(maxWidth: .infinity, minHeight: 190, alignment: .leading).nodusGlass(NodusGlass(.regular, tint: session.accent), in: RoundedRectangle(cornerRadius: 13))
                        }.buttonStyle(.plain).accessibilityIdentifier("toolkit-card-\(tool.rawValue)")
                    }
                }
                DesktopMacJobsCard(session: session)
            }.frame(maxWidth: 1024).padding(20)
        }
    }
}

private struct ToolkitPageHeader: View {
    let page: ToolkitPage; let accent: Color; let onBack: () -> Void
    var body: some View { HStack(spacing: 11) { Button(action: onBack) { Image(systemName: "chevron.left").frame(width: 36, height: 36).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).accessibilityLabel("Back to Tools"); DesktopPageHeader(title: LocalizedStringKey(page.title), subtitle: page.detail, systemImage: page.icon, accent: accent) }.padding(16).background(Color(uiColor: .systemBackground).opacity(0.85)).overlay(alignment: .bottom) { Divider() } }
}

private struct ToolkitAppsMobileView: View {
    let session: SpaceSession; let onBack: () -> Void
    @State private var selected = "Source comparer"
    private let apps = ["Source comparer", "Chronology sorter", "Citation checklist", "Seminar timer"]
    var body: some View {
        VStack(spacing: 0) {
            ToolkitPageHeader(page: .apps, accent: session.accent, onBack: onBack)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if proxy.size.width >= 700 {
                        List(apps, id: \.self) { app in
                            Button { selected = app } label: {
                                Label(app, systemImage: selected == app ? "checkmark.square.fill" : "square.grid.2x2")
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(width: 250)
                    }
                    LocalToolkitAppView(title: selected)
                        .overlay(alignment: .topLeading) {
                            if proxy.size.width < 700 {
                                Picker("App", selection: $selected) {
                                    ForEach(apps, id: \.self, content: Text.init)
                                }
                                .pickerStyle(.menu)
                                .padding(10)
                            }
                        }
                }
            }
        }
        .accessibilityIdentifier("toolkit-apps-catalog")
    }
}

private struct LocalToolkitAppView: UIViewRepresentable {
    let title: String
    func makeUIView(context: Context) -> WKWebView { let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent(); let view = WKWebView(frame: .zero, configuration: configuration); view.isInspectable = false; return view }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.title != title else { return }; context.coordinator.title = title
        let safe = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        view.loadHTMLString("""
        <!doctype html><meta name="viewport" content="width=device-width"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'">
        <style>body{font:15px -apple-system;margin:0;background:#f5f5f7;color:#202124}.card{max-width:760px;margin:80px auto;padding:32px;background:white;border:1px solid #ddd;border-radius:18px}h1{font-size:24px}textarea{width:100%;height:180px;box-sizing:border-box;border:1px solid #ccc;border-radius:10px;padding:12px}button{margin-top:14px;background:#a16207;color:white;border:0;border-radius:9px;padding:11px 16px}</style><div class="card"><small>NODUS LOCAL APP</small><h1>\(safe)</h1><p>This utility runs inside an isolated, non-persistent WebKit context. It cannot call Nodus APIs or the network.</p><textarea placeholder="Paste working material here…"></textarea><br><button>Process locally</button></div>
        """, baseURL: nil)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var title = "" }
}

private struct ToolkitConvertMobileView: View {
    let session: SpaceSession; let onBack: () -> Void
    @State private var operation: ToolkitOperation = .mergePDF
    @State private var inputs: [URL] = []
    @State private var importing = false
    @State private var working = false
    @State private var output: URL?
    @State private var message: String?
    var body: some View { VStack(spacing: 0) { ToolkitPageHeader(page: .convert, accent: session.accent, onBack: onBack); Form { Picker("Operation", selection: $operation) { Text("Merge PDFs").tag(ToolkitOperation.mergePDF); Text("Images to PDF").tag(ToolkitOperation.imagesToPDF); Text("Extract PDF text").tag(ToolkitOperation.extractPDFText); Text("SHA-256 checksum").tag(ToolkitOperation.checksum) }.accessibilityIdentifier("toolkit-op-picker"); Section("Files") { Button { importing = true } label: { Label("Choose files", systemImage: "plus") }; ForEach(inputs, id: \.self) { Label($0.lastPathComponent, systemImage: "doc") }; if !inputs.isEmpty { Button("Clear", role: .destructive) { inputs.removeAll(); output = nil } } }; Section { Button { run() } label: { if working { ProgressView() } else { Label("Run locally", systemImage: "play.fill") } }.disabled(inputs.isEmpty || working).accessibilityIdentifier("toolkit-run"); if let output { ShareLink(item: output) { Label("Share \(output.lastPathComponent)", systemImage: "square.and.arrow.up") } }; if let message { Text(message).font(.caption).foregroundStyle(.secondary) } } } }.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image, .plainText, .data], allowsMultipleSelection: true) { if case .success(let urls) = $0 { inputs = urls } }.accessibilityIdentifier("toolkit-convert-page") }
    private func run() { working = true; Task { defer { working = false }; do { output = try await ToolkitNativeRunner.run(operation, urls: inputs); message = "Processed completely on this device." } catch { message = error.localizedDescription } } }
}

private struct ToolkitProtectMobileView: View {
    let session: SpaceSession; let onBack: () -> Void
    @State private var input: URL?; @State private var importing = false; @State private var ownerPassword = ""; @State private var userPassword = ""; @State private var output: URL?; @State private var message: String?
    var body: some View { VStack(spacing: 0) { ToolkitPageHeader(page: .protect, accent: session.accent, onBack: onBack); Form { Section("PDF") { Button { importing = true } label: { Label(input?.lastPathComponent ?? "Choose PDF", systemImage: "doc") } }; Section("Encryption") { SecureField("Owner password", text: $ownerPassword); SecureField("Reader password (optional)", text: $userPassword); Text("Passwords never leave this device and are not stored.").font(.caption).foregroundStyle(.secondary) }; Button("Create protected copy") { protect() }.disabled(input == nil || ownerPassword.isEmpty); if let output { ShareLink(item: output) { Label("Share protected PDF", systemImage: "square.and.arrow.up") } }; if let message { Text(message).font(.caption).foregroundStyle(.secondary) } } }.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { if case .success(let url) = $0 { input = url } }.accessibilityIdentifier("toolkit-protect-page") }
    private func protect() { guard let input else { return }; Task { do { output = try ToolkitNativeRunner.protectPDF(input, owner: ownerPassword, user: userPassword); ownerPassword = ""; userPassword = ""; message = "Encrypted locally." } catch { message = error.localizedDescription } } }
}

private struct ToolkitTranslateMobileView: View {
    let session: SpaceSession; let ai: AISettings; let onBack: () -> Void
    @State private var source = ""; @State private var targetLanguage = "English"; @State private var result = ""; @State private var working = false; @State private var message: String?
    private let languages = ["English", "Spanish", "French", "German", "Italian", "Portuguese", "Catalan", "Dutch", "Polish", "Greek", "Turkish", "Arabic", "Hebrew", "Persian", "Hindi", "Chinese", "Japanese", "Korean"]
    var body: some View { VStack(spacing: 0) { ToolkitPageHeader(page: .translate, accent: session.accent, onBack: onBack); ScrollView { VStack(alignment: .leading, spacing: 12) { Picker("Target language", selection: $targetLanguage) { ForEach(languages, id: \.self, content: Text.init) }.pickerStyle(.menu); TextEditor(text: $source).frame(minHeight: 180).padding(8).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10)); Button { translate() } label: { if working { ProgressView() } else { Label("Translate", systemImage: "character.bubble") } }.buttonStyle(.borderedProminent).tint(session.accent).disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working); if !result.isEmpty { Text("Translation").font(.headline); Text(result).textSelection(.enabled).padding(14).desktopContentRow(accent: session.accent); ShareLink(item: result) { Label("Share translation", systemImage: "square.and.arrow.up") } }; if let message { Text(message).font(.caption).foregroundStyle(Color.nodusCaution) } }.frame(maxWidth: 820, alignment: .leading).padding(20) } }.accessibilityIdentifier("toolkit-translate-page") }
    private func translate() { guard let model = ai.model(for: .chat) else { message = "Choose a chat model in Settings first."; return }; working = true; Task { defer { working = false }; do { result = try await ProviderClient(keyProvider: ai.keyProvider).complete(ChatRequest(model: model, messages: [.init(role: .system, content: "Translate faithfully into \(targetLanguage). Preserve paragraphs, citations and Markdown. Return only the translation."), .init(role: .user, content: source)], temperature: 0.1, maxTokens: 4_000)); message = nil } catch { message = error.localizedDescription } } }
}

private struct ToolkitPresenterMobileView: View {
    let session: SpaceSession; let onBack: () -> Void
    @State private var input: URL?; @State private var importing = false; @State private var fullscreen = false
    var body: some View { VStack(spacing: 0) { ToolkitPageHeader(page: .presenter, accent: session.accent, onBack: onBack); if let input { PDFKitView(url: input).overlay(alignment: .topTrailing) { Button { fullscreen = true } label: { Label("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") }.buttonStyle(.borderedProminent).tint(session.accent).padding() } } else { VStack(spacing: 14) { ContentUnavailableView("Choose a PDF to present", systemImage: "play.rectangle", description: Text("Use Control Center to mirror the presentation with AirPlay.")); Button("Choose PDF") { importing = true }.buttonStyle(.borderedProminent).tint(session.accent) } } }.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { if case .success(let url) = $0 { input = url } }.fullScreenCover(isPresented: $fullscreen) { ZStack(alignment: .topTrailing) { Color.black.ignoresSafeArea(); if let input { PDFKitView(url: input, presentation: true) }; Button("Close") { fullscreen = false }.buttonStyle(.borderedProminent).padding() } }.accessibilityIdentifier("toolkit-presenter-page") }
}

private struct ToolkitOCRMobileView: View {
    let session: SpaceSession; let onBack: () -> Void
    @State private var inputs: [URL] = []; @State private var importing = false; @State private var working = false; @State private var output = ""; @State private var message: String?
    var body: some View { VStack(spacing: 0) { ToolkitPageHeader(page: .ocr, accent: session.accent, onBack: onBack); ScrollView { VStack(alignment: .leading, spacing: 14) { Button { importing = true } label: { Label(inputs.isEmpty ? "Choose images or PDF" : "\(inputs.count) file(s) selected", systemImage: "doc.viewfinder") }.buttonStyle(.bordered); Button { recognize() } label: { if working { ProgressView() } else { Label("Recognize locally", systemImage: "text.viewfinder") } }.buttonStyle(.borderedProminent).tint(session.accent).disabled(inputs.isEmpty || working); if !output.isEmpty { TextEditor(text: $output).frame(minHeight: 360).padding(8).background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 10)); ShareLink(item: output) { Label("Share recognized text", systemImage: "square.and.arrow.up") } }; if let message { Text(message).font(.caption).foregroundStyle(.secondary) } }.frame(maxWidth: 900, alignment: .leading).padding(20) } }.fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { if case .success(let urls) = $0 { inputs = urls } }.accessibilityIdentifier("toolkit-ocr-page") }
    private func recognize() { working = true; Task { defer { working = false }; do { output = try await ToolkitNativeRunner.recognize(urls: inputs); message = "Recognition ran with Apple Vision on this device." } catch { message = error.localizedDescription } } }
}

private struct PDFKitView: UIViewRepresentable {
    let url: URL; var presentation = false
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = presentation ? .singlePage : .singlePageContinuous; view.displayDirection = presentation ? .horizontal : .vertical; view.usePageViewController(presentation, withViewOptions: nil); return view }
    func updateUIView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; view.document = PDFDocument(url: url) } }
}

private enum ToolkitNativeRunner {
    enum Failure: LocalizedError { case unreadable, unsupported, write; var errorDescription: String? { switch self { case .unreadable: "A selected file could not be read."; case .unsupported: "The selected files do not match this operation."; case .write: "Nodus could not write the result." } } }
    static func run(_ operation: ToolkitOperation, urls: [URL]) async throws -> URL {
        switch operation {
        case .mergePDF: return try mergePDFs(urls)
        case .imagesToPDF: return try imagesToPDF(urls)
        case .extractPDFText:
            let text = try urls.map { url -> String in let (document, release) = try document(url); defer { release() }; return document.string ?? "" }.joined(separator: "\n\n")
            return try writeText(text, name: "extracted-text.txt")
        case .checksum:
            let lines = try urls.map { url -> String in let data = try read(url); return "\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())  \(url.lastPathComponent)" }
            return try writeText(lines.joined(separator: "\n"), name: "SHA256SUMS.txt")
        default: throw Failure.unsupported
        }
    }
    static func protectPDF(_ url: URL, owner: String, user: String) throws -> URL {
        let (document, release) = try document(url); defer { release() }
        let output = exportURL("protected-\(url.deletingPathExtension().lastPathComponent).pdf")
        let options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: owner, .userPasswordOption: user]
        guard document.write(to: output, withOptions: options) else { throw Failure.write }; return output
    }
    static func recognize(urls: [URL]) async throws -> String {
        var pages: [CGImage] = []
        for url in urls {
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .pdf) == true {
                let (document, release) = try document(url); defer { release() }
                for index in 0..<document.pageCount { if let image = document.page(at: index)?.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox).cgImage { pages.append(image) } }
            } else if let image = UIImage(data: try read(url))?.cgImage { pages.append(image) }
        }
        guard !pages.isEmpty else { throw Failure.unsupported }
        var result: [String] = []
        for image in pages {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            result.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
        }
        return result.joined(separator: "\n\n--- Page ---\n\n")
    }
    private static func mergePDFs(_ urls: [URL]) throws -> URL { let result = PDFDocument(); var destination = 0; for url in urls { let (source, release) = try document(url); defer { release() }; for index in 0..<source.pageCount { if let page = source.page(at: index) { result.insert(page, at: destination); destination += 1 } } }; guard destination > 0 else { throw Failure.unsupported }; let output = exportURL("merged.pdf"); guard result.write(to: output) else { throw Failure.write }; return output }
    private static func imagesToPDF(_ urls: [URL]) throws -> URL { let images = try urls.compactMap { UIImage(data: try read($0)) }; guard !images.isEmpty else { throw Failure.unsupported }; let bounds = CGRect(x: 0, y: 0, width: 595, height: 842); let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in for image in images { context.beginPage(); let scale = min(bounds.width / image.size.width, bounds.height / image.size.height); let size = CGSize(width: image.size.width * scale, height: image.size.height * scale); image.draw(in: CGRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)) } }; let output = exportURL("images.pdf"); try data.write(to: output, options: [.atomic, .completeFileProtectionUnlessOpen]); return output }
    private static func document(_ url: URL) throws -> (PDFDocument, () -> Void) { let access = url.startAccessingSecurityScopedResource(); guard let value = PDFDocument(url: url) else { if access { url.stopAccessingSecurityScopedResource() }; throw Failure.unreadable }; return (value, { if access { url.stopAccessingSecurityScopedResource() } }) }
    private static func read(_ url: URL) throws -> Data { let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; return try Data(contentsOf: url, options: .mappedIfSafe) }
    private static func writeText(_ text: String, name: String) throws -> URL { let url = exportURL(name); try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen]); return url }
    private static func exportURL(_ name: String) -> URL { let directory = URL.documentsDirectory.appendingPathComponent("Nodus Exports", isDirectory: true); try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); let url = directory.appendingPathComponent(name); try? FileManager.default.removeItem(at: url); return url }
}

private struct DesktopMacJobsCard: View {
    let session: SpaceSession
    @State private var selected: ToolkitOperation = .officeToPDF
    @State private var importing = false
    @State private var message: String?
    var body: some View { VStack(alignment: .leading, spacing: 10) { Label("Mac-dependent jobs", systemImage: "desktopcomputer").font(.headline); Text("Word conversion and searchable-PDF OCR use a typed job. The file first becomes an encrypted, account-scoped Library object; no device path or arbitrary command is sent.").font(.caption).foregroundStyle(.secondary); Picker("Job", selection: $selected) { Text("Word to Markdown").tag(ToolkitOperation.officeToPDF); Text("Scanned to searchable PDF").tag(ToolkitOperation.repairDamagedPDF) }.pickerStyle(.segmented); Button { importing = true } label: { Label("Run on the Mac", systemImage: "desktopcomputer.and.arrow.down") }.buttonStyle(.bordered).disabled(session.isDemo); if let message { Text(message).font(.caption).foregroundStyle(.secondary) } }.padding(18).desktopContentRow(accent: session.accent).fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { if case .success(let url) = $0 { Task { do { try await DesktopToolkitQueue.enqueue(url: url, operation: selected, session: session); message = "Queued once for the owner Mac." } catch { message = error.localizedDescription } } } }.accessibilityIdentifier("toolkit-run-on-mac") }
}

private enum DesktopToolkitQueue {
    @MainActor
    static func enqueue(url: URL, operation: ToolkitOperation, session: SpaceSession) async throws {
        guard let command = operation.desktopCommand else { return }
        let accountId = try await session.client.me().user.id
        let directory = URL.applicationSupportDirectory.appendingPathComponent("global-library", isDirectory: true)
        let catalog = try await AccountLibraryCatalog.open(accountId: accountId, directory: directory)
        let outbox = try await AccountLibraryOutbox.open(accountId: accountId, directory: directory)
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let hash = try await catalog.stageObject(data, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream")
        var item = AccountLibraryItem(metadata: .init(title: url.deletingPathExtension().lastPathComponent, itemType: "document", tags: ["toolkit-input"]), deviceId: LibraryDeviceIdentity.current)
        item.attachments = [.init(title: url.lastPathComponent, fileName: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", byteSize: data.count, sha256: hash)]
        let version = try await catalog.upsertItem(item, deviceId: LibraryDeviceIdentity.current)
        _ = try await outbox.enqueue(.record(version), title: item.metadata.title)
        _ = try await catalog.flushObjects(using: session.client); _ = try await outbox.flush(using: session.client)
        let outputFormat = command == "docx-to-text" ? "md" : "pdf"
        _ = try await session.client.createSpaceAction(idempotencyKey: "toolkit:\(command):\(hash)", kind: .toolkitDesktopRun, payload: ["operation": .string(command), "libraryObjectIds": .array([.string(hash)]), "fileNames": .array([.string(url.lastPathComponent)]), "outputFormat": .string(outputFormat)], inputRevision: session.publishedRevision, inputFingerprint: hash, in: session.connection.spaceId)
    }
}
