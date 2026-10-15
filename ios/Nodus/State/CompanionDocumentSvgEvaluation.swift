import Foundation
import NodusKit
import WebKit

/// The canonical SVG inspector measures real font/layout metrics in a fresh DOM.
/// The expression runs in a separate ephemeral document with no file or network access.
@MainActor final class CompanionDocumentSvgEvaluation: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var expression = ""
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var deadline: Task<Void, Never>?
    private var evaluation: Task<Void, Never>?
    private var settled = false
    private var evaluating = false

    static func evaluate(_ input: JSONValue) async throws -> JSONValue {
        let runtime = CompanionDocumentSvgEvaluation()
        return try await runtime.run(input)
    }

    private func run(_ input: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let script = input.objectValue?["script"]?.stringValue, !script.isEmpty,
              script.utf8.count <= 1_048_576 else { throw DesktopBridgeError.malformedResponse }
        expression = script
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 1000), configuration: configuration)
        view.navigationDelegate = self
        webView = view
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(20))
                        self?.finish(.failure(APIError(status: 408, code: "document_svg_inspection_timeout", message: "La comprobación del visual no terminó. Vuelve a intentarlo.")))
                    } catch { }
                }
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                view.loadHTMLString("<!doctype html><meta charset='utf-8'><meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; style-src 'unsafe-inline'; object-src 'none'; base-uri 'none'; form-action 'none'\"><style>html,body{margin:0;background:white;color:black}</style>", baseURL: nil)
            }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }

    private func finish(_ result: Result<JSONValue, Error>) {
        guard !settled else { return }
        settled = true; deadline?.cancel(); deadline = nil
        evaluation?.cancel(); evaluation = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        expression = ""
        continuation?.resume(with: result); continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !settled, !evaluating else { return }; evaluating = true
        let script = expression
        evaluation = Task { @MainActor [weak self] in
            do {
                let output = try await webView.callAsyncJavaScript(
                    "return JSON.stringify(await (" + script + "))", arguments: [:], in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard let text = output as? String, text.utf8.count <= 1_048_576,
                      let bytes = text.data(using: .utf8) else { throw DesktopBridgeError.malformedResponse }
                self?.finish(.success(try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)))
            } catch { self?.finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // loadHTMLString has no read-access grant. Links and subsequent navigations
        // never inherit a document or the companion's privileged operation bridge.
        decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(APIError(status: 503, code: "document_svg_inspection_interrupted", message: "Se interrumpió la comprobación del visual. Vuelve a intentarlo.")))
    }
}
