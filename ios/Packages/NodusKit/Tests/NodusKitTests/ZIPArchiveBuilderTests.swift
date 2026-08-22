import Foundation
import Testing
import ZIPFoundation
@testable import NodusKit

@Suite("ZIP archive builder")
struct ZIPArchiveBuilderTests {
    @Test("multiple reports are exported with deterministic safe filenames")
    func buildsArchive() throws {
        let output = URL.temporaryDirectory.appendingPathComponent("reports-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: output) }
        try ZIPArchiveBuilder.build(entries: [
            .init(filename: "Second/report.pdf", data: Data("pdf".utf8)),
            .init(filename: "First report.md", data: Data("markdown".utf8)),
        ], at: output)

        let archive = try Archive(url: output, accessMode: .read, pathEncoding: nil)
        #expect(Set(archive.map(\.path)) == ["report.pdf", "First report.md"])
    }

    @Test("an empty selection is refused instead of sharing an empty file")
    func refusesEmpty() throws {
        let output = URL.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).zip")
        #expect(throws: ZIPArchiveBuilder.Failure.empty) {
            try ZIPArchiveBuilder.build(entries: [], at: output)
        }
    }
}
