import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Bounded companion storage")
struct PrivateBridgeCacheTests {
    private func encryptedDiskContents(_ root: URL) throws -> [Data] {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
        var result: [Data] = []
        for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result.append(try Data(contentsOf: file))
        }
        return result
    }
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

    @Test("chosen complete downloads survive LRU pressure and clearing while sharing the per-Mac budget")
    func chosenDownload() async throws {
        let f = try Fixture(limit: 4_096); defer { f.clean() }
        let selected = Data("Private structured document selected for the journey".utf8)
        try await f.cache.store(Data("stale consulted revision".utf8), vaultId: "a", domain: .corpus, recordId: "editor")
        let pack = try await f.cache.saveReadPack(vaultId: "a", title: "One selected document", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "editor", data: selected)])
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "editor") == selected)
        for index in 0..<8 { try await f.cache.store(Data(repeating: 65, count: 1_000), vaultId: "a", domain: .corpus, recordId: "consulted-\(index)") }
        let usage = try await f.cache.usage()
        #expect(usage.reusableBytes + usage.downloadedBytes <= usage.readLimitBytes)
        #expect(usage.downloadedBytes == pack.bytes)
        try await f.cache.store(Data("Unsynced draft".utf8), vaultId: "a", domain: .writing, recordId: "draft")
        try await f.cache.removeReusableCopies()
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "editor") == selected)
        #expect(try await f.cache.usage().reusableBytes == 0)
        #expect(try await f.cache.readPacks(vaultId: "a").count == 1)
        #expect(try await f.cache.readPacks(vaultId: "b").isEmpty)
        #expect(try await f.cache.data(vaultId: "b", domain: .corpus, recordId: "editor") == nil)
        try await f.cache.removeReadPack(id: pack.id, vaultId: "b")
        #expect(try await f.cache.readPacks(vaultId: "a").count == 1)
        try await f.cache.removeReadPack(id: pack.id, vaultId: "a")
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "editor") == nil)
        #expect(try await f.cache.data(vaultId: "a", domain: .writing, recordId: "draft") == Data("Unsynced draft".utf8))
    }

    @Test("failed or duplicate selections never replace the previous complete download")
    func failedDownload() async throws {
        let f = try Fixture(limit: 2_048); defer { f.clean() }
        let id = UUID(), chosen = PrivateBridgeCache.ReadPackRecord(domain: .corpus, recordId: "editor", data: Data("kept".utf8))
        try await f.cache.saveReadPack(id: id, vaultId: "a", title: "Complete", expiresAt: .distantFuture, records: [chosen])
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await f.cache.saveReadPack(id: id, vaultId: "a", title: "Too large", expiresAt: .distantFuture,
                records: [.init(domain: .corpus, recordId: "editor", data: Data(repeating: 0, count: 3_000))])
        }
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await f.cache.saveReadPack(id: id, vaultId: "a", title: "Duplicate", expiresAt: .distantFuture, records: [chosen, chosen])
        }
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await f.cache.saveReadPack(vaultId: "a", title: "Wrong domain", expiresAt: .distantFuture,
                records: [.init(domain: .writing, recordId: "queue", data: Data())])
        }
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "editor") == chosen.data)
        #expect(try await f.cache.readPacks(vaultId: "a").first?.title == "Complete")
        let directories = try FileManager.default.contentsOfDirectory(at: f.folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("pack-copy-") }
        #expect(directories.count == 1, "Failed staging directories must not accumulate")
    }

    @Test("atomic replacement, encryption and reopen keep only the new selected download")
    func replaceDownload() async throws {
        let f = try Fixture(limit: 4_096); defer { f.clean() }
        let id = UUID()
        try await f.cache.saveReadPack(id: id, vaultId: "a", title: "Old", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "old", data: Data("old".utf8))])
        let payload = Data("Selected private content".utf8)
        try await f.cache.saveReadPack(id: id, vaultId: "a", title: "Private download title", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "new", data: payload)])
        let reopened = try PrivateBridgeCache(pairingId: f.id, directory: f.root, keychain: f.keychain, readLimitBytes: 4_096)
        #expect(try await reopened.data(vaultId: "a", domain: .corpus, recordId: "old") == nil)
        #expect(try await reopened.data(vaultId: "a", domain: .corpus, recordId: "new") == payload)
        #expect(try await reopened.readPacks(vaultId: "a").first?.title == "Private download title")
        for bytes in try encryptedDiskContents(f.folder) {
            #expect(bytes.range(of: payload) == nil)
            #expect(bytes.range(of: Data("Private download title".utf8)) == nil)
        }
    }

    @Test("repeating a selection refreshes one pack while vaults and different records remain separate")
    func repeatSelection() async throws {
        let f = try Fixture(limit: 4_096); defer { f.clean() }
        let first = try PrivateBridgeCache.readPackSelectionId(vaultId: "a", recordIds: ["one", "two"])
        let repeated = try PrivateBridgeCache.readPackSelectionId(vaultId: "a", recordIds: ["two", "one", "two"])
        #expect(first == repeated)
        #expect(first != (try PrivateBridgeCache.readPackSelectionId(vaultId: "b", recordIds: ["one", "two"])))
        #expect(first != (try PrivateBridgeCache.readPackSelectionId(vaultId: "a", recordIds: ["other"])))
        #expect(throws: PrivateBridgeCache.ReadPackError.self) { try PrivateBridgeCache.readPackSelectionId(vaultId: "a", recordIds: []) }
        try await f.cache.saveReadPack(id: first, vaultId: "a", title: "Before", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "one", data: Data("before".utf8))])
        try await f.cache.saveReadPack(id: repeated, vaultId: "a", title: "Refreshed", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "one", data: Data("after".utf8))])
        #expect(try await f.cache.readPacks(vaultId: "a").count == 1)
        #expect(try await f.cache.readPacks(vaultId: "a").first?.title == "Refreshed")
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "one") == Data("after".utf8))
    }

    @Test("expiry removes chosen reading copies, never local writing, without relying on sleeps")
    func expiredDownload() async throws {
        let f = try Fixture(limit: 4_096); defer { f.clean() }
        let pack = try await f.cache.saveReadPack(vaultId: "a", title: "Temporary", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "editor", data: Data("temporary".utf8))])
        try await f.cache.store(Data("local work".utf8), vaultId: "a", domain: .writing, recordId: "draft")
        let pointer = f.folder.appendingPathComponent("pin-\(pack.id.uuidString).readpack")
        let encodedKey = try #require(f.keychain.value(for: KeychainStore.desktopBridgeCacheKey(pairingId: f.id)))
        let keyBytes = try #require(Data(base64Encoded: encodedKey))
        let key = SymmetricKey(data: keyBytes)
        let manifest = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: pointer)), using: key)
        var object = try #require(JSONSerialization.jsonObject(with: manifest) as? [String: Any])
        object["expiresAt"] = "2000-01-01T00:00:00.000Z"
        try #require(AES.GCM.seal(JSONSerialization.data(withJSONObject: object), using: key).combined).write(to: pointer)
        #expect(try await f.cache.readPacks(vaultId: "a").isEmpty)
        #expect(try await f.cache.data(vaultId: "a", domain: .corpus, recordId: "editor") == nil)
        #expect(try await f.cache.downloadedData(vaultId: "a", domain: .corpus, recordId: "editor").isEmpty)
        #expect(try await f.cache.usage().downloadedBytes == 0)
        #expect(try await f.cache.data(vaultId: "a", domain: .writing, recordId: "draft") == Data("local work".utf8))
    }

    @Test("independent selections remain enumerable after clearing and reopening, isolated from other vaults and consulted data")
    func combinedDownloads() async throws {
        let f = try Fixture(limit: 8_192); defer { f.clean() }
        let one = Data("selected first catalogue".utf8), two = Data("selected second catalogue".utf8)
        let first = try await f.cache.saveReadPack(vaultId: "a", title: "First", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "catalogue", data: one)])
        let second = try await f.cache.saveReadPack(vaultId: "a", title: "Second", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "catalogue", data: two)])
        try await f.cache.saveReadPack(vaultId: "other", title: "Other vault", expiresAt: .distantFuture,
            records: [.init(domain: .corpus, recordId: "catalogue", data: Data("never included".utf8))])
        try await f.cache.store(Data("consulted only".utf8), vaultId: "a", domain: .corpus, recordId: "catalogue")
        #expect(Set(try await f.cache.downloadedData(vaultId: "a", domain: .corpus, recordId: "catalogue")) == Set([one, two]))
        try await f.cache.removeReusableCopies()
        let reopened = try PrivateBridgeCache(pairingId: f.id, directory: f.root, keychain: f.keychain, readLimitBytes: 8_192)
        #expect(Set(try await reopened.downloadedData(vaultId: "a", domain: .corpus, recordId: "catalogue")) == Set([one, two]))
        #expect(try await reopened.hasDownloadedData(vaultId: "a", domain: .corpus, recordId: "catalogue"))
        #expect(try await !reopened.hasDownloadedData(vaultId: "missing", domain: .corpus, recordId: "catalogue"))
        #expect(try await reopened.downloadedData(vaultId: "a", domain: .testimonies, recordId: "catalogue").isEmpty)
        try await reopened.removeReadPack(id: second.id, vaultId: "a")
        #expect(try await reopened.downloadedData(vaultId: "a", domain: .corpus, recordId: "catalogue") == [one])
        #expect(try await reopened.readPacks(vaultId: "a").first?.id == first.id)
        for content in try encryptedDiskContents(f.root) {
            #expect(content.range(of: one) == nil); #expect(content.range(of: two) == nil)
        }
    }

    @Test("a downloadable private file preserves its descriptor and rejects unverified or incomplete bytes before commit")
    func selectedFileIdentity() async throws {
        let f = try Fixture(limit: 8_192); defer { f.clean() }
        let content = Data("Private selected recording fixture".utf8)
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let file = DesktopBridgeFileDescriptor(kind: .studyRecording, id: "recording-fixture", filename: "recording.wav", mime: "audio/wav", byteSize: content.count, sha256: hash, chunkSize: 128)
        let key = "file:studyRecording:recording-fixture", id = UUID()
        let metadata = PrivateBridgeCache.ReadPackRecord(domain: .studyRecordings, recordId: key, data: try JSONEncoder.nodus.encode(file))
        let bytes = PrivateBridgeCache.ReadPackRecord(domain: .studyRecordings, recordId: "\(key):\(hash)", data: content)
        try await f.cache.saveReadPack(id: id, vaultId: "a", title: "Recording", expiresAt: .distantFuture, records: [metadata, bytes], primaryFile: file)
        let reopened = try PrivateBridgeCache(pairingId: f.id, directory: f.root, keychain: f.keychain, readLimitBytes: 8_192)
        #expect(try await reopened.readPacks(vaultId: "a").first?.primaryFile == file)
        #expect(try await reopened.data(vaultId: "a", domain: .studyRecordings, recordId: "\(key):\(hash)") == content)
        #expect(try await reopened.data(vaultId: "a", domain: .corpus, recordId: "\(key):\(hash)") == nil)
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await reopened.saveReadPack(id: id, vaultId: "a", title: "Incomplete", expiresAt: .distantFuture, records: [metadata], primaryFile: file)
        }
        await #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            try await reopened.saveReadPack(id: id, vaultId: "a", title: "Wrong bytes", expiresAt: .distantFuture,
                records: [metadata, .init(domain: .studyRecordings, recordId: "\(key):\(hash)", data: Data(repeating: 0, count: content.count))], primaryFile: file)
        }
        #expect(try await reopened.readPacks(vaultId: "a").first?.title == "Recording")
        #expect(try await reopened.data(vaultId: "a", domain: .studyRecordings, recordId: "\(key):\(hash)") == content)
    }
}
