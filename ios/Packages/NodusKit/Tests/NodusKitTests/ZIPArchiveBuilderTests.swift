import Foundation
import Testing
import ZIPFoundation
@testable import NodusKit

@Suite("ZIP archive builder")
struct ZIPArchiveBuilderTests {
    @Test("streaming archives preserve exact bytes with bounded reads and remove incomplete exports")
    func boundedStreaming() throws {
        let output = URL.temporaryDirectory.appendingPathComponent("streaming-\(UUID()).zip")
        defer { try? FileManager.default.removeItem(at: output) }
        let bytes = Data((0..<(196_608 + 17)).map { UInt8($0 % 251) })
        let progress = Progress(totalUnitCount: Int64(bytes.count))
        try ZIPArchiveBuilder.buildStreaming(entries: [.init(filename: "original.bin", byteCount: Int64(bytes.count), read: { offset, count in
            #expect(count <= 64 * 1024)
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        })], at: output, progress: progress)
        let zip = try Archive(url: output, accessMode: .read, pathEncoding: nil)
        let file = try #require(zip["original.bin"])
        var restored = Data()
        _ = try zip.extract(file) { restored.append($0) }
        #expect(restored == bytes)
        #expect(progress.completedUnitCount == Int64(bytes.count))
        #expect(throws: ZIPArchiveBuilder.Failure.self) {
            try ZIPArchiveBuilder.buildStreaming(entries: [.init(filename: "short.bin", byteCount: 17, read: { _, _ in Data() })], at: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let canceled = Progress(totalUnitCount: 17); canceled.cancel()
        #expect(throws: CancellationError.self) {
            try ZIPArchiveBuilder.buildStreaming(entries: [.init(filename: "cancel.bin", byteCount: 17, read: { _, _ in Issue.record("Canceled exports must not read authored bytes"); return Data() })], at: output, progress: canceled)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: ZIPArchiveBuilder.Failure.self) {
            _ = try ZIPArchiveBuilder.streamingReservation(entries: [.init(filename: "folder/same.txt", byteCount: 0, read: { _, _ in Data() }), .init(filename: "same.txt", byteCount: 0, read: { _, _ in Data() })])
        }
    }

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
