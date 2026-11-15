import Foundation
import NodusKit
import CryptoKit

enum ReaderImageSource {
    struct Reference: Identifiable, Hashable {
        let id: String
        let source: String
        let alternative: String
        init(source: String,alternative: String) {
            self.source = source;self.alternative = alternative
            id = SHA256.hash(data:Data(source.utf8)).map{String(format:"%02x",$0)}.joined()
        }
    }
    /// Images add a visual alongside the existing text block. Keeping the text
    /// and block IDs unchanged preserves historical UTF-16 annotation anchors.
    static func references(in markdown: String) -> [Reference] {
        let expression = try! NSRegularExpression(pattern:#"(?<!\\)!\[([^\]\n]*)\]\(\s*(?:<([^<>\n]+)>|([^\s)]+))(?:\s+["'][^"'\n]*["'])?\s*\)"#)
        // Code examples are literal text; their apparent image URLs must never
        // cause network requests. Parse eligible prose without changing it.
        var fence: Character?,fenceLength = 0
        let prose = markdown.components(separatedBy:.newlines).map { line -> String in
            let trim = line.trimmingCharacters(in:.whitespaces)
            if let first = trim.first,first == "`" || first == "~" {
                let count = trim.prefix{$0 == first}.count
                if count >= 3 {
                    if fence == first && count >= fenceLength { fence = nil }
                    else if fence == nil { fence = first;fenceLength = count }
                    return ""
                }
            }
            return fence != nil || line.hasPrefix("    ") || line.hasPrefix("\t") ? "":line
        }.joined(separator:"\n")
        let code = try! NSRegularExpression(pattern:#"`+[^`\n]*`+"#)
        let eligible = code.stringByReplacingMatches(in:prose,range:NSRange(prose.startIndex...,in:prose),withTemplate:"")
        var seen = Set<String>()
        var references = expression.matches(in:eligible,range:NSRange(eligible.startIndex...,in:eligible)).compactMap { match -> Reference? in
            guard let label = Range(match.range(at:1),in:eligible),
                  let target = Range(match.range(at:2).location == NSNotFound ? match.range(at:3):match.range(at:2),in:eligible) else { return nil }
            let source = String(eligible[target])
            guard seen.insert(source).inserted else { return nil }
            return Reference(source:source,alternative:String(eligible[label]))
        }
        let images = try! NSRegularExpression(pattern: #"<img\b([^<>]*)/?>"#, options: [.caseInsensitive])
        for image in images.matches(in: eligible, range: NSRange(eligible.startIndex..., in: eligible)) {
            guard let range = Range(image.range(at: 1), in: eligible) else { continue }
            let attributes = String(eligible[range])
            func attribute(_ name: String) -> String? {
                let pattern = "(?:^|\\s)" + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
                guard let match = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]).firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) else { return nil }
                for group in 1...3 {
                    if let range = Range(match.range(at: group), in: attributes) {
                        var text = String(attributes[range])
                        for (entity, decoded) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: decoded) }
                        return text
                    }
                }
                return nil
            }
            guard let source = attribute("src"), !source.isEmpty, seen.insert(source).inserted else { continue }
            references.append(Reference(source: source, alternative: attribute("alt") ?? ""))
        }
        return references
    }
    static let maximumBytes = 40 * 1024 * 1024
    struct Content { let data: Data;let mime: String }
    @MainActor static func load(_ source: String,session: SpaceSession?, downloadedOnly: Bool = false) async throws -> Content {
        guard source.utf8.count <= 56 * 1024 * 1024,let url = URL(string:source) else { throw DesktopBridgeError.malformedResponse }
        if ["nodus-image","nodus-library","nodus-archive"].contains(url.scheme) {
            guard let session else { throw DesktopBridgeError.permissionDenied }
            let (vault,pairing,token) = try privateBridgeConnection(session,domain:.corpus)
            guard !pairing.isExpired else { throw DesktopBridgeError.expired }
            let cache = try PrivateBridgeCache(pairingId:pairing.id),client = DesktopBridgeClient(pairing:pairing,token:token)
            if url.scheme == "nodus-image" {
                if downloadedOnly {
                    guard let data = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:CompanionCorpusImage.recordId(source:source)).first else { throw APIError(status:409,code:"image_not_downloaded",message:"Esta imagen no está incluida en la descarga. Actualiza el dossier con «Incluir imágenes» cuando Nodus esté conectado.") }
                    let image = try JSONDecoder.nodus.decode(CompanionCorpusImage.self,from:data)
                    try image.validate(source:source,domains:Array(pairing.domains))
                    return Content(data:image.data,mime:image.descriptor.mime)
                }
                let content = try await CompanionCorpusImage.load(client:client,cache:cache,vaultId:vault,source:source,domains:Array(pairing.domains))
                return Content(data:content.data,mime:content.descriptor.mime)
            }
            let content: CompanionEmbeddedResource
            if downloadedOnly {
                guard let data = try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:CompanionEmbeddedResource.recordId(source:source)).first else { throw APIError(status:409,code:"resource_not_downloaded",message:"Este original no está incluido en la descarga. Actualiza el dossier con «Incluir archivos originales» cuando Nodus esté conectado.") }
                content = try JSONDecoder.nodus.decode(CompanionEmbeddedResource.self,from:data)
                try content.validate(source:source,domains:Array(pairing.domains))
            } else { content = try await CompanionEmbeddedResource.load(client:client,cache:cache,vaultId:vault,source:source,domains:Array(pairing.domains)) }
            guard supported(content.descriptor.mime) else { throw DesktopBridgeError.malformedResponse }
            return Content(data:content.data,mime:content.descriptor.mime)
        }
        if source.hasPrefix("data:") {
            let parts = source.split(separator:",",maxSplits:1,omittingEmptySubsequences:false)
            guard parts.count == 2,parts[0].hasSuffix(";base64"),let semicolon = parts[0].firstIndex(of:";"),
                  let data = Data(base64Encoded:String(parts[1])),data.count > 0,data.count <= maximumBytes else { throw DesktopBridgeError.malformedResponse }
            let mime = String(parts[0].dropFirst(5)[..<semicolon]).lowercased()
            guard supported(mime) else { throw DesktopBridgeError.malformedResponse }
            return Content(data:data,mime:mime)
        }
        if downloadedOnly { throw APIError(status:409,code:"external_image_not_downloaded",message:"Esta imagen externa necesita conexión a Internet.") }
        guard url.scheme == "https",url.host != nil,url.user == nil,url.password == nil else { throw DesktopBridgeError.malformedResponse }
        let config = URLSessionConfiguration.ephemeral;config.urlCache = nil
        let client = URLSession(configuration:config);defer { client.invalidateAndCancel() }
        var request = URLRequest(url:url);request.timeoutInterval = 15
        let (stream,response) = try await client.bytes(for:request)
        guard let http = response as? HTTPURLResponse,http.statusCode == 200,http.url?.scheme == "https",let mime = http.mimeType,supported(mime),http.expectedContentLength <= Int64(maximumBytes) else { throw DesktopBridgeError.malformedResponse }
        var data = Data()
        for try await byte in stream {
            if data.count % 65_536 == 0 { try Task.checkCancellation() }
            guard data.count < maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge };data.append(byte)
        }
        guard !data.isEmpty else { throw DesktopBridgeError.malformedResponse }
        return Content(data:data,mime:mime)
    }
    static func supported(_ mime: String) -> Bool {
        ["image/png","image/jpeg","image/jpg","image/gif","image/webp","image/avif","image/heic","image/heif","image/tiff","image/bmp","image/svg+xml"].contains(mime.lowercased())
    }
}
