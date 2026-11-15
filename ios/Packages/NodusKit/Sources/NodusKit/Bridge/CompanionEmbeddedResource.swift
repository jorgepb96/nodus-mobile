import CryptoKit
import Foundation

/// Resolve opaque Desktop resource identities through the existing scoped file
/// contract. The URL is preserved in BlockNote; no filesystem path is accepted.
public struct CompanionEmbeddedResource: Codable, Sendable {
    public struct Identity: Sendable, Equatable {
        public let kind: DesktopBridgeFileKind
        public let id: String
    }
    public let source: String
    public let descriptor: DesktopBridgeFileDescriptor
    public let data: Data
    public static let maximumBytes = 40 * 1024 * 1024
    public static func identity(_ source: String) throws -> Identity {
        guard source.utf8.count <= 8192, let url = URLComponents(string:source),
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
              (url.queryItems ?? []).allSatisfy({ $0.name == "v" }),
              url.percentEncodedPath.hasPrefix("/") else { throw DesktopBridgeError.malformedResponse }
        let encoded = url.percentEncodedPath.dropFirst().split(separator:"/",omittingEmptySubsequences:false)
        let parts = try encoded.map { value -> String in
            guard let id = String(value).removingPercentEncoding, !id.isEmpty, id != ".", id != "..", id.utf8.count <= 2048,
                  !id.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw DesktopBridgeError.malformedResponse }
            return id
        }
        if url.scheme == "nodus-library", url.host == "original", parts.count == 1 { return Identity(kind:.libraryOriginal,id:parts[0]) }
        if url.scheme == "nodus-library", url.host == "attachment", parts.count == 2 {
            return Identity(kind:.libraryAttachment,id:try DesktopLibraryAttachmentIdentity.encode(documentId:parts[0],attachmentId:parts[1]))
        }
        if url.scheme == "nodus-archive", url.host == "file", parts.count == 1,parts[0].count <= 512 { return Identity(kind:.archiveFile,id:parts[0]) }
        throw DesktopBridgeError.malformedResponse
    }
    public static func recordId(source: String) -> String {
        "companion:embedded-resource:v1:" + SHA256.hash(data:Data(source.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    public init(source: String, descriptor: DesktopBridgeFileDescriptor, data: Data, domains: [DesktopBridgeDomain]) throws {
        self.source = source; self.descriptor = descriptor; self.data = data
        try validate(source:source,domains:domains)
    }
    public func validate(source: String, domains: [DesktopBridgeDomain]) throws {
        let identity = try Self.identity(source)
        guard domains.contains(.corpus),domains.contains(identity.kind.domain),
              Set(descriptor.requiredDomains ?? []).isSubset(of:Set(domains)) else { throw DesktopBridgeError.permissionDenied }
        try descriptor.validate()
        guard self.source == source,descriptor.kind == identity.kind,descriptor.id == identity.id,
              descriptor.byteSize >= 0,descriptor.byteSize <= Self.maximumBytes,data.count == descriptor.byteSize,
              SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == descriptor.sha256.lowercased() else { throw DesktopBridgeError.malformedResponse }
    }
    public static func sourceURLs(in value: JSONValue) throws -> [String] {
        let expression = try NSRegularExpression(pattern:#"nodus-(?:library|archive)://[^\s<>"')\]]+"#)
        var found = Set<String>(); var invalid = false
        func visit(_ value: JSONValue) {
            switch value {
            case .string(let text):
                for match in expression.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
                    guard let range = Range(match.range,in:text) else { continue }
                    let source = String(text[range]); do { _ = try identity(source); found.insert(source) } catch { invalid = true }
                }
            case .array(let items): items.forEach(visit)
            case .object(let fields): fields.values.forEach(visit)
            default: break
            }
        }
        visit(value)
        guard !invalid else { throw APIError(status:422,code:"embedded_resource_unavailable",message:"El documento incluye un recurso interno cuya identidad no es válida.") }
        return found.sorted()
    }
    public static func load(client: DesktopBridgeClient, cache: PrivateBridgeCache, vaultId: String, source: String, domains: [DesktopBridgeDomain]) async throws -> Self {
        let identity = try identity(source)
        guard domains.contains(.corpus),domains.contains(identity.kind.domain) else { throw DesktopBridgeError.permissionDenied }
        let key = recordId(source:source),retained = try await cache.data(vaultId:vaultId,domain:.corpus,recordId:key)
        do {
            let descriptor = try await client.fileDescriptor(vaultId:vaultId,kind:identity.kind,id:identity.id,timeout:retained == nil ? nil : 4)
            guard descriptor.byteSize <= maximumBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            let resource = try Self(source:source,descriptor:descriptor,data:try await client.fileData(vaultId:vaultId,descriptor:descriptor),domains:domains)
            try await cache.store(JSONEncoder.nodus.encode(resource),vaultId:vaultId,domain:.corpus,recordId:key)
            return resource
        } catch {
            guard let offline = error as? URLError,
                  [.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed,.timedOut].contains(offline.code),let retained else { throw error }
            let resource = try JSONDecoder.nodus.decode(Self.self,from:retained)
            try resource.validate(source:source,domains:domains);return resource
        }
    }
}
