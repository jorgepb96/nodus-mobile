import Foundation
import Testing
@testable import NodusKit

@Suite(.serialized)
struct PublishedLibraryCatalogueTests {
    private final class Source: @unchecked Sendable {
        private let lock = NSLock()
        var changesOnce = false
        var prematureEnd = false
        private var version = 1
        private(set) var offsets: [Int] = []
        func body(_ request: URLRequest) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let offset = Int(components.queryItems?.first(where: { $0.name == "offset" })?.value ?? "0") ?? 0
            if request.url!.path.hasSuffix("/collections") {
                return try JSONSerialization.data(withJSONObject: ["collections": [], "generatedAt": stamp])
            }
            offsets.append(offset)
            if changesOnce && offset == 200 { version = 2; changesOnce = false }
            let items: [[String: Any]] = (offset..<min(offset + 200, 501)).map { index in [
                "id": "source-\(index)", "title": "v\(version) source \(index)", "itemType": "book", "creators": [],
                "tags": [], "collectionIds": [], "updatedAt": stamp, "cleanAvailable": true,
                "wordCount": 100, "figureCount": 0, "originalAvailable": false, "annotations": [],
            ] }
            return try JSONSerialization.data(withJSONObject: ["items": items, "total": 501, "limit": 200, "offset": offset,
                "hasMore": prematureEnd ? false : offset + items.count < 501, "generatedAt": stamp])
        }
        private var stamp: String { version == 1 ? "2026-10-12T12:00:00.000Z" : "2026-10-12T12:01:00.000Z" }
    }

    private func client(source: Source, directory: URL) -> NodusClient {
        LibraryCatalogueProtocol.handler = { try source.body($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryCatalogueProtocol.self]; configuration.urlCache = nil
        return NodusClient(address: ServerAddress(trusted: "https://library.example"), session: URLSession(configuration: configuration),
            cache: ResponseCache(directory: directory))
    }

    @Test func realClientTraversesLargeLibraryAndRestartsChangedPublication() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); LibraryCatalogueProtocol.handler = nil }
        let source = Source(); source.changesOnce = true
        let result = try await client(source: source, directory: directory).publishedLibraryCatalogue(in: "space")
        #expect(result.documents.count == 501)
        #expect(Set(result.documents.map(\.id)).count == 501)
        #expect(result.documents.first?.title == "v2 source 0")
        #expect(result.documents.last?.title == "v2 source 500")
        #expect(!result.fromDevice)
        #expect(source.offsets.filter { $0 == 0 }.count >= 2)
    }

    @Test func prematurelyEndedLibraryResponseIsErrorRatherThanPartialSuccess() async {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); LibraryCatalogueProtocol.handler = nil }
        let source = Source(); source.prematureEnd = true
        await #expect(throws: PageTraversalError.self) {
            try await client(source: source, directory: directory).publishedLibraryCatalogue(in: "space")
        }
    }
}

private final class LibraryCatalogueProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "library.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let data = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
