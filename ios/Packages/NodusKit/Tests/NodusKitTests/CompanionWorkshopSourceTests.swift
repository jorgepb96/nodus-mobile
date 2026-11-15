import Foundation
import Testing
@testable import NodusKit

@Suite("Selected autonomous workshop material and durable publication")
struct CompanionWorkshopSourceTests {
    @Test("chosen workshop selections preserve all seven categories, including contradictions and tutor routes")
    func allChosenCategories() throws {
        let copies = CompanionWorkshopSource.groups.keys.sorted().map { key in copy(key, id: "chosen-\(key)", text: "Fuente completa de \(key) · 37 datos") }
        let source = try CompanionWorkshopSource(copies: copies)
        let selection: JSONValue = .object(Dictionary(uniqueKeysWithValues: CompanionWorkshopSource.groups.keys.map { key in
            (key, .array([.string("chosen-\(key)")]))
        }))
        let chosen = try source.selected(selection)
        for key in CompanionWorkshopSource.groups.keys {
            #expect(chosen.rows(for: key).count == 1)
            #expect(chosen.rows(for: key).first?.text("enunciado") == "Fuente completa de \(key) · 37 datos")
        }
        let restored = try CompanionWorkshopSource(copies: [JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(chosen.value))])
        #expect(restored.rows(for: "contradictionIds").count == 1)
        #expect(restored.rows(for: "tutorRouteIds").count == 1)
        var absent = selection.objectValue!; absent["tutorRouteIds"] = .array([.string("not-chosen")])
        #expect(throws: (any Error).self) { try restored.selected(.object(absent)) }
    }
    private let revision = String(repeating: "a", count: 64)
    private func copy(_ key: String = "ideaIds", id: String = "idea-a", text: String = "Enunciado literal", config: String? = nil) -> JSONValue {
        var groups: [String: JSONValue] = Dictionary(uniqueKeysWithValues: CompanionWorkshopSource.groups.values.map { ($0, .array([])) })
        let group = CompanionWorkshopSource.groups[key]!
        groups[group] = .array([.object(["id": .string(id), "revision": .string(revision),
            "value": .object(["id": .string(id), "enunciado": .string(text), "cita": .string("nodus://idea/\(id)"),
                "obra": .object(["id": .string("linked-work"), "titulo": .string("Contexto de la idea")])])])])
        return .object(["version": .int(1), "configurationRevision": .string(config ?? revision),
            "promptLanguage": .string("es"), "system": .string("Escribir con las fuentes elegidas"),
            "contextRule": .string("Mantener las referencias exactas"), "kindLabels": .object(["literature_review": .string("Estado de la cuestión")]),
            "maxOutputTokens": .int(16_000), "groups": .object(groups)])
    }
    private func request(_ ids: [String] = ["idea-a"]) throws -> JSONValue {
        .object(["brief": .object(["kind": .string("literature_review"), "objective": .string("Pregunta nueva"),
            "language": .string("es"), "tone": .string("critical")]),
            "selection": try CompanionWorkshopSource.selection(path: "ideas", ids: ids),
            "model": .object(["provider": .string("deepseek"), "model": .string("phone-model")])])
    }
    private func raw(_ citation: String = "nodus://idea/idea-a") throws -> String {
        String(decoding: try JSONEncoder.nodus.encode(JSONValue.object(["title": .string("Borrador del móvil"),
            "draftMarkdown": .string("Argumento con [fuente](\(citation))."), "outline": .array([.object(["title": .string("Contexto")])]),
            "matrix": .array([.object(["citation": .string(citation), "evidence": .string("Cita literal")])]),
            "bibliography": .array([.string("Fuente")]), "nextSteps": .array([.string("Revisar")])])), as: UTF8.self)
    }

    @Test("a new question retains complete selected material and no neighbouring primary source")
    func selectedOnly() throws {
        let literal = String(repeating: "Evidencia literal extensa. ", count: 300)
        let source = try CompanionWorkshopSource(copies: [copy(text: literal), copy(id: "idea-b", text: "Otra fuente")])
        let chosen = try source.selected(try request().objectValue!["selection"]!)
        #expect(chosen.rows(for: "ideaIds").count == 1)
        #expect(chosen.rows(for: "workIds").isEmpty)
        let prompt = try chosen.prompt(request: request()).objectValue!
        #expect(prompt["user"]?.stringValue?.contains(literal) == true)
        #expect(prompt["user"]?.stringValue?.contains("Pregunta nueva") == true)
        #expect(prompt["user"]?.stringValue?.contains("Otra fuente") == false)
        #expect(throws: CompanionWorkshopSource.SourceError.self) { try source.selected(try request(["unselected"]).objectValue!["selection"]!) }
    }

    @Test("newer selected dossiers win and outdated prompt configurations cannot mix")
    func revisions() throws {
        let updated = try CompanionWorkshopSource(copies: [copy(text: "Nuevo contenido"), copy(text: "Contenido viejo")])
        #expect(updated.rows(for: "ideaIds").first?.string("enunciado") == "Nuevo contenido")
        let changed = try CompanionWorkshopSource(copies: [copy(id: "new", config: String(repeating: "b", count: 64)), copy()])
        #expect(changed.rows(for: "ideaIds").count == 1)
        #expect(throws: CompanionWorkshopSource.SourceError.self) { try changed.selected(try request().objectValue!["selection"]!) }
    }

    @Test("native catalogue accepts later pages and rejects hidden truncation")
    func cataloguePages() throws {
        let rows: [JSONValue] = (100..<121).map { .object(["selection_id": .string("idea-\($0)"), "label": .string("Idea \($0)")]) }
        var value: [String: JSONValue] = ["items": .array(rows), "total": .int(121), "limit": .int(100),
            "offset": .int(100), "hasMore": .bool(false), "revision": .string(revision)]
        let page = try CompanionWorkshopSource.cataloguePage(.object(value))
        #expect(page.items.first?.string("selection_id") == "idea-100")
        #expect(page.items.count == 21)
        value["items"] = .array([])
        #expect(throws: DesktopBridgeError.self) { try CompanionWorkshopSource.cataloguePage(.object(value)) }
        value["offset"] = .int(200)
        #expect(try CompanionWorkshopSource.cataloguePage(.object(value)).items.isEmpty)
        value["items"] = .array([rows[0], rows[0]]); value["offset"] = .int(119)
        #expect(throws: DesktopBridgeError.self) { try CompanionWorkshopSource.cataloguePage(.object(value)) }
    }

    @Test("ordinary query caches cannot masquerade as chosen workshop downloads")
    func selectedStorage() async throws {
        let id = UUID().uuidString, root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let keychain = KeychainStore(service: "nodus.tests.workshop.\(id)")
        defer { try? FileManager.default.removeItem(at: root); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain, readLimitBytes: 100_000)
        let data = try JSONEncoder.nodus.encode(copy())
        try await cache.store(data, vaultId: "vault-a", domain: .corpus, recordId: CompanionWorkshopSource.recordId)
        #expect(try await CompanionWorkshopSource.downloaded(cache: cache, vaultId: "vault-a") == nil)
        let pack = try await cache.saveReadPack(vaultId: "vault-a", title: "Chosen source", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: CompanionWorkshopSource.recordId, data: data)])
        let reopened = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain, readLimitBytes: 100_000)
        #expect(try await CompanionWorkshopSource.downloaded(cache: reopened, vaultId: "vault-a")?.rows(for: "ideaIds").count == 1)
        #expect(try await CompanionWorkshopSource.downloaded(cache: reopened, vaultId: "vault-b") == nil)
        try await reopened.removeReadPack(id: pack.id, vaultId: "vault-a")
        #expect(try await CompanionWorkshopSource.downloaded(cache: reopened, vaultId: "vault-a") == nil)
    }

    @Test("structured preview preserves sections and explicitly states the device scope")
    func preview() throws {
        let source = try CompanionWorkshopSource(copies: [copy()])
        let result = try source.preview(raw: "```json\n\(try raw())\n```", request: request(), scope: "device_downloads", generatedAt: "2026-10-11T00:00:00Z")
        #expect(result.objectValue?["draftMarkdown"]?.stringValue?.contains("no representa todo el vault") == true)
        #expect(result.objectValue?["matrix"]?.arrayValue?.count == 1)
        #expect(result.objectValue?["outline"]?.arrayValue?.count == 1)
        #expect(result.objectValue?["bibliography"]?.arrayValue?.count == 1)
        #expect(throws: DesktopBridgeError.self) { try source.preview(raw: raw("nodus://idea/foreign"), request: request(), scope: "device_downloads", generatedAt: "now") }
        #expect(throws: DesktopBridgeError.self) { try source.preview(raw: "{\"title\":\"Incomplete\"}", request: request(), scope: "linked_corpus", generatedAt: "now") }
    }

    @Test("only a complete saved checkpoint queues the original source and phone response")
    func publication() throws {
        let identity = UUID().uuidString.lowercased(), entity = "workshop-request"
        let source = try CompanionWorkshopSource(copies: [copy()])
        let promptRequest = try request(), response = try raw()
        var checkpoint: [String: JSONValue] = ["id": .string(identity), "entityKey": .string(entity), "state": .string("saved"),
            "request": promptRequest, "context": .object(["revision": .string(revision), "source": source.value]),
            "raw": .string(response), "sourceScope": .string("device_downloads"),
            "preview": try source.preview(raw: response, request: promptRequest, scope: "device_downloads", generatedAt: "now")]
        let publication = try #require(try CompanionGenerationPublication(kind: "workshop", entity: entity, checkpoint: .object(checkpoint)))
        #expect(publication.id == identity)
        #expect(publication.method == "saveWritingWorkshopFromMobile")
        #expect(DesktopBridgeClient.providerFreeJobMethods.contains(publication.method))
        #expect(publication.args[0].objectValue?["source"] == source.value)
        #expect(publication.args[0].objectValue?["raw"] == .string(response))
        let stored = DesktopJobLedger.Request(id: identity, method: publication.method, args: publication.args,
            createdAt: Date(), jobId: nil, state: "pending", issue: nil, checkpoint: .object(checkpoint))
        #expect(CompanionResultCatalogue.contains(stored, in: "writingWorkshop"))
        #expect(!CompanionResultCatalogue.contains(stored, in: "workspace"))
        #expect(CompanionResultCatalogue.title(stored) == "Borrador del móvil")
        checkpoint["state"] = .string("running")
        #expect(try CompanionGenerationPublication(kind: "workshop", entity: entity, checkpoint: .object(checkpoint)) == nil)
        checkpoint["state"] = .string("saved"); checkpoint["preview"] = nil
        #expect(throws: DesktopBridgeError.self) { try CompanionGenerationPublication(kind: "workshop", entity: entity, checkpoint: .object(checkpoint)) }
    }
}
