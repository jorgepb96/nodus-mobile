import Foundation
import CryptoKit

/// QR and links carry the certificate pin out of band, before any private request.
public struct DesktopPairingOffer: Codable, Sendable {
    public struct Vault: Codable, Sendable, Identifiable { public let id: String; public let name: String; public let type: VaultType }
    public let version: Int
    public let id: String
    public let code: String
    public let origins: [String]
    public let certificateFingerprint: String
    public let vaultIds: [String]
    public let domains: [DesktopBridgeDomain]
    public let expiresAt: Date
    public let deviceName: String?
    public let macDeviceId: String?
    public let vaults: [Vault]?
    public let relay: DesktopRelayConfiguration?
    public let renewalPairingId: String?

    public static func read(_ text: String, now: Date = Date()) throws -> Self {
        guard text.utf8.count <= 16_384,
              let link = URLComponents(string: text), link.scheme == "nodus", link.host == "pair",
              let parameter = link.queryItems?.first(where: { $0.name == "offer" || $0.name == "q" }),
              let value = parameter.value else {
            throw DesktopBridgeError.malformedResponse
        }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard var data = Data(base64Encoded: base64) else { throw DesktopBridgeError.malformedResponse }
        if parameter.name == "q" {
            guard let fields = try JSONSerialization.jsonObject(with: data) as? [Any], [11, 12].contains(fields.count),
                  let rows = fields[8] as? [[String]], rows.allSatisfy({ $0.count == 3 }),
                  Set(rows.map { $0[0] }).count == rows.count,
                  let mac = fields[10] as? String, UUID(uuidString: mac) != nil else { throw DesktopBridgeError.malformedResponse }
            var full: [String: Any] = ["version": fields[0], "id": fields[1], "code": fields[2], "origins": fields[3],
                "certificateFingerprint": fields[4], "domains": fields[5], "expiresAt": fields[6], "deviceName": fields[7],
                "vaultIds": rows.map { $0[0] }, "vaults": rows.map { ["id": $0[0], "name": $0[1], "type": $0[2]] },
                "relay": fields[9], "macDeviceId": mac]
            if fields.count == 12 {
                guard let renewal = fields[11] as? String, UUID(uuidString: renewal) != nil else { throw DesktopBridgeError.malformedResponse }
                full["renewalPairingId"] = renewal
            }
            data = try JSONSerialization.data(withJSONObject: full)
        }
        let offer = try JSONDecoder.nodus.decode(Self.self, from: data)
        guard offer.version == 2, !offer.vaultIds.isEmpty, !offer.origins.isEmpty else { throw DesktopBridgeError.malformedResponse }
        if let renewal = offer.renewalPairingId, UUID(uuidString: renewal) == nil { throw DesktopBridgeError.malformedResponse }
        guard offer.expiresAt > now else { throw DesktopBridgeError.expired }
        for origin in offer.origins {
            _ = try DesktopBridgePairing(id: offer.id, origin: origin, certificateFingerprint: offer.certificateFingerprint,
                deviceId: "validation", deviceName: "validation", vaultIds: Set(offer.vaultIds), domains: Set(offer.domains), pairedAt: now, expiresAt: offer.expiresAt)
        }
        try offer.relay?.validate()
        return offer
    }

    /// Bonjour discovery is untrusted. The temporary code proves the complete
    /// advertised offer and certificate pin before a token or private request is sent.
    public static func discovered(payload: String, proof: String, code: String, now: Date = Date()) throws -> Self {
        let normalized = code.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        guard normalized.count == 10, payload.utf8.count <= 16_384,
              let signature = decodeURLBase64(proof),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(payload.utf8), using: SymmetricKey(data: Data(normalized.utf8))),
              let data = decodeURLBase64(payload),
              var fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DesktopBridgeError.malformedResponse }
        fields["code"] = normalized
        let encoded = try JSONSerialization.data(withJSONObject: fields).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try read("nodus://pair?offer=\(encoded)", now: now)
    }
    private static func decodeURLBase64(_ value: String) -> Data? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
