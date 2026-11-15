import Foundation
import Testing
@testable import NodusKit

@Suite("Current companion manuscript sources")
struct CompanionProseDraftTests {
    private var baseRequest: JSONValue { .object(["kind": .string("prose"), "sceneId": .string("scene"), "language": .string("es")]) }
    private var baseline: JSONValue { .object([
        "version": .int(1), "request": baseRequest, "revision": .string(String(repeating: "a", count: 64)),
        "source": .object(["sceneId": .string("scene"), "beats": .array([]), "noMaterial": .bool(true),
            "sources": .object(["sceneTitle": .string("Título guardado"), "beats": .array([]), "prose": .string("Texto antiguo")]),
            "prompt": .object(["system": .string("Sistema original"), "user": .string("Prompt anterior"), "plainContext": .bool(true), "temperature": .double(0.2), "maxTokens": .int(600)]),
            "draftTemplate": .object(["scene": .string("ESCENA"), "declaredBeats": .string("LO QUE DIJISTE QUE TENÍA QUE PASAR"), "sceneText": .string("EL TEXTO DE LA ESCENA"),
                "askTemplate": .string("Dime, en 92837 línea(s) y en ese mismo orden, cuáles aparecen."),
                "threadKinds": .object(["rule": .string("regla"), "arc": .string("arco"), "conflict": .string("conflicto")]),
                "beatMarks": .object(["breaks": .string("Se rompe")]), "replyMarks": .object(["breaks": .string("Se rompe")])])]),
        "emptyPreview": .object(["noMaterial": .bool(true), "beats": .array([])])]) }
    private var beat: JSONValue { .object(["threadKind": .string("rule"), "threadId": .string("rule"), "threadTitle": .string("La puerta"), "mark": .string("breaks"), "text": .string("Se paga.")]) }
    private func request(_ text: String, beats: [JSONValue]? = nil) -> JSONValue {
        var value = baseRequest.objectValue!
        value["draft"] = .object(["sceneTitle": .string("Título local"), "text": .string(text), "beats": .array(beats ?? [beat])])
        return .object(value)
    }
    @Test("a downloaded scene template reads the current draft and pending declared beats")
    func currentDraft() throws {
        let requested = request("[Ada](nodus://world/character/ada) cruza [[Puerta]].")
        let value = try CompanionProseDraft.source(baseline, request: requested)
        let source = try CompanionAcademicSource(value, request: requested)
        #expect(source.needsModel)
        #expect(source.completion["system"] == .string("Sistema original"))
        #expect(source.completion["user"] == .string("ESCENA: Título local\n\nLO QUE DIJISTE QUE TENÍA QUE PASAR:\n1. regla: La puerta — Se rompe: Se paga.\n\nEL TEXTO DE LA ESCENA:\nAda cruza Puerta.\n\nDime, en 1 línea(s) y en ese mismo orden, cuáles aparecen."))
        let preview = try source.preview(raw: "LATIDO: sí — Cruza la puerta.", model: .null, generatedAt: "2026-10-11T12:00:00Z")
        #expect(preview.objectValue?["beats"]?.arrayValue?.first?.objectValue?["threadId"] == .string("rule"))
        #expect(preview.objectValue?["beats"]?.arrayValue?.first?.objectValue?["present"] == .bool(true))
        #expect(baseline.objectValue?["source"]?.objectValue?["sources"]?.objectValue?["prose"] == .string("Texto antiguo"))
        #expect(try CompanionProseDraft.source(baseline, request: request("Otro borrador")).objectValue?["revision"] != value.objectValue?["revision"])
    }
    @Test("empty prose or beats stays unread and invalid local beat identities are refused")
    func noInventedReview() throws {
        let requested = request("", beats: [beat])
        let source = try CompanionAcademicSource(CompanionProseDraft.source(baseline, request: requested), request: requested)
        #expect(!source.needsModel)
        #expect(try source.preview(raw: "LATIDO: sí — inventado", model: .null, generatedAt: "date").objectValue?["beats"] == .array([]))
        #expect(throws: DesktopBridgeError.malformedResponse) { try CompanionProseDraft.source(baseline, request: request("Texto", beats: [beat, beat])) }
    }

    @Test("A durable fresh scene uses the shared template and keeps its unsaved draft separate")
    func localScene() throws {
        let identity=UUID().uuidString.lowercased(),requested=request("Ada paga por cruzar la puerta.")
        let saved:JSONValue = .object(["sceneTitle":.string("Título local"),"text":.string(""),"beats":.array([beat])])
        let value=try CompanionProseDraft.localSceneSource(request:requested,creationMutationId:identity,baselineDraft:saved)
        let captured=try CompanionAcademicSource(value,request:requested)
        #expect(captured.needsModel)
        #expect(captured.completion["user"]?.stringValue?.contains("Ada paga por cruzar la puerta.")==true)
        #expect(value.objectValue?["localScene"]?.objectValue?["baselineDraft"]==saved)
        #expect(try CompanionProseDraft.localSceneSource(request:requested,creationMutationId:UUID().uuidString,baselineDraft:saved).objectValue?["revision"] != value.objectValue?["revision"])
        let model:JSONValue = .object(["provider":.string("phone"),"model":.string("model")])
        let preview=try captured.preview(raw:"LATIDO: sí — Se paga.",model:model,generatedAt:"2026-10-11T12:00:00Z")
        let checkpoint:JSONValue = .object(["id":.string(UUID().uuidString),"state":.string("saved"),"entityKey":.string("scene"),
            "request":.object(["source":requested,"model":model]),"context":.object(["source":value,"revision":.string(captured.revision)]),
            "raw":.string("LATIDO: sí — Se paga."),"preview":preview,"generatedAt":.string("2026-10-11T12:00:00Z")])
        let publication=try #require(try CompanionGenerationPublication(kind:"academic",entity:"scene",checkpoint:checkpoint))
        #expect(publication.args.first?.objectValue?["localScene"] == value.objectValue?["localScene"])
        #expect(publication.method=="saveMobileAcademicResult")
        #expect(throws:DesktopBridgeError.malformedResponse) { try CompanionProseDraft.localSceneSource(request:requested,creationMutationId:"unconfirmed",baselineDraft:saved) }
    }

    @Test("Every bundled Desktop language preserves the exact current prose source")
    func languages() throws {
        for language in ["es","en","fr","tr","de","pt","pt-BR","it","vi","ja","ru","uk","ko","zh-Hans","zh-Hant"] {
            var requested=request("Texto presente").objectValue!;requested["language"] = .string(language)
            let current=try CompanionProseDraft.localSceneSource(request:.object(requested),creationMutationId:UUID().uuidString,baselineDraft:requested["draft"]!)
            #expect(try CompanionAcademicSource(current,request:.object(requested)).needsModel)
        }
    }
}
