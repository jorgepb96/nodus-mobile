import Foundation
import Testing
@testable import NodusKit

@Suite("Private Bridge document identities")
struct BridgePathTests {
    @Test("encoded document ids survive the client adapter exactly once")
    func encodedIdentity() throws {
        let path = try DesktopBridgeClient.corpusPath(vaultId: "Mac/vault", path: "library/documents/nodus%3Afuente%2Fcaf%C3%A9%25/download.zip", percentEncoded: true)
        let parts = path.split(separator: "/").map { String($0).removingPercentEncoding! }
        #expect(parts[3] == "Mac/vault")
        #expect(parts[7] == "nodus:fuente/café%")
        #expect(!path.contains("%253A"))
    }
    @Test("raw document ids retain literal percent characters")
    func rawIdentity() throws {
        let path = try DesktopBridgeClient.corpusPath(vaultId: "vault", path: "library/documents/nodus:100%", percentEncoded: false)
        #expect(path.hasSuffix("nodus:100%25"))
    }
    @Test("encoded traversal and invalid escapes fail before transport")
    func rejectedPaths() {
        #expect(throws: DesktopBridgeError.self) { try DesktopBridgeClient.corpusPath(vaultId: "vault", path: "library/%2E%2E/files", percentEncoded: true) }
        #expect(throws: DesktopBridgeError.self) { try DesktopBridgeClient.corpusPath(vaultId: "vault", path: "library/%broken", percentEncoded: true) }
    }
}
