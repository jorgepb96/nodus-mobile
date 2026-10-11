import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Selected native research readers")
struct CompanionResearchCorpusCopyTests {
    static let imageBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ZkAAAAASUVORK5CYII=")!
    static var imageHash: String { SHA256.hash(data: imageBytes).map { String(format: "%02x", $0) }.joined() }
    static func copy(count: Int = 241, firstId: String = "report-0", withImage: Bool = true, withRelations: Bool = true) -> JSONValue {
        .object(["version": .int(1), "entries": .array((0..<count).map { index in
            let id = index == 0 ? firstId : "report-\(index)"
            var detail: [String: JSONValue] = ["report": .object(["id": .string(id), "title": .string("Informe \(index)"),
                "draft": .object(["draftMarkdown": .string("## Fuente\n\nTexto íntegro con [evidencia](nodus://passage/p).")])]),
                "image": .null, "translations": .array([]), "annotations": .array([]), "revision": .string("mac-original")]
            var entry: [String: JSONValue] = ["documentHTML": .string("<!doctype html><html><body>Informe \(index) · 37</body></html>")]
            if index == 0, withRelations {
                detail["translations"] = .array([.object(["id": .string("translation"), "entity_kind": .string("deep_research"), "entity_id": .string(id), "markdown": .string("Traducción completa")])])
                detail["annotations"] = .array([.object(["id": .string("annotation"), "draft_id": .string(id), "selected_text": .string("Texto íntegro")])])
            }
            if index == 0, withImage {
                detail["image"] = .object(["hash": .string(imageHash), "mime": .string("image/png")])
                entry["image"] = .object(["hash": .string(imageHash), "mime": .string("image/png"), "base64": .string(imageBytes.base64EncodedString())])
            }
            entry["detail"] = .object(detail)
            return .object(entry)
        })])
    }

    @Test("every selected report remains readable past page one, with export and actual illustration bytes")
    func nativeReaders() throws {
        let copy = try CompanionResearchCorpusCopy(copies: [Self.copy()])
        let page = try #require(copy.nativeResponse(path: "deep-research", query: [.init(name: "limit", value: "200"), .init(name: "offset", value: "200")], percentEncoded: false))
        let object = try JSONDecoder.nodus.decode(JSONValue.self, from: page.data).objectValue!
        #expect(object["reports"]?.arrayValue?.count == 41); #expect(object["total"] == .int(241)); #expect(object["hasMore"] == .bool(false))
        let detail = try #require(copy.nativeResponse(path: "deep-research/report-0", query: [], percentEncoded: false))
        let report = try JSONDecoder.nodus.decode(DeepResearchReportDetail.self, from: detail.data)
        #expect(report.report.embeddedJSON("draft")?.objectValue?["draftMarkdown"]?.stringValue?.contains("nodus://passage/p") == true)
        #expect(report.translations.count == 1); #expect(report.annotations?.count == 1)
        let document = try #require(copy.nativeResponse(path: "deep-research/report-240/document.html", query: [], percentEncoded: false))
        #expect(String(data: document.data, encoding: .utf8)?.contains("Informe 240 · 37") == true)
        let image = try #require(copy.nativeResponse(path: "assets/\(Self.imageHash)", query: [], percentEncoded: false))
        #expect(image.data == Self.imageBytes); #expect(image.headers["content-type"] == "image/png")
        #expect(throws: CompanionCollectionCopy.CopyError.self) { try copy.nativeResponse(path: "deep-research/unchosen", query: [], percentEncoded: false) }
        #expect(try copy.nativeResponse(path: "deep-research/report-0/document.pdf", query: [], percentEncoded: false) == nil)
        #expect(try copy.nativeResponse(path: "deep-research", query: [.init(name: "q", value: "unsupported")], percentEncoded: false) == nil)
    }

    @Test("newer removals and reserved identities do not revive old content or move to another source")
    func ownersAndValidation() throws {
        let id = "report/a%2F#x"
        let copy = try CompanionResearchCorpusCopy(copies: [Self.copy(count: 1, firstId: id, withImage: false, withRelations: false), Self.copy(count: 1, firstId: id)])
        let response = try #require(copy.nativeResponse(path: "deep-research/report%2Fa%252F%23x", query: [], percentEncoded: true))
        let detail = try JSONDecoder.nodus.decode(DeepResearchReportDetail.self, from: response.data)
        #expect(detail.report.string("id") == id); #expect(detail.translations.isEmpty); #expect(detail.annotations?.isEmpty == true); #expect(detail.image == nil)
        #expect(try copy.nativeResponse(path: "assets/\(Self.imageHash)", query: [], percentEncoded: false) == nil)
        var entry = Self.copy(count: 1).objectValue!["entries"]!.arrayValue![0].objectValue!
        entry["image"] = .object(["hash": .string(Self.imageHash), "mime": .string("image/png"), "base64": .string(Data("changed".utf8).base64EncodedString())])
        #expect(throws: DesktopBridgeError.self) { try CompanionResearchCorpusCopy(copies: [.object(["version": .int(1), "entries": .array([.object(entry)])])]) }
        entry = Self.copy(count: 1, withImage: false).objectValue!["entries"]!.arrayValue![0].objectValue!
        var detailObject = entry["detail"]!.objectValue!
        detailObject["annotations"] = .array([.object(["draft_id": .string("foreign")])]); entry["detail"] = .object(detailObject)
        #expect(throws: DesktopBridgeError.self) { try CompanionResearchCorpusCopy(copies: [.object(["version": .int(1), "entries": .array([.object(entry)])])]) }
    }
}
