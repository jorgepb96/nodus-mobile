import CryptoKit
import Foundation
import ImageIO
import UIKit
import NodusKit

/// An explicit, expiring reading selection. It is copied into the authored
/// checkpoint before the first paid call; purging downloads cannot erase a guide.
@MainActor
enum CompanionCompleteGuideSource {
    private static let catalogRecord = "companion:complete-guide:catalog:v1"
    private static let prefix = "companion:complete-guide:source:v1:"
    private static func record(_ request: JSONValue) throws -> String {
        guard let selection = request.objectValue?["completeGuide"]?.objectValue?["selection"]?.objectValue,
              let nodes = selection["nodes"]?.arrayValue, !nodes.isEmpty else { throw DesktopBridgeError.malformedResponse }
        return prefix + SHA256.hash(data: try JSONEncoder.nodus.encode(JSONValue.object(selection))).map { String(format: "%02x", $0) }.joined()
    }
    private static func captured(session: SpaceSession, request: JSONValue) async throws -> JSONValue {
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        let response = try await DesktopBridgeClient(pairing: pairing, token: token).operation(vaultId: vault, method: "getMobileDeepResearchSource", args: [.object([
            "request": request, "generationId": .string(UUID().uuidString.lowercased()), "stage": .string("guideSnapshot"),
            "input": .array([]), "history": .array([]), "replies": .object([:])
        ])])
        guard let value = response.objectValue?["value"], value.objectValue?["kind"] == .string("completeGuide"),
              value.objectValue?["context"]?.objectValue?["vaultId"] == .string(vault),
              try JSONEncoder.nodus.encode(value).count <= 16_000_000 else { throw DesktopBridgeError.malformedResponse }
        return value
    }
    static func source(session: SpaceSession, request: JSONValue) async throws -> JSONValue {
        let downloaded = request.objectValue?["mobileSourceScope"] == .string("device_downloads")
        if !downloaded { return .array([try await captured(session: session, request: request)]) }
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        if let bytes = try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: record(request)).first,
           var value = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes).objectValue,
           var context = value["context"]?.objectValue, context["vaultId"] == .string(vault) {
            context["sourceScope"] = .string("device_downloads"); value["context"] = .object(context)
            return .array([.object(value)])
        }
        var copies: [JSONValue] = []
        var recordIds: Set<String> = [try record(request)]
        for bytes in try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: catalogRecord) {
            if let recordId = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes).objectValue?["sourceRecord"]?.stringValue,
               recordId.hasPrefix(prefix) { recordIds.insert(recordId) }
        }
        for recordId in recordIds.sorted() {
            for bytes in try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: recordId) {
                guard var value = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes).objectValue,
                      var context = value["context"]?.objectValue, context["vaultId"] == .string(vault) else { throw DesktopBridgeError.malformedResponse }
                context["sourceScope"] = .string("device_downloads"); value["context"] = .object(context); copies.append(.object(value))
            }
        }
        guard !copies.isEmpty else { throw APIError(status: 404, code: "complete_guide_not_downloaded", message: "Descarga esta selección completa antes de generar la guía sin el Mac.") }
        guard try JSONEncoder.nodus.encode(copies).count <= 16_000_000 else { throw APIError(status: 413, code: "deep_research_source_too_large", message: "El contexto seleccionado supera 16 MB. Reduce los elementos que llevas juntos.") }
        return .array(copies)
    }
    static func download(session: SpaceSession, request: JSONValue, days: Int) async throws {
        guard [7, 30].contains(days) else { throw DesktopBridgeError.malformedResponse }
        let value = try await captured(session: session, request: request)
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        let recordId = try record(request), cache = try PrivateBridgeCache(pairingId: pairing.id)
        let id = try PrivateBridgeCache.readPackSelectionId(vaultId: vault, recordIds: [recordId, catalogRecord])
        try await cache.saveReadPack(id: id, vaultId: vault, title: "Fuentes de la guía completa", expiresAt: Date().addingTimeInterval(Double(days) * 86_400), records: [.init(domain: .corpus, recordId: recordId, data: try JSONEncoder.nodus.encode(value)),
            .init(domain: .corpus, recordId: catalogRecord, data: try JSONEncoder.nodus.encode(JSONValue.object(["catalog": value.objectValue?["catalog"] ?? .null, "sourceRecord": .string(recordId)])))])
        session.didChangeCompanionDownloads()
    }
    static func catalog(session: SpaceSession) async throws -> JSONValue {
        let (vault, pairing, _) = try privateBridgeConnection(session, domain: .corpus)
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        var sources: [String: JSONValue] = [:], organization: [String: [String: JSONValue]] = [:]
        for bytes in try await cache.downloadedData(vaultId: vault, domain: .corpus, recordId: catalogRecord) {
            let value = try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
            guard let catalog = value.objectValue?["catalog"]?.objectValue else { continue }
            for source in catalog["sources"]?.arrayValue ?? [] {
                if let key = source.objectValue?["sourceKey"]?.stringValue { sources[key] = source }
            }
            for (group, rows) in catalog["organization"]?.objectValue ?? [:] {
                for row in rows.arrayValue ?? [] {
                    if let id = row.objectValue?["id"]?.stringValue { organization[group, default: [:]][id] = row }
                }
            }
        }
        return .object(["sources": .array(sources.keys.sorted().compactMap { sources[$0] }),
            "organization": .object(Dictionary(uniqueKeysWithValues: ["courses", "subjects", "folders", "topics"].map { group in (group, .array((organization[group] ?? [:]).keys.sorted().compactMap { organization[group]?[$0] })) }))])
    }
}

