import Foundation
import Testing
@testable import NodusKit

@Suite("Granted private research context")
struct PrivateCorpusSourceMaterialTests {
    private func copy(_ kind: PrivateCorpusReference.Kind, id: String = "source/37", root: [String:JSONValue], groups: [String:[[String:JSONValue]]] = [:]) throws -> CompanionPrivateSourceCopy {
        let reference = try PrivateCorpusReference(kind: kind,id: id)
        var fields = root; fields[kind.primaryKey] = .string(id)
        let rows = Dictionary(uniqueKeysWithValues: kind.groups.map { key in
            (key,(groups[key] ?? []).enumerated().map { index, value in
                var row = value; row["_bridge_cursor"] = .int(Int64(index + 1)); return Row(row)
            })
        })
        let metadata: JSONValue = .object(["version":.int(1),"kind":.string(kind.rawValue),"id":.string(id),"root":.object(fields),
            "revision":.string(String(repeating:"a",count:64)),"groups":.array(kind.groups.map { key in
                .object(["key":.string(key),"title":.string(key),"total":.int(Int64(rows[key]!.count)),"revision":.string(String(repeating:"b",count:64))])
            })])
        let source = try JSONDecoder.nodus.decode(PrivateCorpusSource.self,from: JSONEncoder.nodus.encode(metadata))
        return try .init(source: source,rows: rows,reference: reference)
    }
    private func recording() throws -> CompanionPrivateSourceCopy {
        try copy(.recording,root:["title":.string("Fotografía"),"audio_blob":.string("NEVER CONTEXT"),"national_id":.string("NEVER CONTEXT")],groups:[
            "transcripts":[["id":.string("literal/37"),"recording_id":.string("source/37"),"content_markdown":.string("37 datos íntegros ".repeated(5000)),"kind":.string("literal"),"version_no":.int(3)]],
            "segments":[["transcript_id":.string("unselected-transcript"),"text":.string("FOREIGN NEVER CONTEXT")]],
        ])
    }
    @Test("literal versions and canonical citation IDs survive without exposing arbitrary columns")
    func literalVersions() throws {
        let rows = try PrivateCorpusSourceMaterial.selected(copy: recording())
        let body = try #require(rows.first { $0.string("contentScope") == "record" })
        #expect(body.string("text") == "37 datos íntegros ".repeated(5000))
        #expect(body.string("citation") == "nodus://study/recording/source%2F37?transcript=literal%2F37")
        #expect(body.string("locator")?.contains("v3") == true)
        #expect(try String(decoding:JSONEncoder.nodus.encode(rows.map(\.columns)),as:UTF8.self).contains("NEVER CONTEXT") == false)
        _ = try CorpusSourceMaterial(row: body)
        var forged = body.columns; forged["domain"] = .string("corpus")
        #expect(throws: DesktopBridgeError.self) { try CorpusSourceMaterial(row: Row(forged)) }
        forged = body.columns; forged["citation"] = .string("nodus://study/recording/source%2F37?transcript=other&extra=secret")
        #expect(throws: DesktopBridgeError.self) { try CorpusSourceMaterial(row: Row(forged)) }
    }
    @Test("source locators without literal evidence remain metadata and foreign owned extracts fail")
    func ownership() throws {
        let metadata = try copy(.source,root:["title":.string("Fuente")],groups:["segments":[["source_id":.string("source/37"),"locator_display":.string("folio 37")]]])
        #expect(try PrivateCorpusSourceMaterial.selected(copy: metadata).first?.string("contentScope") == "metadata")
        let foreign = try copy(.source,root:["title":.string("Fuente")],groups:["segments":[["source_id":.string("different"),"quoted_text":.string("No pertenece")]]])
        #expect(throws: DesktopBridgeError.self) { try PrivateCorpusSourceMaterial.selected(copy: foreign) }
    }
    @Test("downloaded private context requires both explicit pack selection and the current domain grant")
    func selectedDownloads() async throws {
        let id = UUID().uuidString, directory = URL.temporaryDirectory.appendingPathComponent(id)
        let keychain = KeychainStore(service:"nodus.tests.private-context.\(id)")
        defer { try? FileManager.default.removeItem(at: directory); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId:id)) }
        let cache = try PrivateBridgeCache(pairingId:id,directory:directory,keychain:keychain,readLimitBytes:1_000_000)
        let copy = try recording(), reference = try PrivateCorpusReference(kind:.recording,id:copy.source.id)
        let data = try JSONEncoder.nodus.encode(copy)
        try await cache.store(data,vaultId:"vault",domain:.studyRecordings,recordId:reference.recordKey)
        #expect(try await CompanionSelectedContext.downloaded(cache:cache,vaultId:"vault",domains:[.studyRecordings]) == nil)
        let pack = try await cache.saveReadPack(vaultId:"vault",title:"Elegida",expiresAt:.distantFuture,records:[
            .init(domain:.studyRecordings,recordId:reference.recordKey,data:data),
            .init(domain:.studyRecordings,recordId:CompanionPrivateSourceCopy.catalogueKey,data:JSONEncoder.nodus.encode(CompanionPrivateSourceCopy.CatalogueEntry(source:copy.source))),
        ])
        #expect(try await CompanionSelectedContext.downloaded(cache:cache,vaultId:"vault",domains:[.corpus]) == nil)
        let context = try #require(try await CompanionSelectedContext.downloaded(cache:cache,vaultId:"vault",domains:[.studyRecordings]))
        let response = try context.response(body:.object(["query":.string("fotografía 37"),"include":.array([.string("sources")]),"budget":.int(1000)]))
        let package = try JSONDecoder.nodus.decode(ContextPackage.self,from:response.data)
        #expect(package.stats.truncated)
        #expect(package.sections.flatMap(\.items).allSatisfy { $0.string("contentScope") == "metadata" })
        try await cache.removeReadPack(id:pack.id,vaultId:"vault")
        #expect(try await CompanionSelectedContext.downloaded(cache:cache,vaultId:"vault",domains:[.studyRecordings]) == nil)
    }
}

private extension String {
    func repeated(_ count: Int) -> String { String(repeating:self,count:count) }
}
