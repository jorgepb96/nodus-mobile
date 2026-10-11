import NodusKit
import NodusUI
import SwiftUI
import UIKit
import WebKit

/// The report keeps its native navigation, tools, search and annotation outbox.
/// Only its formatted body uses the same Markdown/KaTeX renderer as Desktop.
struct RichCorpusProse: View {
    let source: String
    let accent: Color
    let session: SpaceSession?
    let onOpen: (URL) -> Bool
    @Environment(\.nodusReadingStyle) private var reading
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nodusSearchPath) private var searchPath
    @Environment(PageSearch.self) private var search: PageSearch?
    @Environment(ReaderAnnotations.self) private var annotations: ReaderAnnotations?
    @Environment(ReadingBookmarks.self) private var bookmarks: ReadingBookmarks?
    @Environment(PageChatInvite.self) private var chat: PageChatInvite?
    @State private var height: CGFloat = 80
    @State private var issue: String?
    @State private var attempt = 0
    @State private var plain = false
    @State private var image: OpenImage?
    struct OpenImage: Identifiable {
        let id = UUID()
        let content: ReaderImageSource.Content
        let preview: UIImage?
        let title: String
    }
    private var path: PageSearch.Path { searchPath + [0] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if plain {
                CorpusProse(source, accent: accent, session: session, renderRichText: false, onCitation: onOpen)
            } else {
                if let issue {
                    NodusNotice(tone: .blocked, title: "Formato del documento", message: LocalizedStringKey(issue))
                    HStack {
                        Button("Reintentar") { self.issue = nil; attempt += 1 }
                        Button("Mostrar texto") { search?.unregister(path); plain = true }
                    }.frame(minHeight: 44)
                }
                RichProseWebView(source: source, session: session, fontSize: reading.size(.callout, dynamicTypeSize: dynamicTypeSize), accent: accent,
                    dark: colorScheme == .dark, justify: sizeClass == .regular && !dynamicTypeSize.isAccessibilitySize,
                    annotations: annotations, bookmarks: bookmarks, chat: chat, search: search, path: path,
                    height: $height, issue: $issue, onOpen: onOpen, onImage: { image = $0 })
                    .frame(height: height).id(attempt)
                    .id(PageSearchAnchor(path: path))
                    .nodusRevealed(search?.revealed == path)
            }
        }
        .onDisappear { search?.unregister(path) }
        .nodusSheet(item: $image) { item in ReaderImageViewer(content: item.content, image: item.preview, title: item.title, accent: accent) }
    }
    /// Ordinary paragraphs retain the fast TextKit reader. Rich content must
    /// not be flattened into literal table delimiters or mathematical source.
    static func isRequired(_ source: String) -> Bool {
        source.range(of: #"(?m)^\s*\|?.+\|.+\n\s*\|?\s*:?-{3,}:?\s*\|"#, options: .regularExpression) != nil
        || source.range(of: #"(?s)(?<!\\)\${1,2}[^$\n]+\${1,2}|(?m)^\s*\$\$|(?i)<img\b|(?m)^\s*(`{3,}|~{3,})"#, options: .regularExpression) != nil
    }
}

private final class RichProseWKView: WKWebView {
    // Selection handles remain native; all menu entries come from Nodus below.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        builder.replaceChildren(ofMenu: .root) { _ in [] }
    }
    func dismissSystemMenu() {
        func dismiss(_ view: UIView) {
            for item in view.interactions { (item as? UIEditMenuInteraction)?.dismissMenu() }
            for child in view.subviews { dismiss(child) }
        }
        for child in subviews { dismiss(child) }
    }
}

