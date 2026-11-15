import Foundation
import CryptoKit

/// A closed content boundary alongside the read-only corpus transport. Action
/// receipts belong to the Mac job store, never to a published-space identity.
enum DesktopCompanionActions {
    static let content: Set<String> = [
        "idea.delete", "idea.saveToNotes", "deepResearch.saveToNotes", "hypothesis.saveToNotes",
        "projects.create", "projects.update", "projects.section.update", "projects.chapter.import",
        "worldbuilding.entityDelete", "pages.restoreRevision", "databases.importCSV", "worldbuilding.continuity"
    ]
    static let research: Set<String> = [
        "author.synthesis.generate", "authors.matrix.generate", "argumentMap.generate", "writing.generate",
        "worldbuilding.proseReview"
    ]

    static func isIdentity(_ value: String) -> Bool { value.count == 36 && UUID(uuidString: value) != nil }

    /// Share the receipt namespace with corpus/actions when recovering an old
    /// intent through /jobs; changing transports cannot duplicate the operation.
    static func key(_ value: String) -> String {
        SHA256.hash(data: Data("companion-action:\(value)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func identity(_ value: String) -> String {
        let bytes = Array(key(value).prefix(32))
        return [String(bytes[0..<8]), String(bytes[8..<12]), String(bytes[12..<16]),
                String(bytes[16..<20]), String(bytes[20..<32])].joined(separator: "-")
    }
    static func validateJob(args: [JSONValue], domains: Set<DesktopBridgeDomain>) throws -> String {
        guard args.count == 1, var action = args[0].objectValue, action["id"] == nil,
              let key = action["idempotencyKey"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
        action["id"] = .string(identity(key))
        _ = try validateWrite(path: "actions", query: [], body: .object(action), domains: domains)
        return Self.key(key)
    }
    static func isOffline(_ error: any Error) -> Bool {
        guard let url = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .timedOut].contains(url.code)
    }

    static func validateWrite(path: String, query: [URLQueryItem], body: JSONValue?, domains: Set<DesktopBridgeDomain>) throws -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let cancellation = parts.count == 3 && parts[0] == "actions" && isIdentity(parts[1]) && parts[2] == "cancel"
        guard path == "actions" || cancellation else { return false }
        guard query.isEmpty, domains.contains(.corpus), domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
        guard case .object(let value) = body, try JSONEncoder.nodus.encode(body).count <= 2 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
        if cancellation {
            guard value.isEmpty else { throw DesktopBridgeError.malformedResponse }
            return true
        }
        let fields: Set<String> = ["id", "kind", "schemaVersion", "payload", "idempotencyKey", "inputRevision", "inputFingerprint", "executionMode"]
        guard Set(value.keys).isSubset(of: fields), case .string(let id) = value["id"], isIdentity(id),
              value["schemaVersion"] == .int(1), case .object = value["payload"],
              case .string(let key) = value["idempotencyKey"], !key.isEmpty, key.count <= 4096,
              case .string(let kind) = value["kind"] else { throw DesktopBridgeError.malformedResponse }
        guard content.contains(kind) || research.contains(kind) else { throw DesktopBridgeError.permissionDenied }
        for field in ["inputRevision", "inputFingerprint"] {
            if let source = value[field], source != .null {
                guard case .string(let text) = source, text.count <= 4096 else { throw DesktopBridgeError.malformedResponse }
            }
        }
        if research.contains(kind) {
            guard domains.contains(.researchGeneration) else { throw DesktopBridgeError.permissionDenied }
            guard value["executionMode"] == .string("live") else {
                throw APIError(status: 409, code: "explicit_live_mode_required", message: "Esta operación utiliza los modelos del Mac. Selecciona el modo live para ejecutarla con Nodus.")
            }
        }
        return true
    }
}
