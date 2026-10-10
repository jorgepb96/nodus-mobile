import Foundation
import Testing
@testable import NodusKit

@Suite("Bounded private file previews")
struct PrivateBridgeFileLeaseTests {
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
