import Foundation
import WebKit
import NodusKit

/// Runs the portable Desktop query engine against a selected, protected copy.
/// This renderer has no network access, native operation bridge or tool handlers.
@MainActor final class CompanionDatabaseQueryRuntime: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var directory: URL?
    private var payload = ""
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var deadline: Task<Void, Never>?
    private var evaluation: Task<Void, Never>?
    private var settled = false
    private var evaluating = false

    static func query(_ input: JSONValue) async throws -> JSONValue {
        let runtime = CompanionDatabaseQueryRuntime()
        return try await runtime.run(.object(["kind": .string("container"), "input": input]))
    }

    static func derived(_ source: JSONValue) async throws -> JSONValue {
        let runtime = CompanionDatabaseQueryRuntime()
        return try await runtime.run(.object(["kind": .string("derived"), "source": source]))
    }

    private func run(_ input: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let url = Bundle.main.url(forResource: "database-query", withExtension: "html", subdirectory: "SharedDesktop") else {
            throw APIError(status: 503, code: "database_query_runtime_missing", message: "Esta compilación no incluye el motor de consulta local. Actualiza Nodus.")
        }
        let bytes = try JSONEncoder.nodus.encode(input)
        guard let text = String(data: bytes, encoding: .utf8) else { throw DesktopBridgeError.malformedResponse }
        payload = text; directory = url.deletingLastPathComponent().standardizedFileURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view; view.navigationDelegate = self
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(60))
                        self?.finish(.failure(APIError(status: 408, code: "database_local_query_timeout", message: "La consulta local está tardando demasiado. Vuelve a intentarlo.")))
                    } catch { }
                }
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                view.loadFileURL(url, allowingReadAccessTo: directory!)
            }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }

    private func finish(_ result: Result<JSONValue, Error>) {
        guard !settled else { return }
        settled = true; deadline?.cancel(); deadline = nil
        evaluation?.cancel(); evaluation = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        payload = ""
        continuation?.resume(with: result); continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !settled, !evaluating else { return }; evaluating = true
        let input = payload
        evaluation = Task { @MainActor [weak self] in
            do {
                let output = try await webView.callAsyncJavaScript(
                    "const request = JSON.parse(payload); if (request.kind === 'container') return JSON.stringify(await NodusDatabaseQuery.queryCompanionDatabaseContainer(request.input)); if (request.kind === 'derived') return JSON.stringify(NodusDatabaseQuery.prepareCompanionDatabaseDerived(request.source)); throw new Error('Invalid local query kind');",
                    arguments: ["payload": input], in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard let text = output as? String, let data = text.data(using: .utf8) else { throw DesktopBridgeError.malformedResponse }
                self?.finish(.success(try JSONDecoder.nodus.decode(JSONValue.self, from: data)))
            } catch { self?.finish(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url?.standardizedFileURL, url.isFileURL,
              url.deletingLastPathComponent() == directory else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(APIError(status: 503, code: "database_local_query_interrupted", message: "Se interrumpió la consulta local. Vuelve a intentarlo.")))
    }
}
