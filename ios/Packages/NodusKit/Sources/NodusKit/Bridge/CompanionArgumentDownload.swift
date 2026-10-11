import Foundation

public enum CompanionArgumentDownload {
    /// Structural maps generate presentation UUIDs and dates on each read. Only
    /// those fields are omitted when checking that the downloaded sources still
    /// describe the same map; labels, statements, relations and shape all count.
    public static func semanticMap(_ map: JSONValue) throws -> JSONValue {
        guard var value = map.objectValue, let root = value["root"] else { throw DesktopBridgeError.malformedResponse }
        var count = 0
        func node(_ input: JSONValue, depth: Int) throws -> JSONValue {
            count += 1
            guard depth <= 64, count <= 4096, var value = input.objectValue,
                  let id = value["ideaId"]?.stringValue, !id.isEmpty, id.utf8.count <= 256,
                  let children = value["children"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            value["id"] = nil
            value["children"] = .array(try children.map { try node($0, depth: depth + 1) })
            return .object(value)
        }
        value["root"] = try node(root, depth: 0); value["generatedAt"] = nil
        return .object(value)
    }
    public static func ideaIDs(_ map: JSONValue) throws -> Set<String> {
        let value = try semanticMap(map)
        var ids: Set<String> = []
        func walk(_ input: JSONValue) {
            guard let value = input.objectValue, let id = value["ideaId"]?.stringValue else { return }
            ids.insert(id); (value["children"]?.arrayValue ?? []).forEach(walk)
        }
        walk(value.objectValue!["root"]!); return ids
    }
}
