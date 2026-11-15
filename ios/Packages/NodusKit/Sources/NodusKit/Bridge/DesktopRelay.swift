import CryptoKit
import Foundation

/// Relay credentials travel in the authenticated QR/link and are kept in the device Keychain.
public struct DesktopRelayConfiguration: Codable, Hashable, Sendable {
    public let url: String
    public let id: String
    public let keyId: String
    public let clientToken: String
    public let secret: String
    public let expiresAt: Date
    public var certificateFingerprint: String? = nil
    public func validate() throws {
        guard let address = URLComponents(string: url), address.scheme == "https", address.host != nil,
              address.user == nil, address.password == nil, address.query == nil, address.fragment == nil,
              address.path.isEmpty || address.path == "/", UUID(uuidString: id) != nil, UUID(uuidString: keyId) != nil,
              clientToken.count >= 32, let bytes = Data(base64Encoded: secret), bytes.count == 32 else {
            throw DesktopBridgeError.invalidOrigin
        }
        if let pin = certificateFingerprint, pin.count != 64 || !pin.allSatisfy(\.isHexDigit) { throw DesktopBridgeError.invalidFingerprint }
    }
}

struct DesktopRelayFrame: Codable, Sendable {
    let version: Int
    let keyId: String
    let clientId: String
    let epoch: String
    let id: String
    let sequence: Int
    let final: Bool
    var sealed: String
    func aad(channel: String, direction: String) -> Data {
        Data(["nodus-relay-v1", channel, keyId, clientId, epoch, id, String(sequence), final ? "1" : "0", direction].joined(separator: "\n").utf8)
    }
}

enum DesktopRelayCrypto {
    static func key(_ configuration: DesktopRelayConfiguration, direction: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: configuration.secret), data.count == 32 else { throw DesktopBridgeError.malformedResponse }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: data), salt: Data(configuration.id.utf8),
            info: Data("nodus-relay-v1/\(direction)".utf8), outputByteCount: 32)
    }
    static func seal(_ data: Data, frame: DesktopRelayFrame, configuration: DesktopRelayConfiguration, direction: String) throws -> DesktopRelayFrame {
        var output = frame
        guard let combined = try AES.GCM.seal(data, using: key(configuration, direction: direction), authenticating: frame.aad(channel: configuration.id, direction: direction)).combined else { throw DesktopBridgeError.malformedResponse }
        output.sealed = combined.base64EncodedString(); return output
    }
    static func open(_ frame: DesktopRelayFrame, configuration: DesktopRelayConfiguration, direction: String) throws -> Data {
        guard frame.version == 1, frame.sequence >= 0, let data = Data(base64Encoded: frame.sealed), data.count <= 512 * 1024 else { throw DesktopBridgeError.malformedResponse }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key(configuration, direction: direction), authenticating: frame.aad(channel: configuration.id, direction: direction))
    }
}

/// A new request connects to the current Mac epoch. A reconnect never replays an old
/// session, and any transport retry uses the original durable operation identity.
public enum DesktopRelayTransport {
    public static func request(configuration: DesktopRelayConfiguration, path: String, method: String,
                               headers: [String: String], body: Data? = nil) async throws -> DesktopBridgeResponse {
        try configuration.validate()
        guard configuration.expiresAt > Date(), path.hasPrefix("/bridge/v1/") || path.hasPrefix("/bridge/v2/"),
              ["GET", "HEAD", "POST", "DELETE"].contains(method), !path.contains("#") else { throw DesktopBridgeError.permissionDenied }
        var address = URLComponents(string: configuration.url)!
        address.scheme = "wss"; address.path = "/api/v1/bridge-relay/\(configuration.id)/client"
        var request = URLRequest(url: address.url!); request.setValue("Bearer \(configuration.clientToken)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: configuration.certificateFingerprint.map { DesktopBridgeSessionDelegate(fingerprint: $0) }, delegateQueue: nil)
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 768 * 1024; socket.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            struct Ready: Decodable { let type: String; let clientId: String?; let hostEpoch: String? }
            func data(_ message: URLSessionWebSocketTask.Message) throws -> Data {
                switch message { case .data(let bytes): bytes; case .string(let text): Data(text.utf8); @unknown default: throw DesktopBridgeError.malformedResponse }
            }
            var ready: Ready
            repeat { ready = try JSONDecoder().decode(Ready.self, from: data(try await socket.receive())) } while ready.type != "ready" && ready.type != "offline"
            guard let clientId = ready.clientId, let epoch = ready.hostEpoch else { throw URLError(.notConnectedToInternet) }
            struct Input: Encodable { let path: String; let method: String; let headers: [String: String]; let bodyBase64: String? }
            let input = try JSONEncoder().encode(Input(path: path, method: method, headers: headers, bodyBase64: body?.base64EncodedString()))
            guard input.count <= 24 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
            let id = UUID().uuidString.lowercased(), chunkBytes = 192 * 1024
            for offset in stride(from: 0, to: input.count, by: chunkBytes) {
                try Task.checkCancellation()
                let end = min(offset + chunkBytes, input.count)
                let frame = DesktopRelayFrame(version: 1, keyId: configuration.keyId, clientId: clientId, epoch: epoch, id: id, sequence: offset / chunkBytes, final: end == input.count, sealed: "")
                let sealed = try DesktopRelayCrypto.seal(input.subdata(in: offset..<end), frame: frame, configuration: configuration, direction: "request")
                try await socket.send(.data(try JSONEncoder().encode(sealed)))
            }
            struct Output: Decodable { let status: Int; let headers: [String: String]; let bodyBase64: String }
            var bytes = Data(), sequence = 0, status: Int?, responseHeaders: [String: String]?
            while true {
                try Task.checkCancellation()
                let payload = try data(try await socket.receive())
                if (try? JSONDecoder().decode(Ready.self, from: payload))?.type == "offline" { throw URLError(.networkConnectionLost) }
                let frame = try JSONDecoder().decode(DesktopRelayFrame.self, from: payload)
                guard frame.keyId == configuration.keyId, frame.id == id, frame.clientId == clientId, frame.epoch == epoch, frame.sequence == sequence else { throw DesktopBridgeError.malformedResponse }
                let output = try JSONDecoder().decode(Output.self, from: DesktopRelayCrypto.open(frame, configuration: configuration, direction: "response"))
                guard let chunk = Data(base64Encoded: output.bodyBase64), bytes.count + chunk.count <= 512 * 1024 * 1024,
                      status == nil || status == output.status, responseHeaders == nil || responseHeaders == output.headers else { throw DesktopBridgeError.malformedResponse }
                bytes.append(chunk); status = output.status; responseHeaders = output.headers; sequence += 1
                if frame.final { return DesktopBridgeResponse(data: bytes, status: output.status, headers: output.headers) }
            }
        } onCancel: { socket.cancel(with: .goingAway, reason: nil) }
    }
}
