import Foundation
import Testing
@testable import NodusKit

@Suite("Canonical companion academic previews")
struct CompanionAcademicSourceTests {
    private func source(kind: String, fields: [String: JSONValue] = [:], empty: JSONValue? = nil) throws -> CompanionAcademicSource {
        let request: JSONValue = .object(["kind": .string(kind), "language": .string("es")])
        let prompt: JSONValue = .object(["system": .string("Desktop system"), "user": .string("Only actual source material")])
        var source = fields; source["prompt"] = prompt
        var value: [String: JSONValue] = ["version": .int(1), "revision": .string(String(repeating: "a", count: 64)), "request": request, "source": .object(source)]
        if let empty { value["emptyPreview"] = empty }
        return try CompanionAcademicSource(.object(value), request: request)
    }
    @Test("author previews use Desktop's trimming and six-item limit and reject malformed paid output")
    func author() throws {
        let captured = try source(kind: "author")
        let response = JSONValue.object(["thesis": .string("  Tesis  "), "positioning": .string("  Posición  "), "remember": .array((0..<9).map { .string("  \($0)  ") } + [.string("")])])
        let result = try captured.preview(raw: String(decoding: JSONEncoder.nodus.encode(response), as: UTF8.self), model: .null, generatedAt: "2026-10-11T08:00:00Z")
        #expect(result.objectValue?["thesis"] == .string("Tesis"))
        #expect(result.objectValue?["remember"]?.arrayValue?.count == 6)
        #expect(throws: DesktopBridgeError.malformedResponse) { try captured.preview(raw: #"{"thesis":"x","positioning":"y","remember":[true]}"#, model: .null, generatedAt: "date") }
    }
    @Test("matrix previews retain actual source identities and the complete idea count")
    func matrix() throws {
        let ideas = (0..<12).map { JSONValue.object(["global_id": .string("real-\($0)"), "label": .string("Idea \($0)"), "type": .string("claim"), "statement": .string("Original \($0)")]) }
        let captured = try source(kind: "matrix", fields: ["ideas": .array(ideas)])
        let result = try captured.preview(raw: #"{"stance":"  Una posición  ","ideas":["invented"]}"#, model: .null, generatedAt: "date")
        #expect(result.objectValue?["ideaCount"] == .int(12))
        #expect(result.objectValue?["ideas"]?.arrayValue?.count == 8)
        #expect(result.objectValue?["ideas"]?.arrayValue?.first?.objectValue?["global_id"] == .string("real-0"))
        #expect(result.objectValue?["stance"] == .string("Una posición"))
        #expect(try source(kind: "matrix", fields: ["ideas": .array([])]).needsModel == false)
    }
    @Test("scene verdicts keep missing replies unread, recognise accented yes, and reject partial word matches")
    func scene() throws {
        let beats = (0..<4).map { JSONValue.object(["threadId": .string("real-\($0)"), "threadKind": .string("conflict"), "threadTitle": .string("Conflicto \($0)"), "mark": .string("sube"), "present": .null, "note": .null]) }
        let captured = try source(kind: "prose", fields: ["noMaterial": .bool(false)], empty: .object(["beats": .array(beats), "noMaterial": .bool(false)]))
        let result = try captured.preview(raw: "**LATIDO:** sí — Está en la escena.\nLATIDO: no — Falta.\nLATIDO: nosotros\nLATIDO: silencio", model: .null, generatedAt: "date")
        let output = try #require(result.objectValue?["beats"]?.arrayValue)
        #expect(output[0].objectValue?["present"] == .bool(true))
        #expect(output[1].objectValue?["present"] == .bool(false))
        #expect(output[2].objectValue?["present"] == .null)
        #expect(output[3].objectValue?["present"] == .null)
        #expect(output[0].objectValue?["threadId"] == .string("real-0"))
        #expect(output[0].objectValue?["note"] == .string("Está en la escena."))
    }
}
