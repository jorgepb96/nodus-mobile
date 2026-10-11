import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Private original chat result files")
struct CompanionChatAssetTests {
    private let conversation="b5a7a6a7-8424-43d1-924d-52a5d88f576b",vault="vault-37"
    private func request(_ kind:CompanionChatKind = .research,attachment:Bool=false) throws -> CompanionChatAssetRequest {
        let owner=try CompanionChatAssetRequest.owner(kind:kind,conversationId:conversation,vaultId:vault)
        return CompanionChatAssetRequest(kind:kind,conversationId:conversation,source:"\(attachment ? "nodus-attachment":"nodus-capability")://chat/\(owner)/e12f9503-6c36-4b2e-ac21-a2c3ed9dc5f7")
    }
    @Test("Actual Desktop surface and vault identities scope every original file")
    func owner() throws {
        let wire=Data("[\"assistant\",\"vault-37\",\"\(conversation)\"]".utf8)
        #expect(try CompanionChatAssetRequest.owner(kind:.research,conversationId:conversation,vaultId:vault)==SHA256.hash(data:wire).map{String(format:"%02x",$0)}.joined())
        for kind in CompanionChatKind.allCases { let value=try request(kind);try value.validate(vaultId:vault);#expect(throws:DesktopBridgeError.self){try value.validate(vaultId:"another-vault")} }
        let value=try request()
        #expect(throws:DesktopBridgeError.self){try CompanionChatAssetRequest(kind:.world,conversationId:conversation,source:value.source).validate(vaultId:vault)}
        for suffix in ["?path=/private/file","#fragment","/../other"] { #expect(throws:DesktopBridgeError.self){try CompanionChatAssetRequest(kind:.research,conversationId:conversation,source:value.source+suffix).validate(vaultId:vault)} }
        try request(attachment:true).validate(vaultId:vault)
    }
    @Test("Original integrity and private recording grants remain mandatory after serialization")
    func integrity() throws {
        let value=try request(.study),bytes=Data("Actual immutable attachment".utf8)
        var descriptor=DesktopBridgeFileDescriptor(kind:.chatCapability,id:try value.fileIdentity,filename:"original.txt",mime:"text/plain",byteSize:bytes.count,sha256:SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined(),chunkSize:4*1024*1024)
        descriptor.requiredDomains=[.corpus,.studyRecordings]
        let original=CompanionChatAsset(descriptor:descriptor,data:bytes),restored=try JSONDecoder.nodus.decode(CompanionChatAsset.self,from:JSONEncoder.nodus.encode(original))
        try restored.validate(request:value,vaultId:vault,domains:[.corpus,.studyRecordings]);#expect(restored.data==bytes)
        #expect(throws:DesktopBridgeError.self){try restored.validate(request:value,vaultId:vault,domains:[.corpus])}
        #expect(throws:DesktopBridgeError.self){try CompanionChatAsset(descriptor:descriptor,data:Data("Changed".utf8)).validate(request:value,vaultId:vault,domains:[.corpus,.studyRecordings])}
        var other=DesktopBridgeFileDescriptor(kind:.chatCapability,id:"another-identity",filename:descriptor.filename,mime:descriptor.mime,byteSize:descriptor.byteSize,sha256:descriptor.sha256,chunkSize:descriptor.chunkSize)
        other.requiredDomains=descriptor.requiredDomains
        #expect(throws:DesktopBridgeError.self){try CompanionChatAsset(descriptor:other,data:bytes).validate(request:value,vaultId:vault,domains:[.corpus,.studyRecordings])}
    }
}
