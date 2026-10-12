import Foundation

extension DesktopBridgePairing {
    /// Capabilities arrive over the approved pinned transport. Only an explicitly
    /// approved whole-workspace grant may admit additional vault identities.
    public func refreshedWorkspace(_ capabilities: DesktopLiveCapabilities, trustedMacDeviceId: String) throws -> DesktopBridgePairing {
        guard capabilities.protocolVersion == 2, !trustedMacDeviceId.isEmpty,
              capabilities.deviceId == trustedMacDeviceId,
              macDeviceId == nil || macDeviceId == trustedMacDeviceId else { throw DesktopBridgeError.permissionDenied }
        let vaults = Set(capabilities.vaults.map(\.id))
        guard vaults.count == capabilities.vaults.count, !vaults.contains("") else { throw DesktopBridgeError.malformedResponse }
        if wholeWorkspace == true {
            guard capabilities.wholeWorkspace == true else { throw DesktopBridgeError.permissionDenied }
        } else {
            guard vaults.isSubset(of: vaultIds) else { throw DesktopBridgeError.permissionDenied }
        }
        let currentDomains = capabilities.domains.map(Set.init) ?? domains
        guard currentDomains.isSubset(of: domains) else { throw DesktopBridgeError.permissionDenied }
        return try DesktopBridgePairing(id: id, origin: origin, certificateFingerprint: certificateFingerprint,
            deviceId: deviceId, deviceName: deviceName, vaultIds: vaults, domains: currentDomains,
            pairedAt: pairedAt, expiresAt: expiresAt, alternateOrigins: alternateOrigins ?? [],
            wholeWorkspace: wholeWorkspace, macDeviceId: trustedMacDeviceId,
            retainedAuthoringVaultIds: (retainedAuthoringVaultIds ?? []).union(vaultIds.subtracting(vaults)).subtracting(vaults))
    }
    /// Changes archive bookkeeping only. Callers never use this to authorize network requests.
    public func authoringArchiveScope(_ vaults: Set<String>, retained: Set<String>? = nil) throws -> DesktopBridgePairing {
        try DesktopBridgePairing(id: id, origin: origin, certificateFingerprint: certificateFingerprint,
            deviceId: deviceId, deviceName: deviceName, vaultIds: vaults, domains: domains, pairedAt: pairedAt,
            expiresAt: expiresAt, alternateOrigins: alternateOrigins ?? [], wholeWorkspace: wholeWorkspace,
            macDeviceId: macDeviceId, retainedAuthoringVaultIds: retained ?? retainedAuthoringVaultIds)
    }

}
