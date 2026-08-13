import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import NodusKit

@Suite("Published library offline storage")
struct PublishedLibraryStoreTests {
    private func package(_ entries: [String: Data], at root: URL) throws -> Data {
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (name, data) in entries {
            let target = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
        }
        let target = root.appendingPathComponent("package.zip")
        let archive = try Archive(url: target, accessMode: .create)
        for name in entries.keys.sorted() { try archive.addEntry(with: name, relativeTo: source) }
        return try Data(contentsOf: target)
    }

    private func document(id: String, package: Data) throws -> PublishedLibraryDocument {
        let hash = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        let value: [String: Any] = [
            "id": id, "title": "Published document", "itemType": "book", "creators": ["Ada Lovelace"],
            "abstract": NSNull(), "date": NSNull(), "year": 1843, "language": "en",
            "publisher": NSNull(), "publicationTitle": NSNull(), "doi": NSNull(), "url": NSNull(),
            "tags": ["history"], "collectionIds": ["collection-1"], "updatedAt": "2026-08-13T12:00:00.000Z",
            "cleanAvailable": true, "wordCount": 8, "figureCount": 1, "packageHash": hash,
            "packageBytes": package.count, "originalAvailable": true, "originalFileName": "source.pdf",
            "originalMimeType": "application/pdf", "annotations": [],
        ]
        return try JSONDecoder.nodus.decode(PublishedLibraryDocument.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @Test("a real Clean Markdown package installs atomically, exposes figures and can be deleted")
    func installsAndDeletesPackage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-published-library-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try package([
            "document.md": Data("# Downloaded\n\nReadable without a network.".utf8),
            "assets/diagram.svg": Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20\" height=\"10\"><rect width=\"20\" height=\"10\"/></svg>".utf8),
            "manifest.json": try JSONSerialization.data(withJSONObject: [
                "format": "nodus.library-document-package", "formatVersion": 1, "documentId": "document-1",
            ]),
        ], at: root)
        let published = try document(id: "document-1", package: bytes)
        let store = PublishedLibraryStore(spaceId: "space-1", root: root)

        let markdown = try await store.install(published, package: bytes)
        #expect(markdown.contains("Readable without a network"))
        #expect(await store.isDownloaded(published.id, packageHash: published.packageHash))
        #expect(await store.figures(published.id).map(\.lastPathComponent) == ["diagram.svg"])
        #expect(await store.packageURL(published.id) != nil)

        await store.remove(Set([published.id]))
        #expect(!(await store.isDownloaded(published.id)))
        #expect(await store.packageURL(published.id) == nil)
    }

    @Test("the phone rejects originals, arbitrary files and packages relabelled as another document")
    func rejectsUnsafeOrMismatchedPackage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-published-library-reject-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafe = try package([
            "document.md": Data("# Clean".utf8),
            "manifest.json": try JSONSerialization.data(withJSONObject: [
                "format": "nodus.library-document-package", "formatVersion": 1, "documentId": "document-unsafe",
            ]),
            "original.pdf": Data("%PDF-1.7".utf8),
        ], at: root.appendingPathComponent("unsafe", isDirectory: true))
        let store = PublishedLibraryStore(spaceId: "space-1", root: root)
        do {
            _ = try await store.install(try document(id: "document-unsafe", package: unsafe), package: unsafe)
            Issue.record("an original file was accepted")
        } catch let error as PublishedLibraryStore.StoreError {
            #expect(error == .unsafeArchive)
        }

        let mismatched = try package([
            "document.md": Data("# Clean".utf8),
            "manifest.json": try JSONSerialization.data(withJSONObject: [
                "format": "nodus.library-document-package", "formatVersion": 1, "documentId": "another-document",
            ]),
        ], at: root.appendingPathComponent("mismatch", isDirectory: true))
        do {
            _ = try await store.install(try document(id: "wanted-document", package: mismatched), package: mismatched)
            Issue.record("a package for another document was accepted")
        } catch let error as PublishedLibraryStore.StoreError {
            #expect(error == .corruptPackage)
        }
    }

    @Test("global cleanup removes downloads but preserves each remote catalog")
    func globalCleanupKeepsCatalog() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodus-published-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = root.appendingPathComponent("spaces/space-1/library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let documentId = "document-1"
        let folderName = SHA256.hash(data: Data(documentId.utf8)).map { String(format: "%02x", $0) }.joined()
        let documentFolder = library.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: documentFolder, withIntermediateDirectories: true)
        try Data("# Downloaded".utf8).write(to: documentFolder.appendingPathComponent("document.md"))
        try Data("catalog remains available offline".utf8).write(to: library.appendingPathComponent("catalog.json"))

        let download = PublishedLibraryStore.Download(
            id: documentId,
            packageHash: String(repeating: "a", count: 64),
            downloadedAt: Date(timeIntervalSince1970: 1),
            bytes: 12
        )
        let index = try JSONEncoder.nodus.encode([documentId: download])
        try index.write(to: library.appendingPathComponent("downloads.json"))

        try PublishedLibraryStore.removeAllSpaces(root: root)

        #expect(!FileManager.default.fileExists(atPath: documentFolder.path))
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("catalog.json").path))
        let emptyIndex = try Data(contentsOf: library.appendingPathComponent("downloads.json"))
        #expect(try JSONDecoder.nodus.decode([String: PublishedLibraryStore.Download].self, from: emptyIndex).isEmpty)
    }
}
