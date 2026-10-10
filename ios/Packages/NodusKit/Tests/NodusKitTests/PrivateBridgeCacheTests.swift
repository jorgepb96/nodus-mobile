import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Bounded companion storage")
struct PrivateBridgeCacheTests {
    private struct Fixture {
        let id = UUID().uuidString
        let root: URL
        let keychain: KeychainStore
        let cache: PrivateBridgeCache
        init(limit: Int) throws {
            root = .temporaryDirectory.appendingPathComponent("companion-cache-\(id)")
            keychain = KeychainStore(service: "nodus.tests.cache.\(id)")
            cache = try PrivateBridgeCache(pairingId: id, directory: root, keychain: keychain, readLimitBytes: limit)
        }
        func clean() { try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: id)); try? FileManager.default.removeItem(at: root) }
        var folder: URL { root.appendingPathComponent("bridge-\(id)") }
    }

    @Test("least recently read content is evicted; drafts and accepted jobs survive pressure and clearing")
    func boundedLRU() async throws {
        let f = try Fixture(limit: 300); defer { f.clean() }
        let payload = Data(repeating: 65, count: 100) // AES-GCM retains 128 bytes.
        try await f.cache.store(payload, vaultId: "a", domain: .corpus, recordId: "old")
        try await f.cache.store(payload, vaultId: "a", domain: .corpus, recordId: "recent")
        // Deterministic file timestamps, without sleeping or assuming disk resolution.
        let files = try FileManager.default.contentsOfDirectory(at: f.folder, includingPropertiesForKeys: nil)
        for file in files { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: file.path) }
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "old") == payload)
        try await f.cache.store(payload, vaultId: "a", domain: .corpus, recordId: "third")
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "recent") == nil)
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "old") == payload)
        let draft = Data("Unsynchronised private BlockNote document".utf8)
        let job = Data(repeating: 90, count: 1_000)
        try await f.cache.store(draft, vaultId: "a", domain: .writing, recordId: "draft")
        try await f.cache.store(job, vaultId: "a", domain: .researchGeneration, recordId: "ledger")
        #expect(try await f.cache.usage().reusableBytes <= 300)
        #expect(try await f.cache.usage().protectedBytes > 1_000)
        try await f.cache.removeReusableCopies()
        #expect(try await f.cache.usage().reusableBytes == 0)
        #expect(try await f.cache.data(vaultId: "a", domain: .writing, recordId: "draft") == draft)
        #expect(try await f.cache.data(vaultId: "a", domain: .researchGeneration, recordId: "ledger") == job)
        #expect(try await f.cache.data(vaultId: "b", domain: .writing, recordId: "draft") == nil)
        for file in try FileManager.default.contentsOfDirectory(at: f.folder, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: draft) == nil)
        }
    }

    @Test("an oversized read never grows storage or leaves a stale version of that record")
    func oversized() async throws {
        let f = try Fixture(limit: 200); defer { f.clean() }
        #expect(try await f.cache.store(Data("other".utf8), vaultId: "a", domain: .corpus, recordId: "other"))
        #expect(try await f.cache.store(Data("old".utf8), vaultId: "a", domain: .corpus, recordId: "large"))
        #expect(try await !f.cache.store(Data(repeating: 1, count: 201), vaultId: "a", domain: .corpus, recordId: "large"))
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "large") == nil)
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "other") == Data("other".utf8))
    }

    @Test("legacy files remain protected until their domain is known, then migrate without losing draft content")
    func legacy() async throws {
        let f = try Fixture(limit: 0); defer { f.clean() }
        let draft = Data("draft from an earlier app version".utf8)
        try await f.cache.store(draft, vaultId: "a", domain: .writing, recordId: "draft")
        let modern = try #require(FileManager.default.contentsOfDirectory(at: f.folder, includingPropertiesForKeys: nil).first)
        let old = f.folder.appendingPathComponent(String(modern.lastPathComponent.dropFirst("work-".count)))
        try FileManager.default.moveItem(at: modern, to: old)
        try await f.cache.removeReusableCopies()
        #expect(FileManager.default.fileExists(atPath: old.path))
        #expect(try await f.cache.data(vaultId: "a", domain: .writing, recordId: "draft") == draft)
        #expect(FileManager.default.fileExists(atPath: modern.path))
        #expect(!FileManager.default.fileExists(atPath: old.path))
    }

    @Test("multiple surfaces share one quota and keep the same encryption key")
    func simultaneousSurfaces() async throws {
        let f = try Fixture(limit: 512); defer { f.clean() }
        let another = try PrivateBridgeCache(pairingId: f.id, directory: f.root, keychain: f.keychain, readLimitBytes: 512)
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for index in 0..<20 {
                let cache = index.isMultiple(of: 2) ? f.cache : another
                tasks.addTask { try await cache.store(Data(repeating: UInt8(index), count: 100), vaultId: "a", domain: .corpus, recordId: "\(index)") }
            }
            try await tasks.waitForAll()
        }
        #expect(try await f.cache.usage().reusableBytes <= 512)
        try await f.cache.store(Data("kept".utf8), vaultId: "a", domain: .writing, recordId: "work")
        #expect(try await another.data(vaultId: "a", domain: .writing, recordId: "work") == Data("kept".utf8))
    }
}
