import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Scoped internal companion images")
struct CompanionCorpusImageTests {
    private let source = "nodus-image://portrait/person%2F37?v=2"
    private let png = Data(base64Encoded:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aE9sAAAAASUVORK5CYII=")!
    private func descriptor() -> DesktopBridgeFileDescriptor {
        var value = DesktopBridgeFileDescriptor(kind:.corpusImage,id:source,filename:"Nodus.png",mime:"image/png",byteSize:png.count,
            sha256:SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined(),chunkSize:128)
        value.requiredDomains = [.corpus,.prosopographyPrivate]; return value
    }
    @Test("original bytes and private image grants survive encoding and reject corruption or revoked permissions")
    func roundtrip() throws {
        let image = try CompanionCorpusImage(descriptor:descriptor(),data:png)
        let restored = try JSONDecoder.nodus.decode(CompanionCorpusImage.self,from:JSONEncoder.nodus.encode(image))
        try restored.validate(source:source,domains:[.corpus,.prosopographyPrivate])
        #expect(restored.data == png)
        #expect(throws: DesktopBridgeError.self) { try restored.validate(source:source,domains:[.corpus]) }
        #expect(throws: DesktopBridgeError.self) { try CompanionCorpusImage(descriptor:descriptor(),data:Data("Changed".utf8)) }
        #expect(throws: DesktopBridgeError.self) { try restored.validate(source:"nodus-image://portrait/another",domains:[.corpus,.prosopographyPrivate]) }
    }
    @Test("images are collected once without rewriting the native document or accepting external URLs")
    func sourceSelection() throws {
        let value = JSONValue.object(["nativeDocument":.array([.object(["props":.object(["url":.string(source)])])]),
            "contentMarkdown":.string("![Nodus](\(source)) and [external](https://example.com/image.png)")])
        #expect(try CompanionCorpusImage.sourceURLs(in:value) == [source])
        #expect(!CompanionCorpusImage.validSource("https://example.com/image.png"))
        #expect(!CompanionCorpusImage.validSource("nodus-image://user@portrait/person"))
        #expect(!CompanionCorpusImage.validSource("nodus-image://portrait/person?file=/private/file"))
        #expect(CompanionCorpusImage.validSource("nodus-image://world-thumbnail/source%2F37?v=2"))
        #expect(CompanionCorpusImage.recordId(source:source) != CompanionCorpusImage.recordId(source:"nodus-image://portrait/person%2F37?v=3"))
    }
}
