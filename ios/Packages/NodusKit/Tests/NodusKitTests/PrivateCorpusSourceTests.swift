import Foundation
import Testing
@testable import NodusKit

@Suite("Addressed private source readers")
struct PrivateCorpusSourceTests {
    private func reference(_ address: String = "nodus://study/recording/recording?t=37.4&transcript=literal") throws -> PrivateCorpusReference {
        try #require(PrivateCorpusReference(URL(string: address)!))
    }
    private func source(_ target: PrivateCorpusReference, segmentCount: Int = 0) throws -> PrivateCorpusSource {
        let revision = String(repeating: "a", count: 64)
        let json: JSONValue = .object(["version": .int(1), "kind": .string(target.kind.rawValue), "id": .string(target.id),
            "root": .object([target.kind.primaryKey: .string(target.id), "title": .string("Fuente completa")]),
            "revision": .string(revision), "groups": .array(target.kind.groups.map { key in
                .object(["key": .string(key), "title": .string(key), "revision": .string(revision), "total": .int(Int64(key == "segments" ? segmentCount : 0))])
            })])
        return try JSONDecoder.nodus.decode(PrivateCorpusSource.self, from: JSONEncoder.nodus.encode(json))
    }

    @Test("canonical private links preserve real IDs, exact grants and timestamps")
    func references() throws {
        let recording = try reference()
        #expect(recording.kind.domain == .studyRecordings); #expect(recording.timestamp == 37.4); #expect(recording.transcriptId == "literal")
        for (route, kind) in [("person", PrivateCorpusReference.Kind.person), ("source", .source), ("factoid", .factoid), ("mention", .mention)] {
            let target = try reference("nodus://prosop/\(route)/private-id")
            #expect(target.kind == kind); #expect(target.kind.domain == .prosopographyPrivate)
            #expect(target.recordKey != recording.recordKey)
        }
        let literal = try reference("nodus://prosop/person/id%252Fpart")
        #expect(literal.id == "id%2Fpart")
        #expect(try literal.path(vaultId: "vault/one").contains("vault%2Fone"))
        #expect(try literal.path(vaultId: "vault").hasSuffix("id%252Fpart"))
        #expect(PrivateCorpusReference(URL(string: "nodus://prosop/source/x/extra")!) == nil)
        #expect(PrivateCorpusReference(URL(string: "nodus://user@study/recording/x")!) == nil)
        #expect(PrivateCorpusReference(URL(string: "nodus://study/recording/..")!) == nil)
        #expect(PrivateCorpusReference(URL(string: "nodus://prosop/public/private-id")!) == nil)
        let participant = try reference("nodus://testimonios/participant/private-id")
        #expect(participant.kind == .participant); #expect(participant.kind.domain == .testimonies)
        #expect(participant.kind.primaryKey == "person_id"); #expect(participant.recordKey != literal.recordKey)
        let interview = try reference("nodus://testimonios/interview/interview%2Fone?session=session&transcript=literal&annotation=annotation&t=37.4")
        #expect(interview.kind == .interview); #expect(interview.id == "interview/one")
        #expect(interview.sessionId == "session"); #expect(interview.transcriptId == "literal")
        #expect(interview.annotationId == "annotation"); #expect(interview.timestamp == 37.4)
        #expect(interview.kind.domain == .testimonies); #expect(interview.kind.groups.contains("agreements"))
        #expect(try PrivateCorpusReference(kind: .interview, id: interview.id).recordKey == interview.recordKey)
        #expect(try PrivateCorpusReference.collectionReference(path: "testimony-transcripts", id: "literal")?.kind == .testimonyTranscript)
        #expect(try PrivateCorpusReference.collectionReference(path: "persons", id: "private-person") == nil)
        #expect(throws: (any Error).self) { try PrivateCorpusReference(kind: .interview, id: "interview", timestamp: .infinity) }
        #expect(PrivateCorpusReference(URL(string: "nodus://testimonios/contrast/contrast")!)?.kind == .contrast)
    }

