import Foundation
import Testing
@testable import NodusKit

@MainActor struct SpecialCatalogueReaderTests {
    nonisolated private static func response(limit: Int, offset: Int, revision: String = "current") -> SpecialCatalogueReader.Response {
        let items = (offset..<min(61, offset + limit)).map { Row(["id": .string("\(revision)-\($0)")]) }
        return .init(page: Page(items: items, total: 61, limit: limit, offset: offset,
            hasMore: offset + items.count < 61, revision: revision), folders: [Row(["id": .string("folder")])])
    }

    @Test func everySpecialCatalogueIncludesRowsBeyondFirstSixty() async throws {
        for resource in SpecialResource.allCases {
            let reader = SpecialCatalogueReader()
            let result = try await reader.load(resource) { _, limit, offset in Self.response(limit: limit, offset: offset) }
            let complete = try #require(result)
            #expect(complete.page.items.count == 61)
            #expect(complete.page.items.last?.string("id") == "current-60")
            #expect(!complete.page.hasMore)
            #expect(complete.folders.count == (resource == .notes ? 1 : 0))
        }
    }

    @Test func revisionChangeRestartsInsteadOfJoiningVersions() async throws {
        actor Revision {
            var changed = false
            func value(offset: Int) -> String { if offset > 0 { changed = true }; return changed ? "new" : "old" }
        }
        let revision = Revision()
        let result = try await SpecialCatalogueReader().load(.debates) { _, limit, offset in
            Self.response(limit: limit, offset: offset, revision: await revision.value(offset: offset))
        }
        let complete = try #require(result)
        #expect(complete.page.items.map { $0.string("id") } == (0..<61).map { "new-\($0)" })
    }

    @Test func noteFoldersCannotComeFromAnotherRevision() async {
        await #expect(throws: PageTraversalError.self) {
            try await SpecialCatalogueReader().load(.notes) { _, limit, offset in
                Self.response(limit: limit, offset: offset, revision: limit == 1 ? "other" : "current")
            }
        }
    }

    @Test func switchedSelectionRejectsLateSuccessAndLateError() async throws {
        for fails in [false, true] {
            let gate = Gate()
            let reader = SpecialCatalogueReader()
            let old = Task {
                try await reader.load(.debates) { _, limit, offset in
                    await gate.suspend()
                    if fails { throw URLError(.notConnectedToInternet) }
                    return Self.response(limit: limit, offset: offset, revision: "old")
                }
            }
            await gate.waitUntilSuspended()
            let latest = try await reader.load(.immersion) { _, limit, offset in Self.response(limit: limit, offset: offset) }
            #expect(latest?.page.items.last?.string("id") == "current-60")
            await gate.release()
            let discarded = try await old.value
            #expect(discarded == nil)
        }
    }
}

private actor Gate {
    var blocked: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    func suspend() async { await withCheckedContinuation { blocked = $0; observer?.resume(); observer = nil } }
    func waitUntilSuspended() async {
        if blocked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}
