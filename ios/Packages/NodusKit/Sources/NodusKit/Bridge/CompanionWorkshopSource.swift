import Foundation

/// The Desktop projection of explicitly selected workshop material. This is a
/// bounded read download, not a vault snapshot or a local semantic index.
public struct CompanionWorkshopSource: Sendable {
    public enum SourceError: Error, LocalizedError, Sendable {
        case notDownloaded
        public var errorDescription: String? { "Descarga las fuentes elegidas para el taller mientras Nodus esté conectado." }
    }
    public static let recordId = "companion:workshop-source:v1"
    public static let languages = ["es", "en", "fr", "tr", "de", "pt", "pt-BR", "it", "zh-Hans", "zh-Hant", "vi", "ja", "ru", "uk", "ko"]
    public static let groups = ["ideaIds": "ideas", "themeIds": "temas", "gapIds": "huecos",
        "contradictionIds": "contradicciones", "workIds": "obras", "passageIds": "pasajes_evidencia", "tutorRouteIds": "rutas_tutor"]
    public static let collectionKeys = ["ideas": "ideaIds", "themes": "themeIds", "gaps": "gapIds",
        "works": "workIds", "passages": "passageIds", "contradictions": "contradictionIds", "tutor-routes": "tutorRouteIds"]
    public let value: JSONValue
    private let configuration: [String: JSONValue]
    private let items: [String: [String: JSONValue]]
    public var configurationRevision: String { configuration["configurationRevision"]!.stringValue! }

    public init(copies: [JSONValue]) throws {
        guard !copies.isEmpty else { throw SourceError.notDownloaded }
        var configuration: [String: JSONValue]?, collected: [String: [String: JSONValue]] = [:]
        for copy in copies {
            guard var source = copy.objectValue, source["version"] == .int(1),
                  let revision = source["configurationRevision"]?.stringValue, Self.isHash(revision),
                  let system = source["system"]?.stringValue, !system.isEmpty,
                  let rule = source["contextRule"]?.stringValue, !rule.isEmpty,
                  let language = source["promptLanguage"]?.stringValue, Self.languages.contains(language),
                  source["kindLabels"]?.objectValue != nil, let maxTokens = source["maxOutputTokens"]?.intValue,
                  (1...16_000).contains(maxTokens), let groups = source.removeValue(forKey: "groups")?.objectValue,
                  Set(groups.keys) == Set(Self.groups.values)
            else { throw DesktopBridgeError.malformedResponse }
            // Old configurations cannot silently mix prompts with newer copies.
            if let configuration, configuration != source { continue }
            configuration = source
            for group in Self.groups.values {
                guard let entries = groups[group]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
                var seen: Set<String> = []
                for entry in entries {
                    guard let item = entry.objectValue, let id = item["id"]?.stringValue,
                          !id.isEmpty, id.utf8.count <= 256, seen.insert(id).inserted,
                          let revision = item["revision"]?.stringValue, Self.isHash(revision),
                          let body = item["value"]?.objectValue,
                          Self.identity(body["id"]) == id
                    else { throw DesktopBridgeError.malformedResponse }
                    if collected[group]?[id] == nil { collected[group, default: [:]][id] = entry }
                }
            }
        }
        self.configuration = configuration!; items = collected
        value = Self.envelope(configuration!, items: collected)
        guard try JSONEncoder.nodus.encode(value).count <= PrivateBridgeCache.defaultReadLimitBytes else { throw PrivateBridgeCache.ReadPackError.tooLarge }
    }

