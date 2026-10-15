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

/// Resolution failures are independent from an authenticated connection. Track
/// one pending retry per discovered service, invalidating late timers on stop,
/// removal or successful resolution. No address gains trust through this policy.
public struct DesktopLinkedMacResolutionRetries: Sendable {
    public struct Retry: Sendable {
        public let token: UUID
        public let delay: Duration
    }
    private struct State: Sendable { var failures = 0; var pending: UUID? }
    private var states: [String: State] = [:]
    public init() {}
    public mutating func track(_ service: String) -> Bool {
        guard states[service] == nil, states.count < 32 else { return false }
        states[service] = State(); return true
    }
    public mutating func failed(_ service: String) -> Retry? {
        guard var state = states[service], state.pending == nil else { return nil }
        let seconds = [1, 2, 4, 8, 16, 30]
        let retry = Retry(token: UUID(), delay: .seconds(seconds[min(state.failures, seconds.count - 1)]))
        state.failures = min(state.failures + 1, seconds.count - 1)
        state.pending = retry.token; states[service] = state; return retry
    }
    public mutating func consume(_ retry: Retry, service: String) -> Bool {
        guard var state = states[service], state.pending == retry.token else { return false }
        state.pending = nil; states[service] = state; return true
    }
    public mutating func resolved(_ service: String) { if states[service] != nil { states[service] = State() } }
    public mutating func remove(_ service: String) { states[service] = nil }
    public mutating func stop() { states = [:] }
}
