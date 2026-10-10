import Testing
@testable import NodusKit

struct PageTraversalTests {
    @Test func traversesEveryPageBeyondTheOldHundredReportLimit() async throws {
        let result = try await PageTraversal.all { offset in
            let items = Array(offset..<min(offset + 37, 253))
            return Page(items: items, total: 253, limit: 37, offset: offset, hasMore: offset + items.count < 253, revision: "a")
        }
        #expect(result == Array(0..<253))
    }

    @Test func rejectsAnEmptyPageClaimingMoreData() async {
        await #expect(throws: PageTraversalError.self) {
            try await PageTraversal.all { offset in
                Page<Int>(items: [], total: 10, limit: 2, offset: offset, hasMore: true, revision: "a")
            }
        }
    }

    @Test func refusesToCombineChangingPublications() async {
        await #expect(throws: PageTraversalError.self) {
            try await PageTraversal.all { offset in
                Page(items: [offset], total: 2, limit: 1, offset: offset, hasMore: offset == 0, revision: offset == 0 ? "a" : "b")
            }
        }
    }
}