    public static func selection(path: String, ids: [String]) throws -> JSONValue {
        guard let key = collectionKeys[path], !ids.isEmpty, ids.count <= 200 else { throw DesktopBridgeError.malformedResponse }
        return .object(groups.mapValues { _ in .array([]) }.merging([key: .array(ids.sorted().map(JSONValue.string))]) { _, new in new })
    }
    public static func cataloguePage(_ value: JSONValue, idKey: String = "selection_id", labelKey: String = "label") throws -> Page<Row> {
        guard let body = value.objectValue, let items = body["items"]?.arrayValue,
              let total = body["total"]?.intValue, total >= 0,
              let limit = body["limit"]?.intValue, (1...200).contains(limit),
              let offset = body["offset"]?.intValue, offset >= 0, offset <= Int.max - limit,
              let more = body["hasMore"]?.boolValue,
              let revision = body["revision"]?.stringValue, isHash(revision), items.count <= limit,
              more == (offset + items.count < total),
              (offset >= total ? items.isEmpty : (!items.isEmpty && offset + items.count <= total))
        else { throw DesktopBridgeError.malformedResponse }
        var seen: Set<String> = []
        let rows = try items.map { value -> Row in
            guard let row = value.objectValue, let identity = row[idKey]?.stringValue,
                  !identity.isEmpty, seen.insert(identity).inserted, row[labelKey]?.stringValue != nil
            else { throw DesktopBridgeError.malformedResponse }
            return Row(row)
        }
        return Page(items: rows, total: total, limit: limit, offset: offset, hasMore: more, revision: revision)
    }
    public func selected(_ selection: JSONValue) throws -> CompanionWorkshopSource {
        guard let chosen = selection.objectValue, Set(chosen.keys) == Set(Self.groups.keys) else { throw DesktopBridgeError.malformedResponse }
        var selected: [String: [String: JSONValue]] = [:], count = 0
        for (key, group) in Self.groups {
            guard let ids = chosen[key]?.arrayValue else { throw DesktopBridgeError.malformedResponse }
            var seen: Set<String> = []
            for identity in ids {
                guard let id = identity.stringValue, seen.insert(id).inserted, let item = items[group]?[id] else { throw SourceError.notDownloaded }
                selected[group, default: [:]][id] = item; count += 1
            }
        }
        guard (1...200).contains(count) else { throw DesktopBridgeError.malformedResponse }
        let result = try Self(copies: [Self.envelope(configuration, items: selected)])
        guard try JSONEncoder.nodus.encode(result.value).count <= 800_000 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        return result
    }
    public func rows(for selectionKey: String) -> [Row] {
        guard let group = Self.groups[selectionKey] else { return [] }
        return (items[group] ?? [:]).keys.sorted().compactMap { id in
            guard var body = items[group]?[id]?.objectValue?["value"]?.objectValue else { return nil }
            body["selection_id"] = .string(id); return Row(body)
        }
    }
    public func prompt(request: JSONValue) throws -> JSONValue {
        guard let request = request.objectValue, let brief = request["brief"]?.objectValue,
              let kind = brief["kind"]?.stringValue, kind != "deep_research",
              let label = configuration["kindLabels"]?.objectValue?[kind]?.stringValue,
              let objective = brief["objective"]?.stringValue, !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              objective.utf8.count <= 64_000 else { throw DesktopBridgeError.malformedResponse }
        var payload: [String: JSONValue] = ["brief": .object(["tipo": .string(label), "objetivo": .string(objective),
            "audiencia": brief["audience"] ?? .null, "tono": brief["tone"] ?? .string("academic"),
            "lengua": brief["language"] ?? .string("es")]), "regla": configuration["contextRule"]!]
        for group in Self.groups.values {
            payload[group] = .array((items[group] ?? [:]).keys.sorted().compactMap { items[group]?[$0]?.objectValue?["value"] })
        }
        return .object(["system": configuration["system"]!, "user": .string(String(decoding: try JSONEncoder.nodus.encode(payload), as: UTF8.self)),
            "maxTokens": configuration["maxOutputTokens"]!, "temperature": .double(0.18), "format": .string("json")])
    }
    /// Keep the structured preview. Publication applies Desktop's full citation
    /// sanitation again; a foreign device citation never enters this preview.
    public func preview(raw: String, request: JSONValue, scope: String, generatedAt: String) throws -> JSONValue {
        var json = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```"), let firstLine = json.firstIndex(of: "\n") {
            let opening = String(json[..<firstLine]).lowercased()
            if opening == "```" || opening == "```json" { json = String(json[json.index(after: firstLine)..<json.index(json.endIndex, offsetBy: -3)]) }
        }
        guard raw.utf8.count <= 400_000, let data = json.data(using: .utf8),
              var result = try JSONDecoder.nodus.decode(JSONValue.self, from: data).objectValue,
              let title = result["title"]?.stringValue, !title.isEmpty,
              let markdown = result["draftMarkdown"]?.stringValue, !markdown.isEmpty,
              result["outline"]?.arrayValue != nil, let request = request.objectValue,
              ["linked_corpus", "device_downloads"].contains(scope)
        else { throw DesktopBridgeError.malformedResponse }
        var allowed: Set<String> = []
        Self.strings(value) { if $0.hasPrefix("nodus://") { allowed.insert($0) } }
        let pattern = try NSRegularExpression(pattern: "nodus://[^\\s<>()\"'\\[\\]]+")
        var invalid = false
        Self.strings(.object(result)) { text in
            let ns = text as NSString
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if !allowed.contains(ns.substring(with: match.range)) { invalid = true }
            }
        }
        guard !invalid else { throw DesktopBridgeError.malformedResponse }
        let notice = "Generado en el móvil a partir de las fuentes descargadas y seleccionadas; no representa todo el vault."
        if scope == "device_downloads" {
            result["draftMarkdown"] = .string("> \(notice)\n\n\(markdown)")
            result["limitations"] = .array([.string(notice)] + (result["limitations"]?.arrayValue ?? []))
        }
        result["brief"] = request["brief"]; result["selection"] = request["selection"]
        result["generatedAt"] = .string(generatedAt); result["generationModel"] = request["model"]
        return .object(result)
    }
    public static func downloaded(cache: PrivateBridgeCache, vaultId: String) async throws -> CompanionWorkshopSource? {
        let copies = try await cache.downloadedData(vaultId: vaultId, domain: .corpus, recordId: recordId)
        guard !copies.isEmpty else { return nil }
        return try Self(copies: copies.map { try JSONDecoder.nodus.decode(JSONValue.self, from: $0) })
    }
    private static func envelope(_ configuration: [String: JSONValue], items: [String: [String: JSONValue]]) -> JSONValue {
        var copy = configuration
        copy["groups"] = .object(Dictionary(uniqueKeysWithValues: groups.values.map { group in
            (group, .array((items[group] ?? [:]).keys.sorted().compactMap { items[group]?[$0] }))
        }))
        return .object(copy)
    }
    private static func isHash(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func identity(_ value: JSONValue?) -> String? {
        if let id = value?.stringValue { return id }
        return value?.intValue.map { String($0) }
    }
    private static func strings(_ value: JSONValue, visit: (String) -> Void) {
        switch value {
        case .string(let text): visit(text)
        case .object(let body): for value in body.values { strings(value, visit: visit) }
        case .array(let values): for value in values { strings(value, visit: visit) }
        default: break
        }
    }
}
