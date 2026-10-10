import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Encrypted Desktop relay") struct DesktopRelayTests {
    let configuration = DesktopRelayConfiguration(url: "https://private.nodus.test", id: "11111111-1111-4111-8111-111111111111", keyId: "22222222-2222-4222-8222-222222222222", clientToken: String(repeating: "a", count: 43), secret: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=", expiresAt: Date().addingTimeInterval(3600))
    var fixture: DesktopRelayFrame {
        DesktopRelayFrame(version: 1, keyId: configuration.keyId, clientId: "33333333-3333-4333-8333-333333333333", epoch: "44444444-4444-4444-8444-444444444444", id: "55555555-5555-4555-8555-555555555555", sequence: 0, final: true, sealed: "AQEBAQEBAQEBAQEBWTYf2lC76XRcoix4i1UMvnV8GuIMFJeDKaFkmRZfXo0DN3Z33moyomkuk1Om9Gg=")
    }
    @Test("CryptoKit decrypts the actual Node AES-GCM and HKDF wire format") func interoperability() throws {
        try configuration.validate()
        #expect(try String(data: DesktopRelayCrypto.open(fixture, configuration: configuration, direction: "response"), encoding: .utf8) == "Informe privado — fotografía")
        #expect(throws: (any Error).self) { try DesktopRelayCrypto.open(fixture, configuration: configuration, direction: "request") }
        var tampered = fixture
        var bytes = Data(base64Encoded: fixture.sealed)!
        bytes[20] ^= 1; tampered.sealed = bytes.base64EncodedString()
        #expect(throws: (any Error).self) { try DesktopRelayCrypto.open(tampered, configuration: configuration, direction: "response") }
    }
    @Test("Network fallback never retries an ambiguous write or a certificate failure") func fallback() {
        #expect(DesktopBridgeClient.mayUseRelay(after: URLError(.cannotConnectToHost), method: "POST"))
        #expect(DesktopBridgeClient.mayUseRelay(after: URLError(.networkConnectionLost), method: "GET"))
        #expect(!DesktopBridgeClient.mayUseRelay(after: URLError(.networkConnectionLost), method: "POST"))
        #expect(!DesktopBridgeClient.mayUseRelay(after: URLError(.timedOut), method: "POST"))
        #expect(!DesktopBridgeClient.mayUseRelay(after: URLError(.secureConnectionFailed), method: "GET"))
        #expect(!DesktopBridgeClient.mayUseRelay(after: URLError(.serverCertificateUntrusted), method: "GET"))
    }
}
