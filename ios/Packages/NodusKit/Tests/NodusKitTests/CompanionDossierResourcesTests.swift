import Foundation
import Testing
@testable import NodusKit

@Suite("Companion dossier original identities")
struct CompanionDossierResourcesTests {
    private func catalog(_ kind: String, _ fileId: String) -> JSONValue {
        .object(["version": .int(1), "collection": .string("works"), "id": .string("work-a"),
                 "files": .array([.object(["kind": .string(kind), "id": .string(fileId), "title": .string("Original.pdf"), "available": .bool(true)])])])
    }
    @Test("A retained library catalogue cannot open another work's file")
    func parentIsolation() throws {
        let id = try DesktopLibraryAttachmentIdentity.encode(documentId: "work-a", attachmentId: "attachment")
        #expect(try CompanionDossierResources(value: catalog("libraryAttachment", id), collection: "works", id: "work-a").files.count == 1)
        let foreign = try DesktopLibraryAttachmentIdentity.encode(documentId: "work-b", attachmentId: "attachment")
        #expect(throws: DesktopBridgeError.self) { try CompanionDossierResources(value: catalog("libraryAttachment", foreign), collection: "works", id: "work-a") }
        #expect(throws: DesktopBridgeError.self) { try CompanionDossierResources(value: catalog("libraryOriginal", "work-b"), collection: "works", id: "work-a") }
        #expect(throws: DesktopBridgeError.self) { try CompanionDossierResources(value: catalog("archiveFile", "archive-private"), collection: "works", id: "work-a") }
        #expect(throws: DesktopBridgeError.self) { try CompanionDossierResources(value: catalog("libraryOriginal", "work-a"), collection: "works", id: "work-b") }
    }
    @Test("Map originals use the image identity and never an ancestor's gallery")
    func mapIdentity() throws {
        let detail: JSONValue = .object(["map": .object(["map_id": .string("map-a"), "image_id": .string("image-a")]),
            "ancestry": .array([.object(["map_id": .string("parent-map"), "image_id": .string("parent-image")])])])
        #expect(try CompanionDossierResources.imageSources(collection: "world-maps", id: "map-a", detail: detail) == ["nodus-image://map/image-a"])
    }
    @Test("All own gallery images are retained and malformed identities fail explicitly")
    func ownGallery() throws {
        let detail: JSONValue = .object(["portrait": .object(["person_id": .string("person-a")]),
            "images": .array([.object(["image_id": .string("image-a")]), .object(["image_id": .string("image-b")])]),
            "relatedPersons": .array([.object(["person_id": .string("person-b"), "portrait": .object([:])])])])
        #expect(try CompanionDossierResources.imageSources(collection: "persons", id: "person-a", detail: detail) == ["nodus-image://portrait/person-a", "nodus-image://world/image-a", "nodus-image://world/image-b"])
        #expect(throws: DesktopBridgeError.self) { try CompanionDossierResources.imageSources(collection: "persons", id: "person-a", detail: .object(["images": .array([.object([:])])])) }
    }
}
