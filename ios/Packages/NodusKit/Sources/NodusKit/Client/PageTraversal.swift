import Foundation

public enum PageTraversalError: Error, LocalizedError, Sendable {
    case invalidProgress
    case changingRevision
    public var errorDescription: String? {
        switch self {
        case .invalidProgress: "The catalogue response is incomplete or malformed. Retry loading the catalogue."
        case .changingRevision: "The catalogue changed while loading. Refresh to read one consistent version."
        }
    }
}

/// A catalogue is one revision. Restart a changing publication rather than joining unrelated pages.
public enum PageTraversal {
    /// Retain provenance and reject partial/mixed catalogues, including a Mac
    /// reconnect halfway through reading a selected on-device catalogue.
    public static func complete<Element: Sendable>(identity: (@Sendable (Element) -> String?)? = nil, load: @Sendable (Int) async throws -> Page<Element>) async throws -> Page<Element> {
        for _ in 0..<3 {
            var items: [Element] = [], first: Page<Element>?
            var ids = Set<String>()
            repeat {
                try Task.checkCancellation()
                let page = try await load(items.count)
                try CataloguePageIntegrity.validate(page)
                if let first, first.revision != page.revision || first.fromDevice != page.fromDevice { break }
                guard page.offset == items.count, page.total >= 0,
                      first == nil || first?.total == page.total,
                      page.offset + page.items.count <= page.total,
                      page.hasMore == (page.offset + page.items.count < page.total),
                      !page.hasMore || !page.items.isEmpty else { throw PageTraversalError.invalidProgress }
                if let identity {
                    for item in page.items {
                        guard let id = identity(item), !id.isEmpty, ids.insert(id).inserted else { throw PageTraversalError.invalidProgress }
                    }
                }
                first = first ?? page
                items.append(contentsOf: page.items)
                if !page.hasMore {
                    return Page(items: items, total: page.total, limit: max(1, items.count), offset: 0, hasMore: false,
                        revision: page.revision, fromDevice: page.fromDevice)
                }
            } while true
        }
        throw PageTraversalError.changingRevision
    }

    public static func all<Element: Sendable>(
        load: @Sendable (Int) async throws -> Page<Element>
    ) async throws -> [Element] {
        try await complete(load: load).items
    }
}

public extension NodusClient {
    func allDeepResearchReports(in spaceId: String) async throws -> [Row] {
        try await deepResearchCatalogue(in: spaceId).items
    }

    func deepResearchCatalogue(in spaceId: String) async throws -> Page<Row> {
        try await PageTraversal.complete(identity: { $0.string("id") }) { offset in
            try await self.deepResearchReports(in: spaceId, limit: PageBounds.maxLimit, offset: offset)
        }
    }

    func dictionaryEntries(in spaceId: String, query: String = "", offset: Int = 0) async throws -> Page<Row> {
        let response = try await perform(.init(
            path: address.spacePath(spaceId, "/dictionary"),
            query: pagingItems(limit: PageBounds.maxLimit, offset: offset) + [URLQueryItem(name: "q", value: query)],
            cacheable: true
        ))
        return try page(from: response, key: "entries")
    }

    func dictionaryEntry(_ id: String, in spaceId: String) async throws -> DictionaryEntryDetail {
        try decode(DictionaryEntryDetail.self, from: await perform(.init(
            path: address.spacePath(spaceId, "/dictionary/\(escape(id))"), cacheable: true
        )))
    }
}

public struct DictionaryEntryDetail: Decodable, Sendable {
    public let entry: Row
    public let evidence: [Row]
    public let relations: [Row]
    public let versions: [Row]
    public let revision: String?
}
