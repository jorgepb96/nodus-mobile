import Foundation
import Testing
@testable import NodusKit

@Suite("Author catalogue pagination")
struct AuthorWorkspaceCatalogueTests {
    private var tables: [String: [Row]] {
        [
            "authors": (0..<237).map { index in
                Row(["author_id": .string("author-\(index)"), "name": .string("Surname\(String(format: "%03d", index)), Name")])
            },
            "works": (0..<237).map { index in
                Row(["nodus_id": .string("work-\(index)"), "title": .string("Work \(index)"), "archived": .int(0)])
            },
            "work_authors": (0..<237).map { index in
                Row(["nodus_id": .string("work-\(index)"), "author_id": .string("author-\(index)"), "role": .string("author")])
            },
        ]
    }

    private func page(offset: Int = 0, revision: String = "v1") -> AuthorWorkspacePage {
        AcademicWorkspaceProjection.authorPage(in: tables, limit: 100, offset: offset, revision: revision)
    }

    @Test("All 237 authors remain reachable across three transport pages")
    func completeCatalogue() throws {
        var catalogue = try AuthorWorkspaceCatalogue(firstPage: page())
        #expect(catalogue.items.count == 100)
        while catalogue.hasMore { try catalogue.append(page(offset: catalogue.nextOffset)) }
        #expect(catalogue.items.count == 237)
        #expect(Set(catalogue.items.map(\.authorId)).count == 237)
        #expect(catalogue.nextOffset == 237)
        #expect(catalogue.total == 237)
        #expect(catalogue.items.last?.authorId == "author-236")
    }

    @Test("Overlapping transport pages cannot silently drop an author")
    func transportCursor() throws {
        let first = page()
        var catalogue = try AuthorWorkspaceCatalogue(firstPage: first)
        let second = page(offset: 100)
        let duplicate = try #require(first.items.first)
        let overlapping = AuthorWorkspacePage(
            items: [duplicate] + second.items.dropFirst(), total: 237,
            offset: 100, limit: 100, hasMore: true, revision: "v1"
        )
        #expect(throws: AuthorWorkspaceCatalogue.PagingError.self) { try catalogue.append(overlapping) }
        #expect(catalogue.items.count == 100)
        #expect(catalogue.nextOffset == 100)
        try catalogue.append(second)
        try catalogue.append(page(offset: catalogue.nextOffset))
        #expect(catalogue.items.count == 237)
        #expect(!catalogue.hasMore)
    }

    @Test("Changed snapshots and malformed pages leave the displayed catalogue intact")
    func rejectInvalidContinuation() throws {
        var catalogue = try AuthorWorkspaceCatalogue(firstPage: page())
        #expect(throws: AuthorWorkspaceCatalogue.PagingError.self) {
            try catalogue.append(page(offset: 100, revision: "v2"))
        }
        #expect(throws: AuthorWorkspaceCatalogue.PagingError.self) {
            try catalogue.append(page(offset: 200))
        }
        #expect(throws: AuthorWorkspaceCatalogue.PagingError.self) {
            try catalogue.append(AuthorWorkspacePage(items: [], total: 237, offset: 100, limit: 100, hasMore: true, revision: "v1"))
        }
        #expect(catalogue.items.count == 100)
        #expect(catalogue.nextOffset == 100)
        #expect(catalogue.revision == "v1")
        try catalogue.append(page(offset: 100))
        #expect(catalogue.items.count == 200)
    }
}
