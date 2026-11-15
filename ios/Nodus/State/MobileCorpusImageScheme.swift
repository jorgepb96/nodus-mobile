import Foundation
import NodusKit
import WebKit

/// WKWebView keeps the original URL in the document while this scoped native
/// loader supplies verified image bytes. Cancellation never calls a stopped task.
@MainActor final class MobileCorpusImageScheme: NSObject, @preconcurrency WKURLSchemeHandler {
    private let session: SpaceSession
    private let onError: (String) -> Void
    private let maximumRasterPixels: Int?
    private var tasks: [ObjectIdentifier:Task<Void,Never>] = [:]
    init(session: SpaceSession,maximumRasterPixels: Int? = nil,onError: @escaping (String) -> Void) { self.session = session; self.maximumRasterPixels = maximumRasterPixels; self.onError = onError }
    func webView(_ webView: WKWebView,start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        tasks[key] = Task {
            defer { tasks[key] = nil }
            do {
                guard let url = urlSchemeTask.request.url else { throw DesktopBridgeError.malformedResponse }
                let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
                guard !pairing.isExpired else { throw DesktopBridgeError.expired }
                let client = DesktopBridgeClient(pairing:pairing,token:token)
                let cache = try PrivateBridgeCache(pairingId:pairing.id)
                let descriptor: DesktopBridgeFileDescriptor, data: Data
                if url.scheme == "nodus-image" {
                    let image = try await CompanionCorpusImage.load(client:client,cache:cache,vaultId:vault,source:url.absoluteString,domains:Array(pairing.domains))
                    descriptor = image.descriptor; data = image.data
                } else {
                    let resource = try await CompanionEmbeddedResource.load(client:client,cache:cache,vaultId:vault,source:url.absoluteString,domains:Array(pairing.domains))
                    descriptor = resource.descriptor; data = resource.data
                }
                try Task.checkCancellation()
                guard tasks[key] != nil else { return }
                let visual: Data, mime: String
                if let maximumRasterPixels, descriptor.mime.hasPrefix("image/"), descriptor.mime != "image/svg+xml" {
                    guard let preview = try ReaderRasterImage.preview(data, maxPixelSize: maximumRasterPixels).pngData() else { throw DesktopBridgeError.malformedResponse }
                    visual = preview; mime = "image/png"
                } else { visual = data; mime = descriptor.mime }
                // This optional downsample is an ephemeral canvas presentation.
                // The verified original and its cache identity stay unchanged.
                let range = try Self.range(urlSchemeTask.request.value(forHTTPHeaderField:"Range"),size:visual.count)
                let content = range.map { visual.subdata(in:$0) } ?? visual
                var headers = ["Content-Type":mime,"Content-Length":String(content.count),"Accept-Ranges":"bytes","X-Content-Type-Options":"nosniff","Cache-Control":"no-store"]
                if let range { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound-1)/\(visual.count)" }
                guard let response = HTTPURLResponse(url:url,statusCode:range == nil ? 200 : 206,httpVersion:nil,headerFields:headers) else { throw DesktopBridgeError.malformedResponse }
                urlSchemeTask.didReceive(response)
                if urlSchemeTask.request.httpMethod != "HEAD" { urlSchemeTask.didReceive(content) }
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, tasks[key] != nil else { return }
                onError(error.localizedDescription)
                urlSchemeTask.didFailWithError(error)
            }
        }
    }
    func webView(_ webView: WKWebView,stop urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject)
        tasks.removeValue(forKey:key)?.cancel()
    }
    func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
    private static func range(_ header: String?,size: Int) throws -> Range<Int>? {
        guard let header else { return nil }
        let expression = try NSRegularExpression(pattern:#"^bytes=(\d*)-(\d*)$"#)
        guard let match = expression.firstMatch(in:header,range:NSRange(header.startIndex...,in:header)),size > 0,
              let a = Range(match.range(at:1),in:header),let b = Range(match.range(at:2),in:header) else { throw DesktopBridgeError.malformedResponse }
        let start = String(header[a]),end = String(header[b])
        if start.isEmpty {
            guard let length = Int(end),length > 0 else { throw DesktopBridgeError.malformedResponse }
            return max(0,size-length)..<size
        }
        guard let lower = Int(start),lower >= 0,lower < size,let upper = end.isEmpty ? size-1 : Int(end),upper >= lower else { throw DesktopBridgeError.malformedResponse }
        return lower..<(min(upper,size-1)+1)
    }
}
