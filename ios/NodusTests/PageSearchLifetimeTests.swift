import XCTest
import NodusKit
@testable import Nodus

private nonisolated enum SearchLifetimeScope {
    @TaskLocal static var marker = 0
}

nonisolated final class PageSearchLifetimeTests: XCTestCase {
    @MainActor
    func testSynchronousTaskLocalReleaseOfReaderSessionAndCorpusNames() {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = AppModel.Connection(origin: "https://reader-lifetime.test", spaceId: UUID().uuidString,
            spaceName: "Fixture", serverName: "Mac", role: .owner)
        let client = NodusClient(address: ServerAddress(trusted: connection.origin), token: "fixture",
            cache: ResponseCache(directory: root))
        for index in 0..<50 {
            SearchLifetimeScope.$marker.withValue(index) {
                weak var releasedSession: SpaceSession?
                weak var releasedNames: CorpusNames?
                autoreleasepool {
                    let session = SpaceSession(connection: connection, client: client, mirrorDirectory: root)
                    releasedSession = session
                    releasedNames = session.names
                    XCTAssertNil(session.names.idea("not-loaded"))
                }
                XCTAssertNil(releasedSession, "A released reader must not retain its session.")
                XCTAssertNil(releasedNames, "Releasing the reader must also release its name cache.")
            }
        }
    }

    /// SwiftUI can release a replaced @State model synchronously while a
    /// task-local scope is installed, outside a Swift concurrency task.
    @MainActor
    func testSynchronousTaskLocalReleaseDoesNotCrashOrRetainTheSearch() {
        for index in 0..<50 {
            SearchLifetimeScope.$marker.withValue(index) {
                weak var released: PageSearch?
                weak var releasedInvite: PageChatInvite?
                autoreleasepool {
                    let search = PageSearch()
                    released = search
                    search.register([0], text: "Evidence in the actual reader")
                    search.open()
                    search.query = "evidence"
                    XCTAssertEqual(search.matches.count, 1)
                    search.reveal([0])
                    let invite = PageChatInvite()
                    releasedInvite = invite
                    invite.reportId = "lifetime-fixture"
                    invite.isOpen = true
                }
                XCTAssertNil(released, "A cancelled fade must not retain a removed page.")
                XCTAssertNil(releasedInvite, "The removed page must release its chat invitation.")
            }
        }
    }
}