    @Test("partial or foreign dossiers never become complete downloaded sources")
    func completeness() throws {
        let target = try reference(), source = try source(target, segmentCount: 121)
        var rows = Dictionary(uniqueKeysWithValues: target.kind.groups.map { ($0, [Row]()) })
        rows["segments"] = (1...121).map { Row(["_bridge_cursor": .int($0), "text": .string("Texto íntegro \($0)")]) }
        let copy = try CompanionPrivateSourceCopy(source: source, rows: rows, reference: target)
        #expect(copy.rows["segments"]?.last?.text("text") == "Texto íntegro 121")
        rows["segments"]?.removeLast()
        #expect(throws: (any Error).self) { try CompanionPrivateSourceCopy(source: source, rows: rows, reference: target) }
        #expect(throws: (any Error).self) { try copy.validate(for: reference("nodus://study/recording/other")) }
        #expect(throws: (any Error).self) { try copy.validate(for: reference("nodus://prosop/person/recording")) }
    }

    @Test("only explicit selected private downloads survive reopening, within vault and domain")
    func selectedDownloads() async throws {
        let target = try reference(), source = try source(target)
        let copy = try CompanionPrivateSourceCopy(source: source, rows: Dictionary(uniqueKeysWithValues: target.kind.groups.map { ($0, [Row]()) }), reference: target)
        let id = UUID().uuidString, folder = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let keychain = KeychainStore(service: "nodus.tests.private-source.\(id)")
        defer { try? FileManager.default.removeItem(at: folder); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: folder, keychain: keychain, readLimitBytes: 100_000)
        let bytes = try JSONEncoder.nodus.encode(copy)
        let index = try JSONEncoder.nodus.encode(CompanionPrivateSourceCopy.CatalogueEntry(source: source))
        try await cache.store(bytes, vaultId: "vault", domain: .studyRecordings, recordId: target.recordKey)
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: "vault", reference: target) == nil)
        let wrongDomain = try await cache.saveReadPack(vaultId: "vault", title: source.title, expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: target.recordKey, data: bytes)])
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: cache, vaultId: "vault", reference: target) == nil)
        try await cache.removeReadPack(id: wrongDomain.id, vaultId: "vault")
        let pack = try await cache.saveReadPack(vaultId: "vault", title: source.title, expiresAt: .distantFuture,
            records: [.init(domain: .studyRecordings, recordId: target.recordKey, data: bytes),
                .init(domain: .studyRecordings, recordId: CompanionPrivateSourceCopy.catalogueKey, data: index)])
        let reopened = try PrivateBridgeCache(pairingId: id, directory: folder, keychain: keychain, readLimitBytes: 100_000)
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: reopened, vaultId: "vault", reference: target)?.source.id == target.id)
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: reopened, vaultId: "other-vault", reference: target) == nil)
        #expect(try await CompanionPrivateSourceCopy.downloadedCatalogue(cache: reopened, vaultId: "vault", kind: .recording).first?.id == target.id)
        #expect(try await CompanionPrivateSourceCopy.downloadedCatalogue(cache: reopened, vaultId: "vault", kind: .person).isEmpty)
        try await reopened.removeReadPack(id: pack.id, vaultId: "vault")
        #expect(try await CompanionPrivateSourceCopy.downloaded(cache: reopened, vaultId: "vault", reference: target) == nil)
        #expect(try await CompanionPrivateSourceCopy.downloadedCatalogue(cache: reopened, vaultId: "vault", kind: .recording).isEmpty)
    }

    @Test("source catalogues validate complete pages and never accept a partial last page")
    func cataloguePages() throws {
        func page(items: Int, offset: Int = 100, total: Int = 121) throws -> PrivateCorpusSource.Catalogue {
            let json: JSONValue = .object(["items": .array((0..<items).map { index in .object([
                "id": .string("source-\(offset+index)"), "title": .string("Fuente \(offset+index)"),
                "detail": .string("37"), "updatedAt": .string("2026-10-11T00:00:00.000Z"), "state": .string("active")]) }),
                "total": .int(Int64(total)), "offset": .int(Int64(offset)), "limit": .int(100), "hasMore": .bool(false), "revision": .string(String(repeating: "a", count: 64))])
            return try JSONDecoder.nodus.decode(PrivateCorpusSource.Catalogue.self, from: JSONEncoder.nodus.encode(json))
        }
        try page(items: 21).validate(offset: 100)
        #expect(throws: (any Error).self) { try page(items: 20).validate(offset: 100) }
        #expect(throws: (any Error).self) { try page(items: 21).validate(offset: 0) }
    }
}
