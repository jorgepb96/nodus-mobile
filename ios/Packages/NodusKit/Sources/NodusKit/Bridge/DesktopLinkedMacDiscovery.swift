import Foundation

/// Bonjour is an untrusted address hint, never an authorization or a certificate pin.
public struct DesktopLinkedMacAdvertisement: Sendable, Equatable {
    public let macDeviceId: String
    public let origins: [String]
    public init(txt: [String: Data]) throws {
        guard txt.values.reduce(0, { $0 + $1.count }) <= 4_096,
              txt["discoveryVersion"] == Data("1".utf8),
              let mac = txt["macId"].flatMap({ String(data: $0, encoding: .utf8) }), UUID(uuidString: mac) != nil,
              let rawCount = txt["rc"].flatMap({ String(data: $0, encoding: .utf8) }),
              let count = Int(rawCount), String(count) == rawCount, (1...16).contains(count) else { throw DesktopBridgeError.malformedResponse }
        var addresses: [String] = []
        for index in 0..<count {
            guard let bytes = txt["r\(index)"], bytes.count <= 240,
                  let address = String(data: bytes, encoding: .utf8), let url = URLComponents(string: address),
                  url.path.isEmpty, let host = url.host, !host.isEmpty,
                  url.port.map({ (1...65535).contains($0) }) ?? true else { throw DesktopBridgeError.invalidOrigin }
            try DesktopBridgePairing.validateOrigin(address)
            if !addresses.contains(address) { addresses.append(address) }
        }
        macDeviceId = mac; origins = addresses
    }
}
