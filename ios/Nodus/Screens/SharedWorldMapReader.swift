import Foundation
import NodusKit
import SwiftUI
import WebKit

/// The shared Desktop map renderer only draws and reports selections. Native
/// controls own navigation; there is no generic operation or write bridge.
struct SharedWorldMapReader: UIViewRepresentable {
    let session: SpaceSession
    let source: WorldMapReadSource
    let options: JSONValue
    var onEvent: (JSONValue) -> Void
    var onIssue: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "nodusMapRead")
        let images = MobileCorpusImageScheme(session: session, maximumRasterPixels: 2048, onError: onIssue)
        config.setURLSchemeHandler(images, forURLScheme: "nodus-image")
        context.coordinator.images = images
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false; view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false; view.scrollView.bounces = false
        view.navigationDelegate = context.coordinator; context.coordinator.view = view
        guard let url = Bundle.main.url(forResource: "map-read", withExtension: "html", subdirectory: "SharedDesktop") else {
            Task { @MainActor in onIssue("No se ha incluido el visor de mapas en esta compilación.") }; return view
        }
        context.coordinator.document = url
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        context.coordinator.deadline = Task { @MainActor [weak coordinator = context.coordinator] in
            do { try await Task.sleep(for: .seconds(15)); guard let coordinator, !coordinator.ready, !coordinator.stopped else { return }; coordinator.parent.onIssue("El visor no terminó de cargar. Puedes reintentarlo.") }
            catch {}
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.parent = self; context.coordinator.render() }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stopped = true; coordinator.deadline?.cancel(); coordinator.renderTask?.cancel(); coordinator.images?.cancelAll()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "nodusMapRead"); view.navigationDelegate = nil; view.stopLoading()
    }
    @MainActor final class Coordinator: NSObject, @preconcurrency WKScriptMessageHandler, @preconcurrency WKNavigationDelegate {
        var parent: SharedWorldMapReader
        weak var view: WKWebView?
        var document: URL?
        var images: MobileCorpusImageScheme?
        var ready = false, stopped = false
        var sent: JSONValue?
        var deadline: Task<Void, Never>?, renderTask: Task<Void, Never>?
        init(_ parent: SharedWorldMapReader) { self.parent = parent }
        func render() {
            guard ready, !stopped, let view else { return }
            let input: JSONValue = .object(["source": parent.source.value, "options": parent.options, "imageUrl": parent.source.imageSource.map(JSONValue.string) ?? .null])
            guard input != sent else { return }; sent = input
            renderTask?.cancel()
            renderTask = Task { @MainActor [weak self, weak view] in
                guard let self, let view, !self.stopped else { return }
                do {
                    let object = try JSONSerialization.jsonObject(with: JSONEncoder.nodus.encode(input))
                    try Task.checkCancellation()
                    _ = try await view.callAsyncJavaScript("window.nodusMapReadRender(input);", arguments: ["input": object], in: nil, contentWorld: .page)
                } catch where error.isCancellation {}
                catch { guard !self.stopped else { return }; self.sent = nil; self.parent.onIssue(error.localizedDescription) }
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !stopped, message.frameInfo.isMainFrame, message.webView === view,
                  let body = message.body as? [String: Any], let type = body["type"] as? String,
                  let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 512 * 1024,
                  let value = try? JSONDecoder.nodus.decode(JSONValue.self, from: data) else { return }
            if type == "ready" { ready = true; deadline?.cancel(); render(); return }
            if type == "error" { parent.onIssue(body["message"] as? String ?? "No se pudo abrir el mapa."); return }
            guard ["marker", "child", "scene", "summary"].contains(type), body["mapId"] as? String == parent.source.map.string("mapId") else { return }
            parent.onEvent(value)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { /* The renderer sends ready after installing its typed entry point. */ }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { deadline?.cancel(); parent.onIssue(error.localizedDescription) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { deadline?.cancel(); parent.onIssue(error.localizedDescription) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { parent.onIssue("El visor se ha cerrado para liberar memoria. Puedes reabrirlo.") }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url == document && navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
