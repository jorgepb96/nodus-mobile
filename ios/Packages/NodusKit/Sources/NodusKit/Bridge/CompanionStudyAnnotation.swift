import Foundation

/// One annotation mutation; native document and unrelated comments are never replaced.
public enum CompanionStudyAnnotation {
    static func exactInteger(_ value: JSONValue) -> Int64? {
        switch value {
        case .int(let number): return number >= 0 && number <= 9_007_199_254_740_991 ? number : nil
        case .double(let number): return number.isFinite && number >= 0 && number <= 9_007_199_254_740_991 && number.rounded(.towardZero) == number ? Int64(number) : nil
        default: return nil
        }
    }
    static func command(action: String, id: String, expected: JSONValue?, patch: JSONValue?) throws -> JSONValue {
        guard ["annotationCreate", "annotationUpdate", "annotationDelete"].contains(action), UUID(uuidString: id) != nil else { throw DesktopBridgeError.malformedResponse }
        if action != "annotationDelete" {
            guard let fields = patch?.objectValue, fields.keys.allSatisfy({ ["anchor", "from", "to", "selectedText", "comment", "color", "locked", "pinned", "resolved"].contains($0) }) else { throw DesktopBridgeError.malformedResponse }
            for key in ["from", "to"] where fields[key] != nil { guard let value = fields[key].flatMap(exactInteger), value >= 0 else { throw DesktopBridgeError.malformedResponse } }
            for key in ["comment", "selectedText"] where fields[key] != nil { guard let value = fields[key]?.stringValue, value.utf8.count <= 1024 * 1024 else { throw DesktopBridgeError.malformedResponse } }
            for key in ["locked", "pinned", "resolved"] where fields[key] != nil { guard fields[key]?.boolValue != nil else { throw DesktopBridgeError.malformedResponse } }
            if let color = fields["color"], color != .null { guard let value = color.stringValue, value.utf8.count <= 128 else { throw DesktopBridgeError.malformedResponse } }
            if let anchor = fields["anchor"], anchor != .null {
                guard let value = anchor.objectValue, value.keys.allSatisfy({ ["blockId", "endBlockId", "from", "to"].contains($0) }),
                      let block = value["blockId"]?.stringValue, !block.isEmpty, block.utf8.count <= 128,
                      let from = value["from"].flatMap(exactInteger), let to = value["to"].flatMap(exactInteger), from >= 0, to >= from else { throw DesktopBridgeError.malformedResponse }
                if let end = value["endBlockId"] { guard let text = end.stringValue, !text.isEmpty, text.utf8.count <= 128 else { throw DesktopBridgeError.malformedResponse } }
            }
            if action == "annotationCreate" {
                guard fields["comment"]?.stringValue != nil, fields["selectedText"]?.stringValue != nil,
                      let from = fields["from"].flatMap(exactInteger), let to = fields["to"].flatMap(exactInteger), to >= from else { throw DesktopBridgeError.malformedResponse }
            }
        }
        guard action == "annotationCreate" ? expected == nil : expected?.objectValue?["id"] == .string(id) else { throw DesktopBridgeError.malformedResponse }
        var value: [String: JSONValue] = ["action": .string(action), "annotationId": .string(id), "expectedAnnotation": expected ?? .null]
        if action != "annotationDelete" { value["patch"] = patch }
        return .object(value)
    }
    static func projected(command: JSONValue, documentId: String, timestamp: String) -> JSONValue? {
        guard let fields = command.objectValue, let action = fields["action"]?.stringValue, let id = fields["annotationId"]?.stringValue else { return nil }
        if action == "annotationDelete" { return nil }
        var row = fields["expectedAnnotation"]?.objectValue ?? ["id": .string(id), "shortId": .string("ANN-" + id.prefix(8)), "documentId": .string(documentId), "createdAt": .string(timestamp), "color": .null, "resolvedAt": .null, "locked": .bool(false), "pinned": .bool(false), "position": .int(0), "archivedAt": .null, "deletedAt": .null]
        for (key, value) in fields["patch"]?.objectValue ?? [:] {
            if key == "resolved" { row["resolvedAt"] = value.boolValue == true ? .string(timestamp) : .null }
            else { row[key] = value }
        }
        row["updatedAt"] = .string(timestamp)
        if action == "annotationCreate", let comment = row["comment"]?.stringValue { row["comment"] = .string(comment.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return .object(row)
    }
}
