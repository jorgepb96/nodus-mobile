import Foundation
import Testing
@testable import NodusKit

@Suite("Connection storage identity")
struct SpaceStorageIdentityTests {
    @Test("identical published IDs on different servers never share files")
    func independentOrigins() async throws {
        let directory = try testDatabaseDirectory(prefix: "nodus-storage-identity")
        let first = SpaceStorageIdentity(connectionID: "https://one.test|same-id")
        let second = SpaceStorageIdentity(connectionID: "https://two.test|same-id")
        #expect(first.key != second.key)
        try first.prepare(in: directory); try second.prepare(in: directory)
        let a = try MutationOutbox(spaceId: first.key, directory: directory)
        let b = try MutationOutbox(spaceId: second.key, directory: directory)
        let mutation = Mutation(id: "same-mutation", clientId: "phone", kind: .upsert, table: .notes,
                                key: ["note"], row: ["title": .string("Privado A")], schemaVersion: 199)
        try await a.enqueue(mutation, title: "Privado A")
        #expect(try await b.items().isEmpty)
        try await a.authorisePending()
        #expect(try await b.authorisedPending(limit: 100).isEmpty)
        #expect(try await a.authorisedPending(limit: 100).map(\.id) == ["same-mutation"])
    }

    @Test("Mac identity survives address changes while vault and Mac identities stay distinct")
    func macAndVault() {
        let stable = SpaceStorageIdentity(connectionID: "live:mac-one:vault-one")
        #expect(stable.key == SpaceStorageIdentity(connectionID: "live:mac-one:vault-one").key)
        #expect(stable.key != SpaceStorageIdentity(connectionID: "live:mac-two:vault-one").key)
        #expect(stable.key != SpaceStorageIdentity(connectionID: "live:mac-one:vault-two").key)
        let hostile = SpaceStorageIdentity(connectionID: "https://server.test|../../private")
        #expect(hostile.key.count == 67)
        #expect(!hostile.key.contains("/"))
    }

    @Test("unlabelled legacy content is preserved without becoming another connection's queue")
    func unclaimedLegacy() throws {
        let directory = try testDatabaseDirectory(prefix: "nodus-legacy-storage")
        let legacy = directory.appendingPathComponent("shared-name", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let bytes = Data("Un borrador sin propietario".utf8)
        try bytes.write(to: legacy.appendingPathComponent("draft.json"))
        let a = SpaceStorageIdentity(connectionID: "https://one.test|shared-name")
        let b = SpaceStorageIdentity(connectionID: "https://two.test|shared-name")
        #expect(try a.prepare(in: directory, legacySpaceID: "shared-name") == .unclaimedLegacy)
        #expect(try b.prepare(in: directory, legacySpaceID: "shared-name") == .unclaimedLegacy)
        #expect(try Data(contentsOf: legacy.appendingPathComponent("draft.json")) == bytes)
        for identity in [a, b] {
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(identity.key).appendingPathComponent("draft.json").path))
        }
    }

    @Test("a proven legacy owner migrates intact and reopening is idempotent")
    func verifiedMigration() throws {
        let directory = try testDatabaseDirectory(prefix: "nodus-verified-storage")
        let legacy = directory.appendingPathComponent("old", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let identity = SpaceStorageIdentity(connectionID: "https://one.test|old")
        try JSONEncoder().encode(identity).write(to: legacy.appendingPathComponent("connection-owner.json"))
        try Data("saved".utf8).write(to: legacy.appendingPathComponent("draft.json"))
        #expect(try identity.prepare(in: directory, legacySpaceID: "old") == .migrated)
        #expect(try identity.prepare(in: directory, legacySpaceID: "old") == .ready)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try String(contentsOf: directory.appendingPathComponent(identity.key).appendingPathComponent("draft.json"), encoding: .utf8) == "saved")
    }

    @Test("conflicting ownership and symbolic links cannot expose another folder")
    func ownerAndPathSafety() throws {
        let directory = try testDatabaseDirectory(prefix: "nodus-storage-safety")
        let identity = SpaceStorageIdentity(connectionID: "mine"), another = SpaceStorageIdentity(connectionID: "other")
        try identity.prepare(in: directory)
        try JSONEncoder().encode(another).write(to: directory.appendingPathComponent(identity.key).appendingPathComponent("connection-owner.json"))
        #expect(throws: SpaceStorageIdentity.IdentityError.self) { try identity.prepare(in: directory) }
        let linked = SpaceStorageIdentity(connectionID: "linked")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(linked.key), withDestinationURL: directory.appendingPathComponent(identity.key))
        #expect(throws: SpaceStorageIdentity.IdentityError.self) { try linked.prepare(in: directory) }
    }
}
