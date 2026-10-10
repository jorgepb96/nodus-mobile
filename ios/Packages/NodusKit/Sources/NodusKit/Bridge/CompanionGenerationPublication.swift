import CryptoKit
import Foundation

/// A completed phone response and its exact, provider-free Mac save. Keeping the
/// checkpoint in the same durable ledger write closes the app-termination window
/// between saving generated content and queuing its publication.
public struct CompanionGenerationPublication: Sendable {
    public let id: String
    public let recordId: String
    public let method: String
    public let args: [JSONValue]
    public let checkpoint: JSONValue

    public static func recordId(kind: String, entity: String) throws -> String {
        guard ["dictionary", "immersion", "translation", "writing", "argument"].contains(kind),
              !entity.isEmpty, entity.utf8.count <= 256 else { throw DesktopBridgeError.malformedResponse }
        let hash = SHA256.hash(data: Data(entity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "autonomous:\(kind):\(hash)"
    }

    /// Only a complete saved response enters this lane. Provider failures and
    /// cancellations remain checkpoints and never become automatic retries.
    public init?(kind: String, entity: String, checkpoint: JSONValue) throws {
        let key = try Self.recordId(kind: kind, entity: entity)
        guard let value = checkpoint.objectValue,
              let identity = value["id"]?.stringValue, UUID(uuidString: identity) != nil,
              let request = value["request"]?.objectValue,
              let state = value["state"]?.stringValue,
              ["accepted", "running", "saved", "available", "failed", "cancelled"].contains(state)
        else { throw DesktopBridgeError.malformedResponse }
        if kind == "dictionary" {
            guard request["entryId"]?.stringValue == entity else { throw DesktopBridgeError.malformedResponse }
        } else {
            guard value["entityKey"]?.stringValue == entity else { throw DesktopBridgeError.malformedResponse }
        }
        guard state == "saved" else { return nil }
        guard let context = value["context"]?.objectValue,
              let revision = context["revision"]?.stringValue, revision.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw DesktopBridgeError.malformedResponse }
        var input: [String: JSONValue] = ["request": .object(request), "revision": .string(revision), "requestId": .string(identity)]
        let operation: String
        switch kind {
        case "dictionary":
            guard let definition = value["definition"]?.objectValue,
                  definition["entryId"]?.stringValue == entity,
                  let markdown = definition["contentMarkdown"]?.stringValue, !markdown.isEmpty
            else { throw DesktopBridgeError.malformedResponse }
            operation = "saveDictionaryGeneratedVersion"
            input = ["definition": .object(definition), "contextRevision": .string(revision),
                     "webSearch": request["webSearch"].flatMap { $0.isNull ? nil : $0 } ?? .string("off"), "requestId": .string(identity)]
        case "translation":
            guard let markdown = value["markdown"]?.stringValue, !markdown.isEmpty else { throw DesktopBridgeError.malformedResponse }
            operation = "saveContentTranslationFromMobile"; input["markdown"] = .string(markdown)
        case "immersion":
            guard let plan = value["plan"]?.objectValue, let model = request["model"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
            operation = "saveImmersionGeneratedSession"; input["plan"] = .object(plan); input["model"] = .object(model)
        case "writing":
            guard let raw = value["raw"]?.stringValue, !raw.isEmpty else { throw DesktopBridgeError.malformedResponse }
            operation = "saveStudyImprovementFromMobile"; input["raw"] = .string(raw)
        default: throw DesktopBridgeError.malformedResponse
        }
        guard try JSONEncoder.nodus.encode(checkpoint).count <= 20_000_000 else { throw DesktopBridgeError.malformedResponse }
        id = identity; recordId = key; method = operation; args = [.object(input)]; self.checkpoint = checkpoint
    }
}
