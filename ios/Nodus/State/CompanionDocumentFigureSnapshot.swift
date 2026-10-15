import Foundation
import NodusKit
import UIKit
import WebKit

/// Renders the production document figure with explicitly supplied local assets.
/// This temporary view has no native message handlers, cookies or network access.
@MainActor final class CompanionDocumentFigureSnapshot: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var container: UIView?
    private var directory: URL?
    private var payload = ""
    private var continuation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private var evaluation: Task<Void, Never>?
    private var settled = false
    private var evaluating = false

    static func snapshot(_ input: JSONValue) async throws -> String {
        let renderer = CompanionDocumentFigureSnapshot()
        return try await renderer.run(input)
    }

    private func run(_ input: JSONValue) async throws -> String {
        try Task.checkCancellation()
        guard let object = input.objectValue, let owner = object["owner"]?.stringValue,
              owner.count == 64, owner.allSatisfy({ "0123456789abcdef".contains($0) }),
              object["view"]?.objectValue != nil, let assets = object["assets"]?.objectValue,
              assets.count <= 32 else { throw DesktopBridgeError.malformedResponse }
        var assetBytes = 0
        for (id, asset) in assets {
            guard !id.isEmpty, id.utf8.count <= 200, !id.contains("/"), !id.contains("\\"),
                  let fields = asset.objectValue, let mime = fields["mimeType"]?.stringValue,
                  mime.utf8.count <= 128, !mime.contains("\r"), !mime.contains("\n"),
                  let encoded = fields["base64"]?.stringValue, encoded.utf8.count <= 16_777_216,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
                throw DesktopBridgeError.malformedResponse
            }
            assetBytes += bytes.count
            guard assetBytes <= 12 * 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        }
        let data = try JSONEncoder.nodus.encode(input)
        guard data.count <= 16 * 1_048_576, let text = String(data: data, encoding: .utf8) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let url = Bundle.main.url(forResource: "figure-snapshot", withExtension: "html", subdirectory: "SharedDesktop") else {
            throw APIError(status: 503, code: "document_figure_runtime_missing", message: "Esta compilación no incluye el lector de figuras. Actualiza Nodus.")
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: { $0.isKeyWindow }) else {
            throw APIError(status: 409, code: "document_figure_requires_foreground", message: "Abre Nodus para preparar la figura del documento.")
        }
        payload = text
        directory = url.deletingLastPathComponent().standardizedFileURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1048, height: 2300), configuration: configuration)
        view.navigationDelegate = self
        view.isOpaque = true
        view.backgroundColor = .white
        view.scrollView.isScrollEnabled = false
        let staging = UIView(frame: view.frame)
        staging.isUserInteractionEnabled = false
        staging.accessibilityElementsHidden = true
        // WebKit needs a window to render its real layers. A transparent staging
        // container keeps the user's current document and focus undisturbed.
        staging.alpha = 0.01
        staging.addSubview(view)
        window.addSubview(staging)
        container = staging; webView = view
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(45))
                        self?.finish(.failure(APIError(status: 408, code: "document_figure_timeout", message: "La figura no terminó de dibujarse. Vuelve a intentarlo.")))
                    } catch { }
                }
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                view.loadFileURL(url, allowingReadAccessTo: directory!)
            }
        }, onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } })
    }

    private func finish(_ result: Result<String, Error>) {
        guard !settled else { return }
        settled = true; deadline?.cancel(); deadline = nil
        evaluation?.cancel(); evaluation = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        container?.removeFromSuperview(); container = nil
        payload = ""
        continuation?.resume(with: result); continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !settled, !evaluating else { return }; evaluating = true
        let input = payload
        evaluation = Task { @MainActor [weak self] in
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return JSON.stringify(await window.renderDocumentFigure(JSON.parse(payload)))",
                    arguments: ["payload": input], in: nil, contentWorld: .page)
                try Task.checkCancellation()
                guard let text = result as? String, let data = text.data(using: .utf8),
                      let rect = try JSONDecoder.nodus.decode(JSONValue.self, from: data).objectValue,
                      let x = rect["x"]?.doubleValue, let y = rect["y"]?.doubleValue,
                      let width = rect["width"]?.doubleValue, let height = rect["height"]?.doubleValue,
                      [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
                      width >= 10, width <= 1048, height >= 10, height <= 2200,
                      x + width <= 1048, y + height <= 2300 else { throw DesktopBridgeError.malformedResponse }
                let configuration = WKSnapshotConfiguration()
                configuration.rect = CGRect(x: x, y: y, width: width, height: height)
                configuration.snapshotWidth = NSNumber(value: width)
                let image = try await webView.takeSnapshot(configuration: configuration)
                try Task.checkCancellation()
                guard let bytes = image.pngData(), bytes.count <= 8 * 1_048_576,
                      image.size.width > 0, image.size.height > 0 else { throw URLError(.dataLengthExceedsMaximum) }
                self?.finish(.success("data:image/png;base64," + bytes.base64EncodedString()))
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
        finish(.failure(APIError(status: 503, code: "document_figure_interrupted", message: "Se interrumpió la preparación de la figura. Vuelve a intentarlo.")))
    }
}
