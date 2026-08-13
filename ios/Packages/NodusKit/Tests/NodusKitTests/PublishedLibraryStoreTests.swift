import CryptoKit
import Foundation
import Testing
@testable import NodusKit

@Suite("Published library offline storage")
struct PublishedLibraryStoreTests {
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
