import Foundation
import Testing
@testable import NodusKit

@Suite("Durable workspace organization metadata") struct CompanionWorkspaceOrganizationTests {
    let tree: JSONValue = .object(["mobileOrganizationComplete": .bool(true), "folders": .array([.object(["id": .string("parent"), "parentId": .null, "name": .string("Manuscritos")]), .object(["id": .string("child"), "parentId": .string("parent"), "name": .string("Capítulo")])]), "notes": .array([.object(["id": .string("note"), "folderId": .string("child"), "tags": .array([.string("externa"), .string("quitar")]), "trashedAt": .null, "content": .string("Cuerpo intacto")]), .object(["id": .string("trash"), "folderId": .string("child"), "tags": .array([]), "trashedAt": .string("original tombstone")])])])
    @Test func tagsAreDeltaAndPreserveBody() throws {
        let op = try CompanionWorkspaceOrganization.operation(type: "tags", id: "note", arguments: .object(["add": .array([.string("nueva")]), "remove": .array([.string("QUITAR")])]), tree: tree)
        let note = CompanionWorkspaceOrganization.project(op, onto: tree, timestamp: "now").objectValue?["notes"]?.arrayValue?.first?.objectValue
        #expect(note?["tags"] == .array([.string("externa"), .string("nueva")]))
        #expect(note?["content"] == .string("Cuerpo intacto"))
        #expect(op.objectValue?["nativeDocument"] == nil)
    }
    @Test func folderCreationAndChildUseRealStableAncestry() throws {
        let id = UUID().uuidString.lowercased()
        let create = try CompanionWorkspaceOrganization.operation(type: "folderCreate", id: id, arguments: .object(["name": .string("Subcapítulo"), "parentId": .string("child")]), tree: tree)
        #expect(create.objectValue?["parentAncestry"]?.arrayValue?.count == 2)
        let projected = CompanionWorkspaceOrganization.project(create, onto: tree, timestamp: "now")
        let move = try CompanionWorkspaceOrganization.operation(type: "move", id: "note", arguments: .object(["folderId": .string(id)]), tree: projected)
        #expect(move.objectValue?["targetAncestry"]?.arrayValue?.first?.objectValue?["id"] == .string(id))
        #expect(move.objectValue?["expectedFolderId"] == .string("child"))
    }
    @Test func restorePreservesOriginalTombstonePrecondition() throws {
        let op = try CompanionWorkspaceOrganization.operation(type: "restore", id: "trash", arguments: .object([:]), tree: tree)
        #expect(op.objectValue?["expectedTrashedAt"] == .string("original tombstone"))
        let projected = CompanionWorkspaceOrganization.project(op, onto: tree, timestamp: "now")
        #expect(projected.objectValue?["notes"]?.arrayValue?.last?.objectValue?["trashedAt"] == .null)
        #expect(throws: APIError.self) { try CompanionWorkspaceOrganization.operation(type: "restore", id: "note", arguments: .object([:]), tree: tree) }
    }
    @Test func folderTrashCapturesExactDescendantsIncludingTrashed() throws {
        let op = try CompanionWorkspaceOrganization.operation(type: "folderTrash", id: "parent", arguments: .object([:]), tree: tree)
        #expect(op.objectValue?["expectedSubtree"]?.objectValue?["notes"]?.arrayValue?.count == 2)
        let next = CompanionWorkspaceOrganization.project(op, onto: tree, timestamp: "now")
        #expect(next.objectValue?["folders"] == .array([]))
        #expect(next.objectValue?["notes"]?.arrayValue?.allSatisfy { $0.objectValue?["folderId"] == .null } == true)
        #expect(next.objectValue?["notes"]?.arrayValue?.first?.objectValue?["content"] == .string("Cuerpo intacto"))
    }
    @Test func missingAndCyclicPlacementsFailExplicitly() throws {
        #expect(throws: APIError.self) { try CompanionWorkspaceOrganization.ancestry("unknown", tree: tree) }
        #expect(throws: APIError.self) { try CompanionWorkspaceOrganization.ancestry("loop", tree: .object(["folders": .array([.object(["id": .string("loop"), "parentId": .string("loop"), "name": .string("Loop")])])])) }
    }
}