private struct RichProseWebView: UIViewRepresentable {
    @Environment(\.nodusResidentRouteActive) private var routeActive
    let source: String
    let session: SpaceSession?
    let fontSize: CGFloat
    let accent: Color
    let dark: Bool
    let justify: Bool
    let annotations: ReaderAnnotations?
    let bookmarks: ReadingBookmarks?
    let chat: PageChatInvite?
    let search: PageSearch?
    let path: PageSearch.Path
    @Binding var height: CGFloat
    @Binding var issue: String?
    let onOpen: (URL) -> Bool
    let onImage: (RichCorpusProse.OpenImage) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RichProseWKView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "proseRead")
        let view = RichProseWKView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear; view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.scrollView.bounces = false
        view.navigationDelegate = context.coordinator
        view.accessibilityElementsHidden = !routeActive
        context.coordinator.webView = view
        let menu = UIEditMenuInteraction(delegate: context.coordinator); view.addInteraction(menu); context.coordinator.menu = menu
        guard let url = Bundle.main.url(forResource: "prose-read", withExtension: "html", subdirectory: "SharedDesktop") else {
            DispatchQueue.main.async { issue = "El lector de formato completo no está incluido en esta compilación." }; return view
        }
        context.coordinator.root = url
        context.coordinator.deadline = Task { @MainActor [weak coordinator = context.coordinator] in
            do { try await Task.sleep(for: .seconds(20)); guard let coordinator, !coordinator.ready else { return }; coordinator.parent.issue = "El documento no ha podido iniciar su lector. Reintenta la lectura." } catch {}
        }
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }
    func updateUIView(_ view: RichProseWKView, context: Context) {
        view.accessibilityElementsHidden = !routeActive
        context.coordinator.parent = self
        if context.coordinator.ready { context.coordinator.update() }
    }
    static func dismantleUIView(_ view: RichProseWKView, coordinator: Coordinator) {
        coordinator.stopped = true; coordinator.deadline?.cancel(); coordinator.menu?.dismissMenu()
        coordinator.tasks.values.forEach { $0.cancel() }; coordinator.tasks.removeAll()
        coordinator.parent.search?.unregister(coordinator.parent.path)
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "proseRead")
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIEditMenuInteractionDelegate {
        var parent: RichProseWebView
        weak var webView: RichProseWKView?
        var menu: UIEditMenuInteraction?
        var root: URL?
        var ready = false
        var stopped = false
        var deadline: Task<Void, Never>?
        var tasks: [String: Task<Void, Never>] = [:]
        var selection: ReaderAnnotationAnchor?
        var selectedHighlight: ReaderAnnotation?
        var lastHighlighter: ReaderAnnotationAnchor?
        var sent: JSONValue?
        var text: String?
        var images: [String: ReaderImageSource.Content] = [:]
        var imageLanes: [Task<Void, Never>?] = [nil, nil, nil, nil]
        var nextImageLane = 0
        init(_ parent: RichProseWebView) { self.parent = parent }
        func input() -> JSONValue {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(parent.accent).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            func anchor(_ value: ReaderAnnotationAnchor) -> [String: JSONValue] {
                ["startOffset": .int(Int64(value.startOffset)), "endOffset": .int(Int64(value.endOffset)), "selectedText": .string(value.selectedText), "prefix": .string(value.prefix), "suffix": .string(value.suffix)]
            }
            var items = parent.annotations?.items.map { item -> JSONValue in
                .object(anchor(item.anchor).merging(["id": .string(item.id), "kind": .string(item.kind.rawValue), "color": item.color.map { .string($0.rawValue) } ?? .null]) { _, new in new })
            } ?? []
            let legacy = parent.bookmarks?.bookmark
            if parent.annotations == nil, let legacy, legacy.path.starts(with: Array(parent.path.dropLast())) {
                let value = ReaderAnnotationAnchor(startOffset: legacy.location, endOffset: legacy.location + (legacy.snippet as NSString).length, selectedText: legacy.snippet, prefix: "", suffix: "")
                items.append(.object(anchor(value).merging(["id": .string("local-bookmark"), "kind": .string("bookmark"), "color": .null]) { _, new in new }))
            }
            let highlights = parent.search?.highlights(for: parent.path)
            func range(_ value: NSRange) -> JSONValue { .object(["location": .int(Int64(value.location)), "length": .int(Int64(value.length))]) }
            let migration: JSONValue
            if parent.annotations?.isWritable == true, parent.annotations?.bookmark == nil, let legacy, legacy.path.starts(with: Array(parent.path.dropLast())) {
                migration = .object(anchor(ReaderAnnotationAnchor(startOffset: legacy.location, endOffset: legacy.location + (legacy.snippet as NSString).length, selectedText: legacy.snippet, prefix: "", suffix: "")))
            } else { migration = .null }
            return .object(["source": .string(parent.source), "language": .string(Prompts.interfaceLanguage), "dark": .bool(parent.dark), "accent": .string(String(format: "#%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))),
                "fontSize": .double(Double(parent.fontSize)), "justify": .bool(parent.justify), "annotations": .array(items), "highlighter": parent.annotations?.fixedColor.map { .string($0.rawValue) } ?? .null,
                "search": .array(highlights?.ranges.map(range) ?? []), "activeSearch": highlights?.active.map(range) ?? .null, "searchAim": .int(Int64(highlights?.aim ?? 0)),
                "bookmarkAim": .int(Int64(parent.annotations?.bookmarkAim ?? parent.bookmarks?.aim ?? 0)), "legacyBookmark": migration])
        }
        func update(initial: Bool = false) {
            guard let webView, !stopped else { return }
            let value = input(); guard initial || value != sent else { return }; sent = value
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, !self.stopped else { return }
                do {
                    guard try JSONEncoder.nodus.encode(value).count <= 20 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
                    let object = try JSONSerialization.jsonObject(with: JSONEncoder.nodus.encode(value))
                    _ = try await webView.callAsyncJavaScript(initial ? "window.nodusProseRender(input);" : "window.nodusProseUpdate(input);", arguments: ["input": object], in: nil, contentWorld: .page)
                } catch { self.sent = nil; self.parent.issue = error.localizedDescription }
            }
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !stopped, message.frameInfo.isMainFrame, let data = try? JSONSerialization.data(withJSONObject: message.body), data.count <= 56 * 1024 * 1024,
                  let value = try? JSONDecoder.nodus.decode(JSONValue.self, from: data), let fields = value.objectValue, let method = fields["method"]?.stringValue else { return }
            let payload = fields["value"] ?? .null
            switch method {
            case "height":
                guard let number = payload.doubleValue, number.isFinite, number > 0, number <= 2_000_000 else { return }
                if abs(parent.height - CGFloat(number)) > 0.5 { parent.height = CGFloat(number) }
            case "text":
                guard let text = payload.stringValue, text.utf8.count <= 20 * 1024 * 1024, text != self.text else { return }
                self.text = text; parent.search?.register(parent.path, text: text, placesItsOwnMatches: true)
            case "scroll": if let rect = rect(payload) { bringIntoView(rect) }
            case "selection":
                webView?.dismissSystemMenu()
                selectedHighlight = nil
                guard let fields = payload.objectValue, let anchor = anchor(fields["anchor"] ?? .null), let rect = rect(fields["rect"] ?? .null) else { selection = nil; menu?.dismissMenu(); return }
                selection = anchor
                if let annotations = parent.annotations, annotations.isWritable, let color = annotations.fixedColor {
                    if lastHighlighter != anchor { lastHighlighter = anchor; annotations.addHighlight(anchor, color: color) }
                    clearSelection(); return
                }
                menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: "nodus-rich-selection" as NSString, sourcePoint: visiblePoint(rect)))
            case "highlight":
                guard let id = payload.objectValue?["id"]?.stringValue,
                      let item = parent.annotations?.items.first(where: { $0.id == id && $0.kind == .highlight }), let rect = rect(payload.objectValue?["rect"] ?? .null) else { return }
                webView?.dismissSystemMenu(); selectedHighlight = item; selection = item.anchor
                menu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: "nodus-rich-highlight" as NSString, sourcePoint: visiblePoint(rect)))
            case "migrateBookmark":
                guard let annotations = parent.annotations, annotations.isWritable, annotations.bookmark == nil, let anchor = anchor(payload) else { return }
                annotations.setBookmark(anchor); parent.bookmarks?.clear()
            case "annotation":
                if payload.stringValue == "local-bookmark" { parent.bookmarks?.clear() }
                else if let id = payload.stringValue, parent.annotations?.items.contains(where: { $0.id == id }) == true { parent.annotations?.open(id) }
            case "open":
                guard let string = payload.stringValue, string.count <= 4096, let url = URL(string: string) else { return }
                if parent.onOpen(url) { clearSelection(); return }
                if ["https", "http"].contains(url.scheme), url.user == nil, url.password == nil { Task { await UIApplication.shared.open(url) } }
            case "image", "openImage": image(payload, requestId: fields["id"]?.stringValue, opening: method == "openImage")
            case "issue": if let message = payload.stringValue { parent.issue = String(message.prefix(2000)) }
            default: break
            }
        }
        private func anchor(_ value: JSONValue) -> ReaderAnnotationAnchor? {
            guard let fields = value.objectValue, let start = fields["startOffset"]?.intValue, let end = fields["endOffset"]?.intValue,
                  let selected = fields["selectedText"]?.stringValue, start >= 0, end > start, end <= 20 * 1024 * 1024, (selected as NSString).length == end - start,
                  let prefix = fields["prefix"]?.stringValue, let suffix = fields["suffix"]?.stringValue, (prefix as NSString).length <= 64, (suffix as NSString).length <= 64 else { return nil }
            return ReaderAnnotationAnchor(startOffset: Int(start), endOffset: Int(end), selectedText: selected, prefix: prefix, suffix: suffix)
        }
        private func rect(_ value: JSONValue) -> CGRect? {
            guard let fields = value.objectValue, let x = fields["x"]?.doubleValue, let y = fields["y"]?.doubleValue, let width = fields["width"]?.doubleValue, let height = fields["height"]?.doubleValue,
                  [x,y,width,height].allSatisfy(\.isFinite), width >= 0, height >= 0, abs(x) < 2_000_000, abs(y) < 2_000_000 else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        private func clearSelection() {
            selection = nil; selectedHighlight = nil; menu?.dismissMenu()
            webView?.evaluateJavaScript("window.nodusProseClear();", completionHandler: nil)
        }
        private func enclosingScroll() -> UIScrollView? {
            var view = webView?.superview
            while let current = view { if let scroll = current as? UIScrollView { return scroll }; view = current.superview }
            return nil
        }
        private func visiblePoint(_ rect: CGRect) -> CGPoint {
            guard let view = webView, let window = view.window else { return CGPoint(x: rect.midX, y: rect.minY) }
            let visible = view.convert(window.bounds, from: window).intersection(view.bounds)
            return CGPoint(x: min(max(rect.midX, visible.minX + 16), visible.maxX - 16), y: min(max(rect.minY, visible.minY + 16), visible.maxY - 16))
        }
        private func bringIntoView(_ rect: CGRect) {
            guard let view = webView, let scroll = enclosingScroll() else { return }
            let onPage = view.convert(rect, to: scroll).midY, inset = scroll.adjustedContentInset
            let target = onPage - inset.top - (scroll.bounds.height - inset.top - inset.bottom) / 2
            let low = -inset.top, high = max(low, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: min(max(target, low), high)), animated: !UIAccessibility.isReduceMotionEnabled)
        }
        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let anchor = selection else { return nil }
            var actions: [UIMenuElement] = []
            func action(_ title: String, symbol: String, identifier: String, perform: @escaping @MainActor () -> Void) -> UIAction {
                let item = UIAction(title: "", image: UIImage(systemName: symbol)) { [weak self] _ in MainActor.assumeIsolated { perform(); self?.clearSelection() } }
                item.accessibilityLabel = title; item.accessibilityIdentifier = identifier; return item
            }
            actions.append(action(String(localized: "Copy"), symbol: "doc.on.doc", identifier: "nodus-selection-copy") { UIPasteboard.general.string = anchor.selectedText })
            if let annotations = parent.annotations, annotations.isWritable {
                if let selectedHighlight {
                    for color in ReaderAnnotationColor.allCases {
                        let item = UIAction(title: "", image: ReaderHighlightMenuSwatch.image(for: color, selected: selectedHighlight.color == color)) { [weak self] _ in MainActor.assumeIsolated { annotations.updateHighlightColor(selectedHighlight, color: color); self?.clearSelection() } }
                        item.accessibilityLabel = color.localizedLabel; actions.append(item)
                    }
                    actions.append(action(String(localized: "Delete"), symbol: "trash", identifier: "nodus-selection-delete") { annotations.delete(selectedHighlight) })
                } else { actions.append(action(String(localized: "Highlight"), symbol: "highlighter", identifier: "nodus-selection-highlight") { annotations.addHighlight(anchor, color: annotations.selectedColor) }) }
                actions.append(action(String(localized: "Add comment"), symbol: "text.bubble", identifier: "nodus-selection-comment") { annotations.beginComment(anchor) })
                actions.append(action(String(localized: "Reading bookmark"), symbol: annotations.bookmark == nil ? "bookmark" : "bookmark.fill", identifier: "nodus-selection-bookmark") { annotations.setBookmark(anchor) })
            } else if let bookmarks = parent.bookmarks {
                actions.append(action(String(localized: "Reading bookmark"), symbol: "bookmark", identifier: "nodus-selection-bookmark") { [parent] in bookmarks.set(path: parent.path, range: NSRange(location: anchor.startOffset, length: anchor.endOffset - anchor.startOffset), snippet: anchor.selectedText) })
            }
            if let chat = parent.chat { actions.append(action(String(localized: "Ask about this"), symbol: "bubble.left.and.bubble.right", identifier: "nodus-selection-ask") { chat.ask(about: anchor.selectedText) }) }
            return UIMenu(children: [UIMenu(title: "", options: .displayInline, preferredElementSize: .small, children: actions)])
        }
        private func image(_ value: JSONValue, requestId: String?, opening: Bool) {
            let source = opening ? value.objectValue?["source"]?.stringValue : value.stringValue
            guard let source, source.utf8.count <= 56 * 1024 * 1024, (parent.source.contains(source) || ReaderImageSource.references(in: parent.source).contains(where: { $0.source == source })), tasks.count < 256 else {
                if let requestId { reply(requestId, value: .null, error: "La imagen no pertenece a este documento.") }; return
            }
            let taskId = requestId ?? UUID().uuidString, title = value.objectValue?["title"]?.stringValue ?? String(localized: "Image")
            let lane = nextImageLane; nextImageLane = (nextImageLane + 1) % imageLanes.count
            let previous = images[source] == nil ? imageLanes[lane] : nil
            let task = Task { @MainActor [weak self] in
                guard let self else { return }; defer { self.tasks.removeValue(forKey: taskId) }
                do {
                    await previous?.value; try Task.checkCancellation()
                    let content: ReaderImageSource.Content
                    if let cached = self.images[source] { content = cached }
                    else { content = try await ReaderImageSource.load(source, session: self.parent.session) }
                    let preview = content.mime == "image/svg+xml" ? nil : try ReaderRasterImage.preview(content.data)
                    try Task.checkCancellation(); guard !self.stopped else { return }
                    if self.images.values.reduce(0, { $0 + $1.data.count }) + content.data.count <= 64 * 1024 * 1024 { self.images[source] = content }
                    if opening { self.parent.onImage(.init(content: content, preview: preview, title: title)) }
                    else if let requestId {
                        let bytes = preview?.pngData() ?? content.data, mime = preview == nil ? content.mime : "image/png"
                        self.reply(requestId, value: .object(["data": .string(bytes.base64EncodedString()), "mime": .string(mime)]), error: nil)
                    }
                } catch { guard !self.stopped else { return }; if let requestId { self.reply(requestId, value: .null, error: error.localizedDescription) } else { self.parent.issue = error.localizedDescription } }
            }
            tasks[taskId] = task; imageLanes[lane] = task
        }
        private func reply(_ id: String, value: JSONValue, error: String?) {
            guard let webView else { return }
            Task { @MainActor in
                do { let object = try JSONSerialization.jsonObject(with: JSONEncoder.nodus.encode(value), options: [.fragmentsAllowed]); _ = try await webView.callAsyncJavaScript("window.nodusProseReply(id,result,error);", arguments: ["id": id, "result": object, "error": error.map { $0 as Any } ?? NSNull()], in: nil, contentWorld: .page) }
                catch { self.parent.issue = error.localizedDescription }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; deadline?.cancel(); update(initial: true) }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(action.request.url == root ? .allow : .cancel) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { deadline?.cancel(); parent.issue = error.localizedDescription }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { deadline?.cancel(); parent.issue = error.localizedDescription }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.issue = "El lector se ha detenido. Reintenta la lectura." }
    }
}