/// Narrow public-resource adapter: only Commons API JSON and Wikimedia raster
/// bytes, including every redirect. The byte and decode limits precede storage.
@MainActor
extension CompanionCompleteGuideSource {
    static func commonsResource(session: SpaceSession, url raw: String, kind: String) async throws -> JSONValue {
        _ = try privateBridgeConnection(session, domain: .corpus)
        guard let url = URL(string: raw), CommonsRedirectPolicy.allowed(url), ["json", "image"].contains(kind),
              (kind == "json" ? url.host == "commons.wikimedia.org" && url.path == "/w/api.php" : url.host == "upload.wikimedia.org") else { throw DesktopBridgeError.permissionDenied }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.httpShouldSetCookies = false
        let connection = URLSession(configuration: configuration, delegate: CommonsRedirectPolicy(), delegateQueue: nil)
        defer { connection.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(kind == "json" ? "application/json" : "image/png,image/jpeg,image/webp,image/gif", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await connection.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
              let final = response.url, CommonsRedirectPolicy.allowed(final) else { throw DesktopBridgeError.malformedResponse }
        let limit = kind == "json" ? 1_048_576 : 5 * 1_048_576
        guard response.expectedContentLength <= Int64(limit) else { throw DesktopBridgeError.malformedResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw DesktopBridgeError.malformedResponse }
            data.append(byte)
        }
        if kind == "json" {
            guard response.mimeType == "application/json" else { throw DesktopBridgeError.malformedResponse }
            return try JSONDecoder.nodus.decode(JSONValue.self, from: data)
        }
        guard ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(response.mimeType ?? ""),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let png = UIImage(cgImage: image).pngData(), png.count <= 5 * 1_048_576 else { throw DesktopBridgeError.malformedResponse }
        return .object(["png": .string(png.base64EncodedString()), "width": .int(Int64(image.width)), "height": .int(Int64(image.height))])
    }
}

private final class CommonsRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated static func allowed(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443) && ["commons.wikimedia.org", "upload.wikimedia.org"].contains(url.host?.lowercased() ?? "")
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, Self.allowed(url) else { return nil }
        return request
    }
}
