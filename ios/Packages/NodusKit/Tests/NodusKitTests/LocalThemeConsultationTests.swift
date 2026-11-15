import Foundation
import Testing
@testable import NodusKit

@Suite("Complete thematic consultation without a server")
struct LocalThemeConsultationTests {
    @Test("themes with the same label retain their own full membership beyond 500 links")
    func themeMembership() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-theme-consultation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ideas: [JSONValue] = (0..<1202).map { .object(["global_id": .string("idea-\($0)"), "label": .string("Idea \($0)"), "statement": .string("Exact statement \($0)"), "type": .string("claim")]) }
        let links: [JSONValue] = (0..<1202).map { .object(["global_id": .string("idea-\($0)"), "nodus_id": .string("work"), "theme_id": .string($0 == 1201 ? "another-theme" : "chosen-theme")]) }
        let document = JSONValue.object(["format": .string(SnapshotFormat.identifier), "formatVersion": .int(2), "revision": .string("thematic-revision"), "tables": .object([
            "ideas": .array(ideas), "idea_theme_links": .array(links), "themes": .array([
                .object(["theme_id": .string("chosen-theme"), "label": .string("Same label")]),
                .object(["theme_id": .string("another-theme"), "label": .string("Same label")])])])])
        let archive = try JSONEncoder.nodus.encode(document)
        let mirror = try await MirrorStore.open(spaceId: "theme-lab", directory: directory)
        try await mirror.replace(with: SnapshotDownload.read(archive), revision: "thematic-revision")
        let before = try await mirror.tableCounts()
        let client = NodusClient(local: LocalCorpus(space: .init(id: "theme-lab", name: "Thematic lab"), mirror: mirror, archive: archive),
            address: ServerAddress(trusted: "nodus-demo://this-device"), cache: ResponseCache(directory: directory.appendingPathComponent("cache")))
        let collection = try #require(Collections["themes"])
        let chosen = try await client.dossier(collection, id: "chosen-theme", in: "theme-lab")
        #expect(chosen.sections["ideas"]?.arrayValue?.count == 1201)
        #expect(chosen.sections["ideas"]?.arrayValue?.last?.objectValue?["global_id"] == .string("idea-1200"))
        #expect(chosen.linkedCollection(for: "ideas")?.path == "ideas")
        let other = try await client.dossier(collection, id: "another-theme", in: "theme-lab")
        #expect(other.sections["ideas"]?.arrayValue?.count == 1)
        #expect(other.sections["ideas"]?.arrayValue?.first?.objectValue?["global_id"] == .string("idea-1201"))
        #expect(try await mirror.rows(table: "ideas", where: "type", equals: "claim").count == 1202)
        #expect(try await mirror.rows(table: "ideas", where: "type", equals: "claim", limit: 40).count == 40)
        // The requested set exceeds SQLite's usual variable limit. It remains
        // one ordered query rather than returning duplicate or reordered chunks.
        let ids = (0..<35001).reversed().map { "idea-\($0)" }
        let rows = try await mirror.rows(table: "ideas", ids: ids)
        #expect(rows.count == 1202)
        #expect(rows.first?.string("global_id") == "idea-0")
        #expect(rows.last?.string("global_id") == "idea-1201")
        #expect(try await mirror.tableCounts() == before)
    }
}
