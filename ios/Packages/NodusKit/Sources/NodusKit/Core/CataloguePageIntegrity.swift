import Foundation

/// The same envelope rules apply to the first page and every incremental read.
public enum CataloguePageIntegrity {
    public static func validate<Element: Sendable>(_ page: Page<Element>) throws {
        guard page.total >= 0, page.offset >= 0, page.limit > 0,
              page.items.count <= page.limit, !page.revision.isEmpty,
              page.items.count <= max(0, page.total - page.offset),
              page.hasMore == (page.items.count < max(0, page.total - page.offset)),
              !page.hasMore || !page.items.isEmpty else { throw PageTraversalError.invalidProgress }
    }

    public static func validateRows(_ page: Page<Row>, idField: String, offset: Int,
                                    previous: Page<Row>? = nil) throws {
        try validate(page)
        guard page.offset == offset else { throw PageTraversalError.invalidProgress }
        if let previous {
            guard previous.revision == page.revision, previous.fromDevice == page.fromDevice else { throw PageTraversalError.changingRevision }
            guard previous.total == page.total else { throw PageTraversalError.invalidProgress }
        }
        var ids = Set((previous?.items ?? []).compactMap { $0.string(idField) })
        for row in page.items {
            guard let id = row.string(idField), !id.isEmpty, ids.insert(id).inserted else { throw PageTraversalError.invalidProgress }
        }
    }
}
