import CryptoKit
import Foundation
import NodusKit
import WebKit

/// Printing streams verified encrypted chunks directly into WebKit. Neither the
/// HTML nor a JavaScript message contains all of a report's PNG bytes.
@MainActor final class CompanionResearchFigureScheme: NSObject, @preconcurrency WKURLSchemeHandler {
    private let session: SpaceSession
    private let context: JSONValue
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var lanes: [Task<Void, Never>?] = Array(repeating: nil, count: 4)
    private var nextLane = 0
    private(set) var failure: Error?
    init(session: SpaceSession, context: JSONValue) { self.session = session; self.context = context }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject), lane = nextLane
        nextLane = (nextLane + 1) % lanes.count
        let previous = lanes[lane]
        let task = Task { @MainActor [weak self] in
            guard let self else { return }; defer { self.tasks.removeValue(forKey: key) }
            do {
                await previous?.value; try Task.checkCancellation()
                if [.string("live-mac"),.string("downloaded-mac")].contains(context.objectValue?["origin"] ?? .null) {
                    guard let url=urlSchemeTask.request.url,CompanionResearchFigures.allows(url.absoluteString,context:context),urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET" else { throw DesktopBridgeError.permissionDenied }
                    func read(_ offset:Int64) async throws -> CompanionLiveDocumentVisualRead.Chunk {
                        if context.objectValue?["origin"] == .string("downloaded-mac") { return try await CompanionDownloadedResearchFigures.chunk(url.absoluteString,context:context,session:session,offset:offset,count:524288) }
                        return try await CompanionLiveDocumentVisualRead.chunk(url.absoluteString,context:context,session:session,offset:offset,count:524288)
                    }
                    let first=try await read(0)
                    guard let response=HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:["Content-Type":first.mime,"Content-Length":String(first.total),"Cache-Control":"no-store","X-Content-Type-Options":"nosniff"]) else { throw DesktopBridgeError.malformedResponse }
                    try Task.checkCancellation();guard tasks[key] != nil else { return }
                    urlSchemeTask.didReceive(response)
                    var offset=0,part=first,hash=SHA256()
                    while offset < first.total {
                        guard part.total == first.total,part.mime == first.mime,part.sha256 == first.sha256 else { throw DesktopBridgeError.malformedResponse }
                        hash.update(data:part.data);urlSchemeTask.didReceive(part.data);offset += part.data.count
                        if offset < first.total { part=try await read(Int64(offset)) }
                        try Task.checkCancellation();guard tasks[key] != nil else { return }
                    }
                    guard hash.finalize().map({String(format:"%02x",$0)}).joined() == first.sha256 else { throw DesktopBridgeError.malformedResponse }
                    urlSchemeTask.didFinish();return
                }
                guard let url = urlSchemeTask.request.url, CompanionResearchFigures.allows(url.absoluteString, context: context),
                      let id = url.path.split(separator: "/").last,
                      let value = context.objectValue?["receipts"]?.arrayValue?.first(where: { $0.objectValue?["id"]?.stringValue?.lowercased() == id.lowercased() }) else { throw DesktopBridgeError.permissionDenied }
                let receipt = try CompanionDocumentFigureAssets.Receipt(value: value), scope = try session.surfaceStorageScope()
                guard receipt.vaultId == scope.recordVaultId, receipt.byteCount <= 8 * 1_048_576,
                      url.path.split(separator: "/").first.map(String.init) == receipt.owner,
                      urlSchemeTask.request.httpMethod == nil || urlSchemeTask.request.httpMethod == "GET" else { throw DesktopBridgeError.permissionDenied }
                let store = CompanionDocumentFigureAssets(cache: try PrivateBridgeCache(pairingId: scope.cacheId), vaultId: scope.recordVaultId)
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": receipt.mimeType, "Content-Length": String(receipt.byteCount), "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]) else { throw DesktopBridgeError.malformedResponse }
                urlSchemeTask.didReceive(response)
                var offset: Int64 = 0
                while offset < receipt.byteCount {
                    try Task.checkCancellation()
                    let count = Int(min(Int64(CompanionDocumentFigureAssets.chunkBytes), receipt.byteCount - offset))
                    let chunk = try await store.read(receipt, offset: offset, count: count)
                    try Task.checkCancellation(); guard tasks[key] != nil else { return }
                    urlSchemeTask.didReceive(chunk); offset += Int64(chunk.count)
                }
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, tasks[key] != nil else { return }
                failure = error; urlSchemeTask.didFailWithError(error)
            }
        }
        tasks[key] = task; lanes[lane] = task
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel()
    }
    func cancelAll() { tasks.values.forEach { $0.cancel() }; tasks.removeAll(); lanes = Array(repeating: nil, count: 4) }
}
