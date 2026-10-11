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
        guard ["dictionary", "immersion", "translation", "writing", "argument", "workshop", "database", "academic"].contains(kind),
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
        if let version = context["offlineSourceVersion"] {
            guard version == .int(1), ["translation", "writing", "immersion"].contains(kind) else { throw DesktopBridgeError.malformedResponse }
            input["offlineSourceVersion"] = version
        }
        let operation: String
        switch kind {
        case "academic":
            guard let raw = value["raw"]?.stringValue, !raw.isEmpty, let source = context["source"],
                  let sourceRequest = request["source"], let model = request["model"], let generatedAt = value["generatedAt"]?.stringValue,
                  value["preview"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
            let captured = try CompanionAcademicSource(source, request: sourceRequest)
            guard captured.revision == revision else { throw DesktopBridgeError.malformedResponse }
            operation = "saveMobileAcademicResult"
            input = ["request": sourceRequest, "revision": .string(revision), "raw": .string(raw), "model": model,
                     "requestId": .string(identity), "generatedAt": .string(generatedAt)]
            if let localScene=captured.value.objectValue?["localScene"] {
                guard captured.kind == "prose", let proof=localScene.objectValue,
                      Set(proof.keys) == ["creationMutationId","baselineDraft"],
                      let creation=proof["creationMutationId"]?.stringValue, UUID(uuidString:creation) != nil,
                      proof["baselineDraft"]?.objectValue != nil else { throw DesktopBridgeError.malformedResponse }
                input["localScene"] = localScene
            }
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
        case "workshop":
            guard let raw = value["raw"]?.stringValue, !raw.isEmpty,
                  value["preview"]?.objectValue?["draftMarkdown"]?.stringValue?.isEmpty == false,
                  let source = context["source"], let scope = value["sourceScope"]?.stringValue,
                  ["linked_corpus", "device_downloads"].contains(scope)
            else { throw DesktopBridgeError.malformedResponse }
            _ = try CompanionWorkshopSource(copies: [source]).selected(request["selection"] ?? .null)
            operation = "saveWritingWorkshopFromMobile"
            input["raw"] = .string(raw); input["source"] = source; input["sourceScope"] = .string(scope)
        case "database":
            guard let packs = context["packs"]?.arrayValue,!packs.isEmpty,
                  let detail = value["detail"]?.objectValue,let run = detail["run"]?.objectValue,
                  run["id"] == .string("dbr_mobile_\(identity)"),["completed","partial"].contains(run["status"]?.stringValue ?? ""),
                  detail["report"]?.objectValue?["runId"] == run["id"] else { throw DesktopBridgeError.malformedResponse }
            operation = "saveMobileDatabaseResearchReport"
            input = ["request":.object(request),"sourcePacks":.array(packs),"detail":.object(detail),"requestId":.string(identity)]
        default: throw DesktopBridgeError.malformedResponse
        }
        guard try JSONEncoder.nodus.encode(checkpoint).count <= 20_000_000 else { throw DesktopBridgeError.malformedResponse }
        id = identity; recordId = key; method = operation; args = [.object(input)]; self.checkpoint = checkpoint
    }
}
