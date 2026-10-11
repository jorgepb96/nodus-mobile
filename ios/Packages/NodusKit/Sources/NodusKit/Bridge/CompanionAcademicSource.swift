import Foundation

/// Source and response shapes for the exact Desktop author, matrix and scene
/// prompts. A phone preview uses the original source identities and never fills
/// unread scene beats with inferred verdicts.
public struct CompanionAcademicSource: Sendable {
    public let value: JSONValue
    public let request: JSONValue
    public let revision: String
    public let kind: String
    public let completion: [String: JSONValue]
    private let source: [String: JSONValue]
    public var needsModel: Bool { kind == "prose" ? source["noMaterial"] != .bool(true) : kind != "matrix" || source["ideas"]?.arrayValue?.isEmpty == false }

    public init(_ value: JSONValue, request: JSONValue) throws {
        guard let fields = value.objectValue, fields["version"] == .int(1), fields["request"] == request,
              let kind = request.objectValue?["kind"]?.stringValue, ["author", "matrix", "prose"].contains(kind),
              let revision = fields["revision"]?.stringValue, revision.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let source = fields["source"]?.objectValue, let prompt = source["prompt"]?.objectValue,
              let system = prompt["system"]?.stringValue, let user = prompt["user"]?.stringValue,
              system.utf8.count + user.utf8.count <= 1_000_000 else { throw DesktopBridgeError.malformedResponse }
        self.value = value; self.request = request; self.source = source; self.kind = kind; self.revision = revision
        completion = ["system": .string(system), "user": .string(user), "temperature": .double(0.2),
                      "maxTokens": kind == "prose" ? .int(600) : .int(4000), "format": .string(kind == "prose" ? "text" : "json")]
    }

    public func preview(raw: String, model: JSONValue, generatedAt: String) throws -> JSONValue {
        if kind == "prose" {
            guard var result = value.objectValue?["emptyPreview"]?.objectValue, let original = result["beats"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            let verdicts = try Self.verdicts(raw)
            result["beats"] = .array(try original.enumerated().map { index, value in
                guard var beat = value.objectValue else { throw DesktopBridgeError.malformedResponse }
                beat["present"] = index < verdicts.count ? .bool(verdicts[index].present) : .null
                beat["note"] = index < verdicts.count ? verdicts[index].note.map(JSONValue.string) ?? .null : .null
                return .object(beat)
            })
            return .object(result)
        }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") { text = text.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression) }
        guard let response = try JSONDecoder.nodus.decode(JSONValue.self, from: Data(text.utf8)).objectValue else { throw DesktopBridgeError.malformedResponse }
        if kind == "author" {
            guard case .string(let thesis) = response["thesis"], case .string(let positioning) = response["positioning"],
                  let remember = response["remember"]?.arrayValue, remember.allSatisfy({ if case .string = $0 { true } else { false } }) else { throw DesktopBridgeError.malformedResponse }
            let items = remember.compactMap(\.stringValue).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(6)
            return .object(["thesis": .string(thesis.trimmingCharacters(in: .whitespacesAndNewlines)), "remember": .array(items.map(JSONValue.string)),
                "positioning": .string(positioning.trimmingCharacters(in: .whitespacesAndNewlines)), "model": model, "generatedAt": .string(generatedAt), "stale": .bool(false)])
        }
        guard let ideas = source["ideas"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
        let stance: JSONValue
        if ideas.isEmpty { stance = .null }
        else { guard case .string(let text) = response["stance"] else { throw DesktopBridgeError.malformedResponse }; stance = .string(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .object(["authorId": request.objectValue?["authorId"] ?? .null, "themeId": request.objectValue?["themeId"] ?? .null,
            "ideaCount": .int(Int64(ideas.count)), "ideas": .array(ideas.prefix(8).map { .object(($0.objectValue ?? [:]).filter { ["global_id", "label", "type"].contains($0.key) }) }), "stance": stance])
    }

    private static func verdicts(_ text: String) throws -> [(present: Bool, note: String?)] {
        let line = try NSRegularExpression(pattern: #"^[\s>*\-–—•\d.)]*\*{0,2}\s*latido\s*\d*\s*\*{0,2}\s*[:.\-–—]\s*(.+)$"#, options: .caseInsensitive)
        let yes = try NSRegularExpression(pattern: #"^\s*\*{0,2}\s*(s[ií]|yes|aparece)(?![\p{L}\p{N}])"#, options: .caseInsensitive)
        let no = try NSRegularExpression(pattern: #"^\s*\*{0,2}\s*(no|falta|ausente)(?![\p{L}\p{N}])"#, options: .caseInsensitive)
        return text.components(separatedBy: .newlines).compactMap { value in
            let range = NSRange(value.startIndex..., in: value)
            guard let match = line.firstMatch(in: value, range: range), let bodyRange = Range(match.range(at: 1), in: value) else { return nil }
            let body = String(value[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines), full = NSRange(body.startIndex..., in: body)
            let present = yes.firstMatch(in: body, range: full) != nil
            guard present || no.firstMatch(in: body, range: full) != nil else { return nil }
            let expression = present ? yes : no
            let note = expression.stringByReplacingMatches(in: body, range: full, withTemplate: "")
                .replacingOccurrences(of: #"^\s*[—–\-:,.]\s*"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\*{2,}"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            return (present, note.isEmpty ? nil : note)
        }
    }
}
