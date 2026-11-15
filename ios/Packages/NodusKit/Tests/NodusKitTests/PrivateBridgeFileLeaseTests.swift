import Foundation
import Testing
@testable import NodusKit

@Suite("Bounded private file previews")
struct PrivateBridgeFileLeaseTests {
    @Test("an asynchronous export reserves its budget before writing and releases unused reservation after completion")
    func asynchronousReservation() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("lease-stream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let task = Task {
            try await PrivateBridgeFileLease.create(filename: "stream.bin", reservedBytes: 15, directory: root, limitBytes: 20) { url in
                startedSignal.yield()
                for await _ in release { break }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.write(contentsOf: Data(repeating: 65, count: 15))
            }
        }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            _ = try PrivateBridgeFileLease.write(Data(repeating: 66, count: 6), filename: "too-much.bin", directory: root, limitBytes: 20)
        }
        releaseSignal.yield(); releaseSignal.finish(); startedSignal.finish()
        let lease = try await task.value
        #expect(try Data(contentsOf: lease.url).count == 15)
        let remaining = try PrivateBridgeFileLease.write(Data(repeating: 66, count: 5), filename: "remaining.bin", directory: root, limitBytes: 20)
        #expect(try Data(contentsOf: remaining.url).count == 5)
    }

    @Test("failed or oversized stream writers clean up their plaintext file and reservation")
    func failedStream() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("lease-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: URLError.self) {
            _ = try PrivateBridgeFileLease.create(filename: "failed.bin", reservedBytes: 10, directory: root, limitBytes: 10) { url in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }; try handle.write(contentsOf: Data(repeating: 65, count: 5))
                throw URLError(.cannotWriteToFile)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).isEmpty)
        #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            _ = try PrivateBridgeFileLease.create(filename: "oversized.bin", reservedBytes: 3, directory: root, limitBytes: 10) { url in
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }; try handle.write(contentsOf: Data(repeating: 65, count: 4))
            }
        }
        let good = try PrivateBridgeFileLease.write(Data(repeating: 65, count: 10), filename: "good.bin", directory: root, limitBytes: 10)
        #expect(try Data(contentsOf: good.url).count == 10)
    }

    @Test("shared reader ownership retains bytes until the last viewer releases its lease")
    func ownership() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("nodus-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: PrivateBridgeFileLease? = try .write(Data("original file".utf8), filename: "original.pdf", directory: root, limitBytes: 20)
        let url = try #require(first?.url)
        var second = first
        first = nil
        #expect(try Data(contentsOf: url) == Data("original file".utf8))
        #expect(second?.url == url)
        second = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test("active previews share a quota; closing one frees space and a rejected preview leaves no partial folder")
    func budget() throws {
        let root = URL.temporaryDirectory.appendingPathComponent("nodus-preview-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var first: PrivateBridgeFileLease? = try .write(Data(repeating: 65, count: 15), filename: "first.pdf", directory: root, limitBytes: 20)
        #expect(first != nil)
        #expect(throws: PrivateBridgeCache.ReadPackError.self) {
            _ = try PrivateBridgeFileLease.write(Data(repeating: 66, count: 6), filename: "second.pdf", directory: root, limitBytes: 20)
        }
        #expect(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count == 1)
        first = nil
        let second = try PrivateBridgeFileLease.write(Data(repeating: 66, count: 20), filename: "second.pdf", directory: root, limitBytes: 20)
        #expect(try Data(contentsOf: second.url).count == 20)
        #expect(throws: DesktopBridgeError.self) {
            _ = try PrivateBridgeFileLease.write(Data(), filename: "../outside", directory: root, limitBytes: 20)
        }
    }
}
