import Foundation
import Security

struct DesktopPendingPairing: Codable, Sendable {
    let offer: DesktopPairingOffer
    let deviceId: String
    let deviceName: String
    let token: String
}

extension DesktopBridgeClient {
    /// Recovery is a read authenticated by the credential stored *before* the
    /// single-use POST. A timeout never causes an automatic duplicate POST.
    static func pair(offer: DesktopPairingOffer, deviceId: String, deviceName: String,
                     store: DesktopBridgePairingStore, session: URLSession) async throws -> (pairing: DesktopBridgePairing, token: String) {
        guard let origin = offer.origins.first else { throw DesktopBridgeError.invalidOrigin }
        let existing = offer.renewalPairingId.flatMap { id in store.pairings().first { $0.id == id } }
        if offer.renewalPairingId != nil {
            guard let existing, !existing.isExpired,
                  existing.certificateFingerprint == DesktopBridgePairing.normalizedFingerprint(offer.certificateFingerprint).lowercased(),
                  existing.wholeWorkspace == offer.wholeWorkspace,
                  existing.wholeWorkspace == true || existing.vaultIds == Set(offer.vaultIds),
                  existing.macDeviceId == nil || offer.macDeviceId == nil || existing.macDeviceId == offer.macDeviceId,
                  existing.domains == Set(offer.domains),
                  store.credential(for: existing) != nil else { throw DesktopBridgeError.permissionDenied }
        }
        let candidate = try store.pendingPairingToken(offerId: offer.id)
            ?? existing.map { try store.prepareRenewal(for: $0) } ?? newPairingToken()
        let pending = try store.preparePendingPairing(offer: offer, deviceId: deviceId, deviceName: deviceName, token: candidate)
        let provisional = try DesktopBridgePairing(id: offer.renewalPairingId ?? offer.id, origin: origin,
            certificateFingerprint: offer.certificateFingerprint, deviceId: deviceId, deviceName: deviceName,
            vaultIds: Set(offer.vaultIds), domains: Set(offer.domains), pairedAt: Date(), expiresAt: nil,
            alternateOrigins: Array(offer.origins.dropFirst()), wholeWorkspace: offer.wholeWorkspace, macDeviceId: existing?.macDeviceId ?? offer.macDeviceId, retainedAuthoringVaultIds: existing?.retainedAuthoringVaultIds)

        // A successful POST is saved before the capabilities request. If that
        // second request fails, even a compatible older Mac can resume locally.
        if let saved = store.pairings().first(where: { $0.id == provisional.id }),
           store.credential(for: saved) == pending.token {
            try validateRecoveredPairing(saved, provisional: provisional, existing: existing)
            return (saved, pending.token)
        }

        var probe = URLRequest(url: URL(string: origin + "/bridge/v2/pairing")!)
        probe.setValue("Bearer \(pending.token)", forHTTPHeaderField: "Authorization")
        let (receiptData, receiptResponse) = try await perform(probe, session: session, relay: offer.relay,
            alternateOrigins: Array(offer.origins.dropFirst()))
        guard let status = receiptResponse as? HTTPURLResponse else { throw DesktopBridgeError.malformedResponse }
        let raw: PairingEnvelope.RawPairing
        let token: String
        let relay: DesktopRelayConfiguration?
        let response: URLResponse
        if status.statusCode == 200 {
            let receipt = try JSONDecoder.nodus.decode(PairingReceipt.self, from: receiptData)
            raw = receipt.pairing; relay = receipt.relay; token = pending.token; response = receiptResponse
        } else if [401, 404].contains(status.statusCode) {
            guard offer.expiresAt > Date() else { throw DesktopBridgeError.expired }
            var request = URLRequest(url: URL(string: origin + "/bridge/v1/pair")!)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let existing, let credential = store.credential(for: existing) {
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder.nodus.encode(PairingRequest(code: offer.code,
                deviceId: pending.deviceId, deviceName: pending.deviceName, nextToken: pending.token))
            let result = try await perform(request, session: session, relay: offer.relay,
                alternateOrigins: Array(offer.origins.dropFirst()))
            guard (result.1 as? HTTPURLResponse)?.statusCode == 201 else { throw DesktopBridgeError.permissionDenied }
            let envelope = try JSONDecoder.nodus.decode(PairingEnvelope.self, from: result.0)
            if existing != nil, envelope.token != pending.token { throw DesktopBridgeError.malformedResponse }
            raw = envelope.pairing; token = envelope.token; relay = envelope.relay; response = result.1
        } else { throw DesktopBridgeError.malformedResponse }

        let retained = (existing?.retainedAuthoringVaultIds ?? []).union((existing?.vaultIds ?? []).subtracting(Set(raw.vaultIds)))
        let pairing = try DesktopBridgePairing(id: raw.id,
            origin: response.url.flatMap(Self.origin(of:)) ?? origin,
            certificateFingerprint: provisional.certificateFingerprint, deviceId: raw.deviceId, deviceName: raw.deviceName,
            vaultIds: Set(raw.vaultIds), domains: Set(raw.domains), pairedAt: raw.createdAt, expiresAt: raw.expiresAt,
            alternateOrigins: [origin] + Array(offer.origins.dropFirst()), wholeWorkspace: raw.wholeWorkspace,
            macDeviceId: existing?.macDeviceId ?? offer.macDeviceId,
            retainedAuthoringVaultIds: retained.isEmpty ? existing?.retainedAuthoringVaultIds : retained)
        try validateRecoveredPairing(pairing, provisional: provisional, existing: existing)
        guard !token.isEmpty else { throw DesktopBridgeError.malformedResponse }
        try store.updatePendingPairing(pending, token: token)
        if let relay { try store.saveRelay(relay, pairingId: pairing.id) }
        if let existing { try store.commitRenewal(for: existing, token: token) }
        try store.save(pairing, token: token)
        return (pairing, token)
    }

    private static func validateRecoveredPairing(_ pairing: DesktopBridgePairing,
                                                provisional: DesktopBridgePairing, existing: DesktopBridgePairing?) throws {
        guard pairing.id == provisional.id, !pairing.isExpired,
              pairing.deviceId == (existing?.deviceId ?? provisional.deviceId),
              pairing.certificateFingerprint == provisional.certificateFingerprint,
              pairing.wholeWorkspace == provisional.wholeWorkspace,
              pairing.macDeviceId == provisional.macDeviceId,
              provisional.wholeWorkspace == true || pairing.vaultIds == provisional.vaultIds,
              pairing.domains == provisional.domains else {
            throw DesktopBridgeError.permissionDenied
        }
        if let existing {
            guard pairing.pairedAt == existing.pairedAt, pairing.deviceName == existing.deviceName else {
                throw DesktopBridgeError.permissionDenied
            }
        }
    }

    private static func newPairingToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw KeychainStore.Failure.unexpectedStatus(status) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

private struct PairingReceipt: Decodable {
    let pairing: PairingEnvelope.RawPairing
    let relay: DesktopRelayConfiguration?
}
