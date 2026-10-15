import Foundation

/// Traverses a stable author snapshot without truncating it to the first transport page.
/// A changed snapshot must be reloaded rather than combined with an older catalogue.
public struct AuthorWorkspaceCatalogue: Sendable {
    public private(set) var items: [AuthorWorkspaceItem] = []
    public private(set) var total = 0
    public private(set) var nextOffset = 0
    public private(set) var hasMore = false
    public private(set) var revision: String?

    public enum PagingError: LocalizedError {
        case snapshotChanged, unexpectedOffset, noProgress, invalidPage

        public var errorDescription: String? {
            switch self {
            case .snapshotChanged: "The author catalogue changed. Reload it to continue."
            case .unexpectedOffset: "The author catalogue returned an unexpected page. Please retry."
            case .noProgress: "The author catalogue returned an incomplete page. Please retry."
            case .invalidPage: "The author catalogue returned inconsistent rows. Reload it to continue."
            }
        }
    }

    public init(firstPage: AuthorWorkspacePage) throws {
        try append(firstPage)
    }

    public mutating func append(_ page: AuthorWorkspacePage) throws {
        guard page.offset == nextOffset else { throw PagingError.unexpectedOffset }
        guard nextOffset == 0 || page.revision == revision else { throw PagingError.snapshotChanged }
        guard !page.hasMore || !page.items.isEmpty else { throw PagingError.noProgress }
        guard page.total >= 0, page.limit > 0, page.items.count <= page.limit,
              page.items.count <= max(0, page.total - page.offset),
              page.hasMore == (page.items.count < max(0, page.total - page.offset)) else { throw PagingError.invalidPage }
        guard nextOffset == 0 || page.total == total else { throw PagingError.snapshotChanged }
        var existing = Set(items.map(\.authorId))
        for item in page.items {
            guard !item.authorId.isEmpty, existing.insert(item.authorId).inserted else { throw PagingError.invalidPage }
        }
        items.append(contentsOf: page.items)
        nextOffset = page.offset + page.items.count
        total = page.total
        revision = page.revision
        hasMore = page.hasMore
    }
}
