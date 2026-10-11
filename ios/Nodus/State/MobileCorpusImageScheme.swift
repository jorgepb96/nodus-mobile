import Foundation
import NodusKit
import WebKit

/// WKWebView keeps the original URL in the document while this scoped native
/// loader supplies verified image bytes. Cancellation never calls a stopped task.
@MainActor final class MobileCorpusImageScheme: NSObject, @preconcurrency WKURLSchemeHandler {
    private let session: SpaceSession
    private let onError: (String) -> Void
    private var tasks: [ObjectIdentifier:Task<Void,Never>] = [:]
    init(session: SpaceSession,onError: @escaping (String) -> Void) { self.session = session; self.onError = onError }
    func webView(_ webView: WKWebView,start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        tasks[key] = Task {
            defer { tasks[key] = nil }
            do {
                guard let url = urlSchemeTask.request.url else { throw DesktopBridgeError.malformedResponse }
                let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
                let client = DesktopBridgeClient(pairing:pairing,token:token)
                let cache = try PrivateBridgeCache(pairingId:pairing.id)
                let image = try await CompanionCorpusImage.load(client:client,cache:cache,vaultId:vault,source:url.absoluteString,domains:pairing.domains)
                try Task.checkCancellation()
                guard tasks[key] != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url:url,mimeType:image.descriptor.mime,expectedContentLength:image.data.count,textEncodingName:nil))
                urlSchemeTask.didReceive(image.data); urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, tasks[key] != nil else { return }
                onError(String(localized:"No se pudo cargar una imagen del contenido. Comprueba la conexión y los permisos del vault."))
                urlSchemeTask.didFailWithError(error)
            }
        }
    }
    func webView(_ webView: WKWebView,stop urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        tasks.removeValue(forKey:key)?.cancel()
    }
    func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
}
