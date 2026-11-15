import CryptoKit
import Foundation

public struct CompanionChatAssetRequest: Codable, Sendable, Hashable {
    public let kind: CompanionChatKind
    public let conversationId: String
    public let source: String
    public init(kind:CompanionChatKind,conversationId:String,source:String) { self.kind=kind;self.conversationId=conversationId;self.source=source }
    public static func owner(kind:CompanionChatKind,conversationId:String,vaultId:String) throws -> String {
        let surface = [CompanionChatKind.research:"assistant",.world:"world-assistant",.database:"database",.study:"study"][kind]!
        let data = try JSONSerialization.data(withJSONObject:[surface,vaultId,conversationId],options:[.withoutEscapingSlashes])
        return SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
    public func validate(vaultId:String,scheme:String = "nodus-capability") throws {
        let scheme = scheme=="nodus-capability"&&source.hasPrefix("nodus-attachment://") ? "nodus-attachment":scheme
        let owner = try Self.owner(kind:kind,conversationId:conversationId,vaultId:vaultId)
        let identifier = URLComponents(string:source)?.path.split(separator:"/").last.map(String.init) ?? ""
        let validIdentifier = scheme=="nodus-attachment" ? identifier.range(of:#"^[A-Za-z0-9_-]{1,100}$"#,options:.regularExpression) != nil:UUID(uuidString:identifier) != nil
        guard !vaultId.isEmpty,!conversationId.isEmpty,conversationId.utf8.count<=256,
              source.hasPrefix("\(scheme)://chat/\(owner)/"),let url=URLComponents(string:source),
              url.scheme==scheme,url.host=="chat",url.query==nil,url.fragment==nil,url.user==nil,url.password==nil,url.port==nil,
              url.path=="/\(owner)/\(url.path.split(separator:"/").last ?? "")",
              validIdentifier else { throw DesktopBridgeError.permissionDenied }
    }
    public var value:JSONValue { .object(["kind":.string(kind.rawValue),"conversationId":.string(conversationId),"source":.string(source)]) }
    public var fileIdentity:String { get throws { String(decoding:try JSONEncoder.nodus.encode(self),as:UTF8.self) } }
    public var recordId:String { get throws { "companion:chat-asset:v1:"+SHA256.hash(data:try JSONEncoder.nodus.encode(self)).map { String(format:"%02x",$0) }.joined() } }
}

public struct CompanionChatAsset: Codable, Sendable {
    public let descriptor:DesktopBridgeFileDescriptor
    public let data:Data
    public init(descriptor:DesktopBridgeFileDescriptor,data:Data) { self.descriptor=descriptor;self.data=data }
    public func validate(request:CompanionChatAssetRequest,vaultId:String,domains:[DesktopBridgeDomain]) throws {
        try request.validate(vaultId:vaultId);try descriptor.validate()
        guard let required=descriptor.requiredDomains,required.contains(.corpus),Set(required).isSubset(of:Set(domains)) else { throw DesktopBridgeError.permissionDenied }
        guard descriptor.kind == .chatCapability,descriptor.id == (try request.fileIdentity),
              descriptor.byteSize>=0,(descriptor.byteSize>0||request.source.hasPrefix("nodus-attachment://")),descriptor.byteSize<=64*1024*1024,data.count==descriptor.byteSize,
              SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==descriptor.sha256.lowercased() else { throw DesktopBridgeError.malformedResponse }
    }
    public static func load(client:DesktopBridgeClient,cache:PrivateBridgeCache,vaultId:String,request:CompanionChatAssetRequest,domains:[DesktopBridgeDomain]) async throws -> Self {
        try request.validate(vaultId:vaultId)
        guard domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
        let key=try request.recordId,existing=try await cache.data(vaultId:vaultId,domain:.corpus,recordId:key)
        do {
            let descriptor=try await client.fileDescriptor(vaultId:vaultId,kind:.chatCapability,id:request.fileIdentity,timeout:existing==nil ? nil:4)
            guard descriptor.byteSize>=0,(descriptor.byteSize>0||request.source.hasPrefix("nodus-attachment://")),descriptor.byteSize<=64*1024*1024 else { throw DesktopBridgeError.malformedResponse }
            guard let required=descriptor.requiredDomains,required.contains(.corpus),Set(required).isSubset(of:Set(domains)) else { throw DesktopBridgeError.permissionDenied }
            let result=Self(descriptor:descriptor,data:try await client.fileData(vaultId:vaultId,descriptor:descriptor))
            try result.validate(request:request,vaultId:vaultId,domains:domains)
            try await cache.store(JSONEncoder.nodus.encode(result),vaultId:vaultId,domain:.corpus,recordId:key);return result
        } catch {
            guard let offline=error as? URLError,[.notConnectedToInternet,.networkConnectionLost,.cannotConnectToHost,.cannotFindHost,.dnsLookupFailed,.timedOut].contains(offline.code),let existing else { throw error }
            let result=try JSONDecoder.nodus.decode(Self.self,from:existing);try result.validate(request:request,vaultId:vaultId,domains:domains);return result
        }
    }
}
