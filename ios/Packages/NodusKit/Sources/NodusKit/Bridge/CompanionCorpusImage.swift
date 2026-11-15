import CryptoKit
import Foundation

/// Original bytes retain their internal source identity; hydrated images never
/// replace BlockNote URLs or become edits to a note.
public struct CompanionCorpusImage: Codable, Sendable {
    public let descriptor: DesktopBridgeFileDescriptor
    public let data: Data
    public init(descriptor: DesktopBridgeFileDescriptor, data: Data) throws {
        self.descriptor = descriptor; self.data = data
        try validate(source:descriptor.id,domains:descriptor.requiredDomains ?? [])
    }
    public static func recordId(source: String) -> String {
        "companion:corpus-image:v1:" + SHA256.hash(data:Data(source.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    public static func validSource(_ source: String) -> Bool {
        guard source.count <= 2048, let value = URLComponents(string:source), value.scheme == "nodus-image",
              value.user == nil, value.password == nil, value.port == nil, value.fragment == nil,
              ["portrait","world","map","character-chat","chat","portrait-thumbnail","world-thumbnail","map-thumbnail","character-chat-thumbnail"].contains(value.host ?? ""),
              (value.queryItems ?? []).allSatisfy({ $0.name == "v" }),
              let id = String(value.percentEncodedPath.drop(while: { $0 == "/" })).removingPercentEncoding,
              !id.isEmpty, id.count <= 512 else { return false }
        return true
    }
    public func validate(source: String, domains: [DesktopBridgeDomain]) throws {
        try descriptor.validate()
        guard let required = descriptor.requiredDomains, required.contains(.corpus), Set(required).isSubset(of:Set(domains)) else { throw DesktopBridgeError.permissionDenied }
        guard Self.validSource(source), descriptor.id == source, descriptor.kind == .corpusImage,
              ["image/png","image/jpeg","image/webp","image/gif","image/avif","image/svg+xml"].contains(descriptor.mime),
              descriptor.byteSize > 0, descriptor.byteSize <= 40 * 1024 * 1024,
              data.count == descriptor.byteSize,
              SHA256.hash(data:data).map({ String(format:"%02x",$0) }).joined() == descriptor.sha256.lowercased() else { throw DesktopBridgeError.malformedResponse }
    }
    public static func sourceURLs(in value: JSONValue) throws -> [String] {
        let expression = try NSRegularExpression(pattern:#"nodus-image://[a-z-]+/[^\s<>"')\]]+"#)
        var found = Set<String>()
        var invalid = false
        func visit(_ value: JSONValue) {
            switch value {
            case .string(let string):
                for match in expression.matches(in:string,range:NSRange(string.startIndex...,in:string)) {
                    if let range = Range(match.range,in:string) { let source = String(string[range]); if validSource(source) { found.insert(source) } else { invalid = true } }
                }
            case .array(let items): items.forEach(visit)
            case .object(let fields): fields.values.forEach(visit)
            default: break
            }
        }
        visit(value)
        guard !invalid else { throw APIError(status:422,code:"internal_image_unavailable",message:"El contenido incluye una imagen interna que no se puede descargar con esta versión.") }
        return found.sorted()
    }
    public static func load(client: DesktopBridgeClient, cache: PrivateBridgeCache, vaultId: String, source: String, domains: [DesktopBridgeDomain]) async throws -> Self {
        guard validSource(source), domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
        let key = recordId(source:source)
        let bytes = try await cache.data(vaultId:vaultId,domain:.corpus,recordId:key)
        do {
            let descriptor = try await client.fileDescriptor(vaultId:vaultId,kind:.corpusImage,id:source,timeout:bytes == nil ? nil : 4)
            let content = try await client.fileData(vaultId:vaultId,descriptor:descriptor)
            let image = try Self(descriptor:descriptor,data:content)
            try image.validate(source:source,domains:domains)
            try await cache.store(JSONEncoder.nodus.encode(image),vaultId:vaultId,domain:.corpus,recordId:key)
            return image
        } catch {
            guard let offline = error as? URLError,
                  [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed,.timedOut].contains(offline.code),
                  let bytes else { throw error }
            let image = try JSONDecoder.nodus.decode(Self.self,from:bytes)
            try image.validate(source:source,domains:domains); return image
        }
    }
}
