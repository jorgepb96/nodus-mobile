import Foundation

/// Complete, revision-consistent catalogues for the non-generic corpus routes.
/// A newer selection supersedes its predecessor, including late errors or pages.
@MainActor public final class SpecialCatalogueReader {
    public struct Response: Sendable {
        public let page: Page<Row>
        public let folders: [Row]
        public init(page: Page<Row>, folders: [Row] = []) { self.page = page; self.folders = folders }
    }
    public typealias Fetch = @Sendable (SpecialResource, Int, Int) async throws -> Response
    private var request = UUID()
    public init() {}
    private func isCurrent(_ token: UUID) -> Bool { request == token }
    public func load(_ resource: SpecialResource, fetch: @escaping Fetch) async throws -> Response? {
        let token = UUID(); request = token
        do {
            let complete = try await PageTraversal.complete(identity: { $0.string("id") }) { offset in
                guard await self.isCurrent(token) else { throw CancellationError() }
                let response = try await fetch(resource, 60, offset)
                guard await self.isCurrent(token) else { throw CancellationError() }
                return response.page
            }
            guard isCurrent(token) else { return nil }
            var folders: [Row] = []
            if resource == .notes {
                let tree = try await fetch(resource, 1, 0)
                guard isCurrent(token) else { return nil }
                try CataloguePageIntegrity.validate(tree.page)
                guard tree.page.revision == complete.revision, tree.page.fromDevice == complete.fromDevice else { throw PageTraversalError.changingRevision }
                guard tree.page.total == complete.total else { throw PageTraversalError.invalidProgress }
                folders = tree.folders
            }
            try Task.checkCancellation()
            return Response(page: complete, folders: folders)
        } catch {
            guard isCurrent(token) else { return nil }
            throw error
        }
    }
}
