import CryptoKit
import Foundation

/// Exact native report responses accompany the shared reader's selected download.
/// The catalogue contains only chosen reports; it never replays an old full catalogue.
public struct CompanionResearchCorpusCopy: Sendable {
    public static let recordId = "companion:deep-research-corpus:v1"
    private let entries: [JSONValue]
    private let revision: String

    public init(copies: [JSONValue]) throws {
        guard !copies.isEmpty else { throw DesktopBridgeError.malformedResponse }
        var entries: [JSONValue] = [], seen = Set<String>()
        for copy in copies {
            guard let object = copy.objectValue, object["version"] == .int(1),
                  let values = object["entries"]?.arrayValue, !values.isEmpty else { throw DesktopBridgeError.malformedResponse }
            var ownIds = Set<String>()
            for entry in values {
                guard let fields = entry.objectValue, let detail = fields["detail"],
                      let report = detail.objectValue?["report"]?.objectValue,
                      let id = report["id"]?.stringValue, !id.isEmpty, ownIds.insert(id).inserted,
                      report["draft"]?.objectValue != nil,
                      let html = fields["documentHTML"]?.stringValue, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { throw DesktopBridgeError.malformedResponse }
                let typed = try JSONDecoder.nodus.decode(DeepResearchReportDetail.self, from: JSONEncoder.nodus.encode(detail))
                guard typed.translations.allSatisfy({ $0.string("entity_kind") == "deep_research" && $0.string("entity_id") == id }),
                      typed.annotations?.allSatisfy({ $0.string("draft_id") == id }) != false else { throw DesktopBridgeError.malformedResponse }
                if let image = typed.image {
                    guard let hash = image.string("hash"), let asset = fields["image"]?.objectValue,
                          asset["hash"] == .string(hash), let encoded = asset["base64"]?.stringValue,
                          let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                          asset["mime"]?.stringValue?.hasPrefix("image/") == true,
                          Self.hash(bytes) == hash else { throw DesktopBridgeError.malformedResponse }
                } else if fields["image"] != nil && fields["image"] != .null { throw DesktopBridgeError.malformedResponse }
                // A newer dossier owns its translations, annotations and illustration,
                // including their removal. Older versions cannot fill absent sections.
                if seen.insert(id).inserted { entries.append(entry) }
            }
        }
        self.entries = entries
        revision = "companion:deep-research:" + Self.hash(try JSONEncoder.nodus.encode(JSONValue.array(entries)))
    }

    public static func downloaded(cache: PrivateBridgeCache, vaultId: String) async throws -> Self? {
        let bytes = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: recordId)
        return bytes.isEmpty ? nil : try Self(copies: bytes.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) })
    }

    public func nativeResponse(path: String, query: [URLQueryItem], percentEncoded: Bool) throws -> DesktopBridgeResponse? {
        let parts = try path.split(separator: "/").map { part -> String in
            guard !percentEncoded || String(part).removingPercentEncoding != nil else { throw DesktopBridgeError.invalidOrigin }
            return percentEncoded ? String(part).removingPercentEncoding! : String(part)
        }
        guard Set(query.map(\.name)).count == query.count else { return nil }
        if parts.count == 2, parts[0] == "assets", query.isEmpty {
            guard let asset = entries.compactMap({ $0.objectValue?["image"]?.objectValue }).first(where: { $0["hash"] == .string(parts[1]) }),
                  let bytes = Data(base64Encoded: asset["base64"]!.stringValue!) else { return nil }
            return Self.response(bytes, mime: asset["mime"]!.stringValue!)
        }
        guard parts.first == "deep-research", (1...3).contains(parts.count) else { return nil }
        let result: JSONValue
        if parts.count == 1 {
            guard query.allSatisfy({ ["limit", "offset"].contains($0.name) }) else { return nil }
            let limit = PageBounds.clampedLimit(query.first { $0.name == "limit" }?.value.flatMap(Int.init))
            let offset = PageBounds.clampedOffset(query.first { $0.name == "offset" }?.value.flatMap(Int.init))
            let start = min(offset, entries.count), end = min(start + limit, entries.count)
            let reports = entries[start..<end].map { entry -> JSONValue in
                var report = entry.objectValue!["detail"]!.objectValue!["report"]!.objectValue!
                report["image"] = entry.objectValue!["detail"]!.objectValue!["image"] ?? .null
                return .object(report)
            }
            result = .object(["reports": .array(reports), "total": .int(Int64(entries.count)), "limit": .int(Int64(limit)),
                "offset": .int(Int64(offset)), "hasMore": .bool(end < entries.count), "revision": .string(revision)])
        } else {
            guard query.isEmpty else { return nil }
            guard parts.count == 2 || parts[2] == "document.html" else { return nil }
            guard let entry = entries.first(where: { $0.objectValue?["detail"]?.objectValue?["report"]?.objectValue?["id"] == .string(parts[1]) })
            else { throw CompanionCollectionCopy.CopyError.dossierNotDownloaded }
            if parts.count == 3 { return Self.response(Data(entry.objectValue!["documentHTML"]!.stringValue!.utf8), mime: "text/html; charset=utf-8") }
            var detail = entry.objectValue!["detail"]!.objectValue!
            detail["revision"] = .string(revision); result = .object(detail)
        }
        return Self.response(try JSONEncoder.nodus.encode(result), mime: "application/json")
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func response(_ data: Data, mime: String) -> DesktopBridgeResponse {
        DesktopBridgeResponse(data: data, status: 200, headers: ["content-type": mime, "x-nodus-device-copy": "selected"])
    }
}
