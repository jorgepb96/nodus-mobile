import CryptoKit
import Foundation
import Testing
import Vision
import ImageIO
@testable import NodusKit

@Suite("Pairing offers") struct DesktopPairingOfferTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private func fields() -> [String: Any] { ["version": 2, "id": "offer", "code": "ABCDE-23456", "origins": ["https://192.168.1.20:7443", "https://100.64.1.20:7443"], "certificateFingerprint": String(repeating: "a", count: 64), "vaultIds": ["vault-a"], "domains": ["corpus", "writing"], "expiresAt": "2023-11-14T22:23:20Z"] }
    private func payload(_ fields: [String: Any]) throws -> String {
        try JSONSerialization.data(withJSONObject: fields).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }
    @Test("QR and links preserve vault identities and HTTPS pins") func link() throws {
        let offer = try DesktopPairingOffer.read("nodus://pair?offer=\(payload(fields()))", now: now)
        #expect(offer.vaultIds == ["vault-a"]); #expect(offer.origins.count == 2); #expect(offer.domains.contains(.writing))
    }
    @Test("expired offers are refused before pairing") func expiry() throws {
        let link = "nodus://pair?offer=\(try payload(fields()))"
        #expect(throws: DesktopBridgeError.expired) { try DesktopPairingOffer.read(link, now: now.addingTimeInterval(3600)) }
    }
    @Test("compact QR keeps all twelve vaults, permissions and the Mac identity") func compact() throws {
        let vaults = (0..<12).map { ["vault-\($0)", "Bóveda \($0)", "academic"] }
        let mac = "d37f3d86-4351-4af4-9cf5-455fa11c098f"
        let fields: [Any] = [2, "offer", "ABCDE-23456", ["https://192.168.1.20:7443"], String(repeating:"a",count:64),
            ["corpus", "writing", "research-generation"], "2023-11-14T22:23:20Z", "Mac de aceptación", vaults, NSNull(), mac]
        let value = try JSONSerialization.data(withJSONObject: fields).base64EncodedString()
        let offer = try DesktopPairingOffer.read("nodus://pair?q=\(value)",now:now)
        #expect(offer.vaults?.count == 12); #expect(offer.vaultIds == vaults.map { $0[0] })
        #expect(offer.vaults?.last?.name == "Bóveda 11"); #expect(offer.domains.contains(.researchGeneration))
        #expect(offer.macDeviceId == mac); #expect(offer.deviceName == "Mac de aceptación")
        var malformed = fields; malformed[8] = [["vault-0", "Bóveda 0"]]
        let bad = try JSONSerialization.data(withJSONObject: malformed).base64EncodedString()
        #expect(throws: DesktopBridgeError.malformedResponse) { try DesktopPairingOffer.read("nodus://pair?q=\(bad)",now:now) }
        malformed[8] = [vaults[0],vaults[0]]
        let duplicate = try JSONSerialization.data(withJSONObject: malformed).base64EncodedString()
        #expect(throws: DesktopBridgeError.malformedResponse) { try DesktopPairingOffer.read("nodus://pair?q=\(duplicate)",now:now) }
    }
    @Test("Vision decodes Desktop's actual QR pixels and Swift reads its wire payload") func barcodeInterop() throws {
        let folder = try #require(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let expected = try JSONDecoder().decode(QRFixture.self,from:Data(contentsOf:folder.appendingPathComponent("desktop-pairing-qr.json")))
        let imageSource = try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent("desktop-pairing-qr.png") as CFURL,nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage:image).perform([request])
        let payload = try #require(request.results?.first?.payloadStringValue)
        #expect(payload == expected.link)
        let offer = try DesktopPairingOffer.read(payload,now:now)
        #expect(offer.vaultIds == expected.vaultIds); #expect(offer.macDeviceId == expected.macDeviceId)
        #expect(offer.relay?.keyId == "efb43a55-3453-4c67-a5b1-c32054212e81")
        #expect(offer.domains.count == 9)
    }
    private struct QRFixture: Decodable { let link: String; let vaultIds:[String]; let macDeviceId:String }
    @Test("renewal links and compact QR preserve the existing grant and reject malformed IDs") func renewal() throws {
        let id = "d37f3d86-4351-4af4-9cf5-455fa11c098f"
        var full = fields(); full["renewalPairingId"] = id
        #expect(try DesktopPairingOffer.read("nodus://pair?offer=\(payload(full))", now: now).renewalPairingId == id)
        let compact: [Any] = [2, "offer", "ABCDE-23456", ["https://192.168.1.20:7443"], String(repeating: "a", count: 64),
            ["corpus", "writing"], "2023-11-14T22:23:20Z", "Mac", [["vault-a", "Vault", "academic"]], NSNull(), id, id]
        let encoded = try JSONSerialization.data(withJSONObject: compact).base64EncodedString()
        #expect(try DesktopPairingOffer.read("nodus://pair?q=\(encoded)", now: now).renewalPairingId == id)
        full["renewalPairingId"] = "invalid"
        #expect(throws: DesktopBridgeError.malformedResponse) { try DesktopPairingOffer.read("nodus://pair?offer=\(payload(full))", now: now) }
    }
    @Test("a code authenticates Bonjour metadata including the certificate pin") func discovery() throws {
        var fields = fields(); fields["code"] = nil
        let advertisement = try payload(fields)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(advertisement.utf8), using: SymmetricKey(data: Data("ABCDE23456".utf8)))).base64EncodedString()
        let offer = try DesktopPairingOffer.discovered(payload: advertisement, proof: signature, code: "ABCDE-23456", now: now)
        #expect(offer.code == "ABCDE23456")
        #expect(throws: DesktopBridgeError.malformedResponse) { try DesktopPairingOffer.discovered(payload: advertisement, proof: signature, code: "WRONG23456", now: now) }
        fields["certificateFingerprint"] = String(repeating: "b", count: 64)
        let forged = try payload(fields)
        #expect(throws: DesktopBridgeError.malformedResponse) { try DesktopPairingOffer.discovered(payload: forged, proof: signature, code: "ABCDE23456", now: now) }
    }
}
