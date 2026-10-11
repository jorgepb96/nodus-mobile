import Foundation
import CryptoKit

/// Rebuild the exact portable Desktop prose prompt for the current local draft.
/// The template is captured from Desktop, including its language vocabulary.
public enum CompanionProseDraft {
    /// Only a durable, locally-created scene can use this provisional baseline.
    /// Publication independently checks the Mac's creation receipt and sources.
    public static func localSceneSource(request:JSONValue, creationMutationId:String, baselineDraft:JSONValue) throws -> JSONValue {
        guard UUID(uuidString:creationMutationId) != nil, var requested=request.objectValue,
              requested["kind"] == .string("prose"), requested["draft"]?.objectValue != nil,
              let sceneId=requested["sceneId"]?.stringValue, !sceneId.isEmpty,
              let language=requested["language"]?.stringValue,
              let url=Bundle.module.url(forResource:"prose-draft-templates",withExtension:"json") else { throw DesktopBridgeError.malformedResponse }
        let templates=try JSONDecoder.nodus.decode(JSONValue.self,from:Data(contentsOf:url))
        guard templates.objectValue?["version"] == .int(1), let template=templates.objectValue?["templates"]?.objectValue?[language]?.objectValue,
              let templateRevision=template["templateRevision"]?.stringValue, templateRevision.count == 64,
              var source=template["source"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
        source["sceneId"] = .string(sceneId); requested["draft"] = nil
        let seed=hash(["mobile-prose-local-scene-v1",sceneId,language,creationMutationId,templateRevision])
        var baseline:[String:JSONValue] = ["version":.int(1),"request":.object(requested),"revision":.string(seed),"source":.object(source),"emptyPreview":.object(["beats":.array([]),"noMaterial":.bool(true)])]
        var baseRequest=requested;baseRequest["draft"] = baselineDraft
        guard var captured=try self.source(.object(baseline),request:.object(baseRequest)).objectValue else { throw DesktopBridgeError.malformedResponse }
        captured["request"] = .object(requested);baseline=captured
        guard var result=try self.source(.object(baseline),request:request).objectValue else { throw DesktopBridgeError.malformedResponse }
        result["localScene"] = .object(["creationMutationId":.string(creationMutationId),"baselineDraft":baselineDraft])
        return .object(result)
    }

    private static func hash(_ fields:[String]) -> String {
        let framed=fields.map{ "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data:Data(framed.utf8)).map{String(format:"%02x",$0)}.joined()
    }

    public static func source(_ baseline: JSONValue, request: JSONValue) throws -> JSONValue {
        guard var requested = request.objectValue, let draft = requested["draft"]?.objectValue,
              Set(draft.keys) == ["sceneTitle", "text", "beats"], let sceneTitle = draft["sceneTitle"]?.stringValue, sceneTitle.utf16.count <= 4096,
              let text = draft["text"]?.stringValue, text.utf8.count <= 500_000,
              let beats = draft["beats"]?.arrayValue, beats.count <= 512 else { throw DesktopBridgeError.malformedResponse }
        requested["draft"] = nil
        let captured = try CompanionAcademicSource(baseline, request: .object(requested))
        guard captured.kind == "prose", var value = baseline.objectValue,
              var source = value["source"]?.objectValue, var original = source["sources"]?.objectValue,
              var prompt = source["prompt"]?.objectValue, let template = source["draftTemplate"]?.objectValue,
              let scene = template["scene"]?.stringValue, let declared = template["declaredBeats"]?.stringValue,
              let sceneText = template["sceneText"]?.stringValue, let ask = template["askTemplate"]?.stringValue,
              let kinds = template["threadKinds"]?.objectValue, let marks = template["beatMarks"]?.objectValue,
              let replies = template["replyMarks"]?.objectValue else { throw DesktopBridgeError.malformedResponse }
        let permitted: [String: Set<String>] = ["rule": ["obeys", "bends", "breaks", "establishes"], "conflict": ["raise", "turn", "ease", "resolve"], "arc": ["step", "turn"]]
        var identities: Set<String> = [], fields = ["mobile-prose-draft-v1", captured.revision, sceneTitle, text, String(beats.count)]
        var normalized: [JSONValue] = [], inputs: [JSONValue] = [], preview: [JSONValue] = []
        var lines = ["\(scene): \(sceneTitle)", "", "\(declared):"]
        for (index, input) in beats.enumerated() {
            guard let beat = input.objectValue, Set(beat.keys).isSubset(of: ["threadKind", "threadId", "threadTitle", "mark", "text"]),
                  let kind = beat["threadKind"]?.stringValue, let id = beat["threadId"]?.stringValue, !id.isEmpty, id.utf16.count <= 256,
                  let title = beat["threadTitle"]?.stringValue, title.utf16.count <= 4096,
                  let mark = beat["mark"]?.stringValue, permitted[kind]?.contains(mark) == true,
                  let kindLabel = kinds[kind]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            let note: String?
            if beat["text"] == nil || beat["text"] == .null { note = nil }
            else { guard let text = beat["text"]?.stringValue, text.utf16.count <= 4096 else { throw DesktopBridgeError.malformedResponse }; note = text }
            guard identities.insert("\(kind):\(id)").inserted else { throw DesktopBridgeError.malformedResponse }
            let label = "\(kindLabel): \(title)", translated = marks[mark]?.stringValue ?? mark
            normalized.append(.object(["threadKind": .string(kind), "threadId": .string(id), "threadTitle": .string(title), "mark": .string(mark), "text": note.map(JSONValue.string) ?? .null]))
            inputs.append(.object(["threadLabel": .string(label), "mark": .string(translated), "text": note.map(JSONValue.string) ?? .null]))
            preview.append(.object(["threadKind": .string(kind), "threadId": .string(id), "threadTitle": .string(title), "mark": replies[mark] ?? .string(mark), "present": .null, "note": .null]))
            lines.append("\(index + 1). \(label) — \(translated)\(note.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? "")")
            fields += [kind, id, title, mark, note ?? ""]
        }
        let prose = text.replacingOccurrences(of: #"\[([^\]\n]*)\]\(nodus://world/[a-z]+/[^)\s]+\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\[\[([^\]\[\n]+)\]\]"#, with: "$1", options: .regularExpression)
        let clean = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        let noMaterial = beats.isEmpty || clean.isEmpty
        lines += ["", "\(sceneText):", clean, "", ask.replacingOccurrences(of: "92837", with: String(beats.count))]
        original["sceneTitle"] = .string(sceneTitle); original["prose"] = .string(prose); original["beats"] = .array(inputs)
        prompt["user"] = .string(lines.joined(separator: "\n"))
        source["sources"] = .object(original); source["beats"] = .array(normalized)
        source["prompt"] = .object(prompt); source["noMaterial"] = .bool(noMaterial)
        var finalRequest = requested; finalRequest["draft"] = .object(["sceneTitle": .string(sceneTitle), "text": .string(text), "beats": .array(normalized)])
        guard request == .object(finalRequest) else { throw DesktopBridgeError.malformedResponse }
        value["request"] = request; value["source"] = .object(source)
        value["emptyPreview"] = .object(["beats": .array(noMaterial ? [] : preview), "noMaterial": .bool(noMaterial)])
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        value["revision"] = .string(SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined())
        let result = JSONValue.object(value)
        guard try JSONEncoder.nodus.encode(result).count <= 2 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
        _ = try CompanionAcademicSource(result, request: request); return result
    }
}
