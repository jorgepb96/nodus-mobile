import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Scriptor scoped embedded resources")
struct CompanionEmbeddedResourceTests {
    @Test("Library and archive addresses retain opaque registered identities")
    func identity() throws {
        let original = try CompanionEmbeddedResource.identity("nodus-library://original/work%2F37?v=file.pdf")
        #expect(original.kind == .libraryOriginal && original.id == "work/37")
        let attachment = try CompanionEmbeddedResource.identity("nodus-library://attachment/work%2F37/asset%2F9?v=revision")
        #expect(attachment.kind == .libraryAttachment)
        #expect(try JSONDecoder().decode([String].self,from:Data(attachment.id.utf8)) == ["work/37","asset/9"])
        #expect(try CompanionEmbeddedResource.identity("nodus-archive://file/archivo%2F37").kind == .archiveFile)
        for invalid in ["https://example.com/a.png","file:///private/a.png","nodus-library://user@original/work","nodus-library://original/work?path=/private/a","nodus-archive://file/..","nodus-library://attachment/work/"] {
            #expect(throws: (any Error).self) { try CompanionEmbeddedResource.identity(invalid) }
        }
    }
    @Test("Selected resource URLs deduplicate without adding external resources")
    func sourceURLs() throws {
        let source = "nodus-library://attachment/work/asset?v=37"
        let document = JSONValue.object(["nativeDocument":.array([.object(["props":.object(["url":.string(source)])])]),"markdown":.string("![Imagen](\(source)) [Enlace](https://example.com/file)")])
        #expect(try CompanionEmbeddedResource.sourceURLs(in:document) == [source])
        #expect(CompanionEmbeddedResource.recordId(source:source) != CompanionEmbeddedResource.recordId(source:"nodus-library://attachment/work/asset?v=38"))
    }
    @Test("An offline archive resource cannot bypass its revoked file grant")
    func grantAndDigest() throws {
        let data = Data("original".utf8),source = "nodus-archive://file/asset"
        let descriptor = DesktopBridgeFileDescriptor(kind:.archiveFile,id:"asset",filename:"original.pdf",mime:"application/pdf",byteSize:data.count,sha256:SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined(),chunkSize:1024)
        let resource = try CompanionEmbeddedResource(source:source,descriptor:descriptor,data:data,domains:[.corpus,.primarySourceFiles])
        let restored = try JSONDecoder.nodus.decode(CompanionEmbeddedResource.self,from:JSONEncoder.nodus.encode(resource))
        #expect(throws:DesktopBridgeError.permissionDenied) { try restored.validate(source:source,domains:[.corpus]) }
        #expect(throws:(any Error).self) { try CompanionEmbeddedResource(source:source,descriptor:descriptor,data:Data("changed".utf8),domains:[.corpus,.primarySourceFiles]) }
    }
}
