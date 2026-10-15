import Foundation

/// Canonical, explicitly selected subject knowledge. Paging cannot mix source
/// revisions; incomplete downloads never replace a usable existing selection.
public struct CompanionStudyKnowledgeCopy: Sendable {
    public static let recordId = "companion:study-knowledge:v1"
    public private(set) var value: JSONValue
    public let total: Int
    public var count: Int { value.objectValue?["ideas"]?.arrayValue?.count ?? 0 }
    public init(first: JSONValue, vaultId: String, subjectId: String) throws {
        guard let page = first.objectValue,
              page["version"] == .int(1), page["vaultId"] == .string(vaultId), page["subjectId"] == .string(subjectId),
              page["offset"] == .int(0), page["limit"] == .int(80),
              let total = page["total"]?.intValue, total >= 0, page["total"] == .int(Int64(total)),
              let revision = page["revision"]?.stringValue, revision.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              let workspace = page["workspace"]?.objectValue,
              let subjects = workspace["subjects"]?.arrayValue, subjects.count == 1,
              subjects.first?.objectValue?["id"] == .string(subjectId),
              let course = subjects.first?.objectValue?["courseId"]?.stringValue,
              workspace["courses"]?.arrayValue?.count == 1,
              workspace["courses"]?.arrayValue?.first?.objectValue?["id"] == .string(course),
              page["graph"]?.objectValue?["nodes"]?.arrayValue != nil,
              page["graph"]?.objectValue?["edges"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        self.total = total
        var initial = page; initial["ideas"] = .array([]); initial["details"] = .array([])
        self.value = .object(initial)
        try append(first)
    }
    public mutating func append(_ pageValue: JSONValue) throws {
        guard var accumulated = value.objectValue, let page = pageValue.objectValue,
              ["version","vaultId","subjectId","revision","total","limit","workspace"].allSatisfy({page[$0] == accumulated[$0]}),
              page["offset"] == .int(Int64(count)),
              let ideas = page["ideas"]?.arrayValue, let details = page["details"]?.arrayValue,
              ideas.count == details.count, ideas.count == min(80,total-count),
              page["hasMore"] == .bool(count+ideas.count < total) else { throw DesktopBridgeError.malformedResponse }
        let known = Set((accumulated["ideas"]?.arrayValue ?? []).compactMap{$0.objectValue?["id"]?.stringValue})
        var added = Set<String>()
        for (idea,detail) in zip(ideas,details) {
            guard let id = idea.objectValue?["id"]?.stringValue, !id.isEmpty, !known.contains(id), added.insert(id).inserted,
                  idea.objectValue?["subjectId"] == accumulated["subjectId"],
                  detail.objectValue?["id"] == .string(id), detail.objectValue?["subjectId"] == accumulated["subjectId"],
                  detail.objectValue?["evidence"]?.arrayValue != nil, detail.objectValue?["connections"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        }
        if let graph = page["graph"], graph != accumulated["graph"] { throw DesktopBridgeError.malformedResponse }
        accumulated["ideas"] = .array((accumulated["ideas"]?.arrayValue ?? [])+ideas)
        accumulated["details"] = .array((accumulated["details"]?.arrayValue ?? [])+details)
        accumulated["hasMore"] = page["hasMore"]
        value = .object(accumulated)
    }
    public init(saved: JSONValue, vaultId: String) throws {
        guard let fields = saved.objectValue, let subject = fields["subjectId"]?.stringValue,
              let ideas = fields["ideas"]?.arrayValue, let details = fields["details"]?.arrayValue,
              fields["total"] == .int(Int64(ideas.count)), ideas.count == details.count,
              fields["hasMore"] == .bool(false) else { throw DesktopBridgeError.malformedResponse }
        var first = fields; first["ideas"] = .array(Array(ideas.prefix(80))); first["details"] = .array(Array(details.prefix(80))); first["hasMore"] = .bool(ideas.count > 80)
        try self.init(first:.object(first),vaultId:vaultId,subjectId:subject)
        while count < total {
            let offset = count, end = min(count+80,total)
            var page = fields; page["offset"] = .int(Int64(offset)); page["ideas"] = .array(Array(ideas[offset..<end])); page["details"] = .array(Array(details[offset..<end])); page["hasMore"] = .bool(end<total); page["graph"] = nil
            try append(.object(page))
        }
        guard try completed() == saved else { throw DesktopBridgeError.malformedResponse }
    }
    public func completed() throws -> JSONValue {
        guard count == total, value.objectValue?["hasMore"] == .bool(false),
              let nodes = value.objectValue?["graph"]?.objectValue?["nodes"]?.arrayValue,
              nodes.count == total,
              Set(nodes.compactMap{$0.objectValue?["id"]?.stringValue}) == Set(value.objectValue?["ideas"]?.arrayValue?.compactMap{$0.objectValue?["id"]?.stringValue} ?? []) else { throw DesktopBridgeError.malformedResponse }
        return value
    }
}
