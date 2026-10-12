import Foundation

/// Citable text from granted private sources. Identity profiles, consent,
/// contacts and media bytes are deliberately outside this context projection.
public struct PrivateCorpusSourceMaterial: Sendable {
    private static let routes: [PrivateCorpusReference.Kind: String] = [
        .archive: "primary-source", .recording: "study/recording", .person: "prosop/person", .source: "prosop/source",
        .factoid: "prosop/factoid", .mention: "prosop/mention", .participant: "testimonios/participant",
        .interview: "testimonios/interview", .testimonyTranscript: "testimonios/transcript", .contrast: "testimonios/contrast",
    ]
    public let row: Row
    public init(row: Row) throws {
        guard Set(row.columns.keys).isSubset(of: ["version","privateKind","domain","recordId","kind","citation","label","text","contentScope","locator"]),
              row.int("version") == 1, let kind = row.string("privateKind").flatMap(PrivateCorpusReference.Kind.init(rawValue:)),
              row.string("domain") == kind.domain.rawValue, let id = row.string("recordId"),
              let token = row.string("citation"), let url = URL(string: token), let target = PrivateCorpusReference(url),
              target.kind == kind, target.id == id, target.timestamp == nil, target.sessionId == nil, target.annotationId == nil,
              kind == .recording || target.transcriptId == nil,
              token == Self.citation(kind: kind,id: id,transcriptId: target.transcriptId),
              row.string("kind") == Self.routes[kind]?.components(separatedBy: "/").first,
              !(row.text("label") ?? "").isEmpty, !(row.text("text") ?? "").isEmpty,
              ["record","metadata"].contains(row.string("contentScope") ?? "") else { throw DesktopBridgeError.malformedResponse }
        self.row = row
    }
    private static func citation(kind: PrivateCorpusReference.Kind, id: String, transcriptId: String? = nil) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let path = routes[kind], let identity = id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let suffix: String
        if let transcriptId {
            guard let encoded = transcriptId.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            suffix = "?transcript=\(encoded)"
        } else { suffix = "" }
        return "nodus://\(path)/\(identity)\(suffix)"
    }
    public static func selected(copy: CompanionPrivateSourceCopy) throws -> [Row] {
        let kind = copy.source.kind, id = copy.source.id, root = copy.source.root
        try copy.validate(for: PrivateCorpusReference(kind: kind,id: id))
        if kind == .source, (copy.rows["segments"] ?? []).contains(where: { $0.string("source_id") != id }) { throw DesktopBridgeError.malformedResponse }
        if kind == .factoid || kind == .mention,
           (copy.rows["segments"] ?? []).contains(where: { $0.string("segment_id") != root.string("source_segment_id") || $0.string("source_id") != root.string("source_id") }) { throw DesktopBridgeError.malformedResponse }
        if kind == .contrast, (copy.rows["items"] ?? []).contains(where: { $0.string("contrast_id") != id }) { throw DesktopBridgeError.malformedResponse }
        func text(_ row: Row, _ fields: [String]) -> String {
            fields.compactMap { row.string($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        }
        func records(_ key: String, _ fields: [String]) -> String {
            (copy.rows[key] ?? []).filter { key != "segments" || !($0.string("quoted_text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { text($0,fields) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let label = ["title","display_name","literal_name","short_id"].compactMap { root.string($0) }.first { !$0.isEmpty } ?? id
        var result: [Row] = []
        func add(_ targetKind: PrivateCorpusReference.Kind, _ targetId: String, _ body: String, record: Bool, transcriptId: String? = nil, locator: String? = nil) throws {
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard let token = citation(kind: targetKind,id: targetId,transcriptId: transcriptId), let route = routes[targetKind] else { throw DesktopBridgeError.malformedResponse }
            var fields: [String:JSONValue] = ["version":.int(1),"privateKind":.string(targetKind.rawValue),"domain":.string(targetKind.domain.rawValue),
                "recordId":.string(targetId),"kind":.string(route.components(separatedBy: "/")[0]),"citation":.string(token),
                "label":.string(label),"text":.string(body),"contentScope":.string(record ? "record" : "metadata")]
            if let locator { fields["locator"] = .string(locator) }
            result.append(try Self(row: Row(fields)).row)
        }
        switch kind {
        case .archive:
            for key in ["profile", "excerpts", "textVersions", "files"] {
                guard (copy.rows[key] ?? []).allSatisfy({ $0.string("item_id") == id }) else { throw DesktopBridgeError.malformedResponse }
            }
            let versions = Set((copy.rows["textVersions"] ?? []).compactMap { $0.string("text_version_id") })
            guard (copy.rows["segments"] ?? []).allSatisfy({ versions.contains($0.string("text_version_id") ?? "") }),
                  (copy.rows["evidence"] ?? []).allSatisfy({ $0.string("source_kind") == "archive" && $0.string("nodus_id") == id }) else { throw DesktopBridgeError.malformedResponse }
            let literal = [text(root,["extracted_text"]), records("textVersions",["content","normalized_text"]),
                (copy.rows["segments"] ?? []).map { text($0,["content","text"]) }.filter { !$0.isEmpty }.joined(separator: "\n\n"), records("excerpts",["locator_display","quoted_text"])].filter { !$0.isEmpty }.joined(separator: "\n\n")
            try add(kind,id,[text(root,["title","description"]),literal].filter { !$0.isEmpty }.joined(separator: "\n\n"),record: !literal.isEmpty)
        case .recording, .interview, .testimonyTranscript:
            if kind != .testimonyTranscript { try add(kind,id,text(root,kind == .interview ? ["title","objective","context_markdown","abstract"] : ["title","session_label"]),record: false) }
            let transcripts = kind == .testimonyTranscript ? [root] : copy.rows["transcripts"] ?? []
            for transcript in transcripts {
                if kind == .recording && transcript.string("recording_id") != id || kind == .interview && transcript.string("interview_id") != id { throw DesktopBridgeError.malformedResponse }
                guard let transcriptId = transcript.string("id"), !transcriptId.isEmpty else { throw DesktopBridgeError.malformedResponse }
                var body = text(transcript,["content_markdown"])
                if body.isEmpty { body = (copy.rows["segments"] ?? []).filter { $0.string("transcript_id") == transcriptId && !($0.string("text") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { text($0,["text","speaker","speaker_label"]) }.filter { !$0.isEmpty }.joined(separator: "\n\n") }
                let locator = "\(transcript.string("kind") ?? "Transcripción") · v\(transcript.int("version_no") ?? 1) · \(transcript.string("language") ?? "") · \(transcript.string("status") ?? "")"
                try add(kind == .recording ? kind : .testimonyTranscript,kind == .recording ? id : transcriptId,body,record: true,
                    transcriptId: kind == .recording ? transcriptId : nil,locator: locator)
            }
        case .source:
            let literal = records("segments",["locator_display","quoted_text"])
            try add(kind,id,[text(root,["title","citation","description","coverage_notes","reliability_notes"]),literal].filter { !$0.isEmpty }.joined(separator: "\n\n"),record: !literal.isEmpty)
        case .factoid, .mention:
            let literal = records("segments",["locator_display","quoted_text"])
            try add(kind,id,[text(root,kind == .factoid ? ["summary","factoid_kind","status","extraction_certainty"] : ["literal_name","context","role_or_title","identity_status","certainty"]),literal,
                records("statements",["literal_value","rationale","reading_certainty","source_assertion_certainty"])].filter { !$0.isEmpty }.joined(separator: "\n\n"),record: !literal.isEmpty)
        case .contrast:
            let literal = records("items",["quote_snapshot"])
            try add(kind,id,[text(root,["title","memo_markdown"]),literal].filter { !$0.isEmpty }.joined(separator: "\n\n"),record: !literal.isEmpty)
        case .person, .participant:
            try add(kind,id,text(root,["display_name","notes","biography"]),record: false)
        }
        return result
    }
}
