import CryptoKit
import Foundation

/// Persist only hashed request scopes and opaque intent keys. A retry after a
/// lost acknowledgement reuses paid work; a known terminal action releases its key.
public actor GenerationActionIntentStore {
    private let file: URL
    private var keys: [String: String]
    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("generation-action-intents.json")
        if FileManager.default.fileExists(atPath: file.path) {
            keys = try JSONDecoder.nodus.decode([String: String].self, from: Data(contentsOf: file))
            guard keys.values.allSatisfy({ !$0.isEmpty && $0.count <= 4096 }) else { throw DesktopBridgeError.malformedResponse }
        } else { keys = [:] }
    }

    public static func scope(kind: SpaceActionKind, payload: [String: JSONValue], revision: String?, mode: String) throws -> String {
        let value: JSONValue = .object(["kind": .string(kind.rawValue), "payload": .object(payload),
            "revision": revision.map(JSONValue.string) ?? .null, "mode": .string(mode)])
        return SHA256.hash(data: try JSONEncoder.nodus.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    public func prepare(scope: String, preferredKey: String? = nil) throws -> String {
        if let key = keys[scope] { return key }
        let key = preferredKey ?? UUID().uuidString.lowercased()
        guard !key.isEmpty, key.count <= 4096 else { throw DesktopBridgeError.malformedResponse }
        keys[scope] = key
        do { try persist() } catch { keys[scope] = nil; throw error }
        return key
    }
    public func acknowledge(scope: String, key: String, terminal: Bool) throws {
        guard terminal, keys[scope] == key else { return }
        keys[scope] = nil
        do { try persist() } catch { keys[scope] = key; throw error }
    }
    private func persist() throws {
        try PrivateBridgeProtectedFile.write(JSONEncoder.nodus.encode(keys), to: file, protection: .completeFileProtectionUnlessOpen)
    }
}
