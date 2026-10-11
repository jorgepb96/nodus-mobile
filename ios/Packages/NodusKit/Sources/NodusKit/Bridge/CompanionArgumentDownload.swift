import Foundation

public enum CompanionArgumentDownload {
    /// Capture the full selected source and inspector dependencies before any
    /// atomic pack commit. Every consulted dossier is rechecked, not just the
    /// graph shape or the AI prompt's subset of ideas.
    @MainActor public static func capture(request: JSONValue, maximumBytes: Int,
        fetch: (String, [JSONValue]) async throws -> JSONValue) async throws -> [PrivateBridgeCache.ReadPackRecord] {
        let initial = try await fetch("getMobileAcademicSource", [request])
        _ = try CompanionAcademicSource(initial, request: request)
        var records: [PrivateBridgeCache.ReadPackRecord] = [], bytes = 0
        func retain(_ method: String, _ args: [JSONValue], _ value: JSONValue) throws {
            let data = try JSONEncoder.nodus.encode(value)
            guard data.count <= maximumBytes - bytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            bytes += data.count; records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey(method, args), data: data))
        }
        try retain("getMobileAcademicSource", [request], initial)
        var inspected: [(String, [JSONValue], JSONValue)] = []
        var map: JSONValue?, mapArgs: [JSONValue] = []
        if request.objectValue?["kind"] == .string("argument") {
            guard let ideas = initial.objectValue?["source"]?.objectValue?["ideas"]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            mapArgs = [.object(["seedIdeaId": request.objectValue?["seedIdeaId"] ?? .null, "language": request.objectValue?["language"] ?? .null])]
            let structural = try await fetch("getMobileStructuralArgumentMap", mapArgs)
            map = structural
            var ids = try ideaIDs(structural)
            for idea in ideas { guard let id = idea.objectValue?["global_id"]?.stringValue else { throw DesktopBridgeError.malformedResponse }; ids.insert(id) }
            try retain("getMobileStructuralArgumentMap", mapArgs, structural)
            for id in ids.sorted() {
                for method in ["getIdeaDetail", "getIdeaEdges"] {
                    try Task.checkCancellation()
                    let args: [JSONValue] = [.string(id)], value = try await fetch(method, args)
                    guard value != .null else { throw DesktopBridgeError.malformedResponse }
                    try retain(method, args, value); inspected.append((method, args, value))
                }
            }
        }
        for (method, args, before) in inspected {
            try Task.checkCancellation()
            guard try await fetch(method, args) == before else { throw changed() }
        }
        if let map { guard try semanticMap(await fetch("getMobileStructuralArgumentMap", mapArgs)) == semanticMap(map) else { throw changed() } }
        guard try await fetch("getMobileAcademicSource", [request]) == initial else { throw changed() }
        try Task.checkCancellation()
        return records
    }
    private static func changed() -> APIError {
        .init(status: 409, code: "argument_download_changed", message: "Las fuentes y los detalles han cambiado durante la descarga. Reintenta para guardar una copia consistente.")
    }
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
