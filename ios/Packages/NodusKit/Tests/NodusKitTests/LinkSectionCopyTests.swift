import Foundation
import Testing
@testable import NodusKit

@Suite("Explicit Nodus Link section downloads")
struct LinkSectionCopyTests {
    @Test("complete catalogues page offline, replacements remove old records, local deletion retires the memory reader")
    func lifecycle() async throws {
        let id = UUID().uuidString, root = URL.temporaryDirectory.appendingPathComponent("link-sections-\(UUID().uuidString)")
        let keychain = KeychainStore(service: "nodus.tests.link-sections.\(id)")
        defer { try? FileManager.default.removeItem(at: root); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain)
        let reader = LinkSectionCopies()
        func envelope(_ count: Int) -> JSONValue {
            .object(["version": .int(1), "section": .string("library"), "revision": .string("r\(count)"), "snapshot": .object([
                "format": .string("nodus.server-snapshot"), "formatVersion": .int(2), "revision": .string("r\(count)"),
                "vault": .object(["id": .string("vault"), "type": .string("academic"), "name": .string("Selected vault")]),
                "tables": .object(["works": .array((0..<count).map { .object(["nodus_id": .string("w\($0)"), "title": .string("Work \($0)")]) })])])])
        }
        let section = LinkDownloadSection.library, packId = try section.packId(vaultId: "vault")
        func save(_ count: Int) async throws {
            _ = try await cache.saveReadPack(id: packId, vaultId: "vault", title: "Library", expiresAt: .distantFuture,
                records: [.init(domain: .corpus, recordId: section.recordId, data: JSONEncoder.nodus.encode(envelope(count)))])
        }
        try await save(241)
        let page = try #require(try await reader.response(cache: cache, vaultId: "vault", path: "works", query: [.init(name: "offset", value: "200"), .init(name: "limit", value: "200")], percentEncoded: false))
        let rows = try JSONDecoder.nodus.decode(JSONValue.self, from: page.data)
        #expect(rows.objectValue?["works"]?.arrayValue?.count == 41)
        #expect(page.headers["x-nodus-device-copy"] == "selected")
        #expect(try await reader.response(cache: cache, vaultId: "other-vault", path: "works", query: [], percentEncoded: false) == nil)
        #expect(try await reader.operation(cache: cache, vaultId: "vault", method: "deleteWork", args: [.string("w0")]) == nil)
        try await save(1)
        let updated = try #require(try await reader.response(cache: cache, vaultId: "vault", path: "works", query: [], percentEncoded: false))
        #expect(try JSONDecoder.nodus.decode(JSONValue.self, from: updated.data).objectValue?["total"] == .int(1))
        try await cache.removeReadPack(id: packId, vaultId: "vault")
        #expect(try await reader.response(cache: cache, vaultId: "vault", path: "works", query: [], percentEncoded: false) == nil)
    }

    @Test("podcast-only download retains catalogue and cover without enabling mutations or inventing graph data")
    func podcast() async throws {
        let id = UUID().uuidString, root = URL.temporaryDirectory.appendingPathComponent("link-podcast-\(UUID().uuidString)")
        let keychain = KeychainStore(service: "nodus.tests.link-podcast.\(id)")
        defer { try? FileManager.default.removeItem(at: root); try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)) }
        let cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain), section = LinkDownloadSection.podcast
        let envelope: JSONValue = .object(["version": .int(1), "section": .string("podcast"), "snapshot": .object([
            "format": .string("nodus.server-snapshot"), "formatVersion": .int(2), "vault": .object(["id": .string("vault"), "type": .string("academic")]), "tables": .object([:])]),
            "episodes": .array([.object(["id": .string("episode"), "title": .string("Real episode")])]),
            "podcastImages": .array([.object(["id": .string("episode"), "dataURL": .string("data:image/png;base64,YQ==")])])])
        _ = try await cache.saveReadPack(id: section.packId(vaultId: "vault"), vaultId: "vault", title: "Podcasts", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: section.recordId, data: JSONEncoder.nodus.encode(envelope))])
        let reader = LinkSectionCopies()
        #expect(try await reader.operation(cache: cache, vaultId: "vault", method: "podcastEpisodes", args: [])?.arrayValue?.count == 1)
        #expect(try await reader.operation(cache: cache, vaultId: "vault", method: "podcastImageData", args: [.string("episode"), .int(0), .string("thumbnail")]) == .string("data:image/png;base64,YQ=="))
        #expect(try await reader.operation(cache: cache, vaultId: "vault", method: "stellarPage", args: []) == nil)
        #expect(try await reader.operation(cache: cache, vaultId: "vault", method: "podcastDelete", args: []) == nil)
    }
}
