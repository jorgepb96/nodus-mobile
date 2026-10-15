import XCTest
@testable import Nodus

private nonisolated enum SearchLifetimeScope {
    @TaskLocal static var marker = 0
}

nonisolated final class PageSearchLifetimeTests: XCTestCase {
    /// SwiftUI can release a replaced @State model synchronously while a
    /// task-local scope is installed, outside a Swift concurrency task.
    @MainActor
    func testSynchronousTaskLocalReleaseDoesNotCrashOrRetainTheSearch() {
        for index in 0..<50 {
            SearchLifetimeScope.$marker.withValue(index) {
                weak var released: PageSearch?
                autoreleasepool {
                    let search = PageSearch()
                    released = search
                    search.register([0], text: "Evidence in the actual reader")
                    search.open()
                    search.query = "evidence"
                    XCTAssertEqual(search.matches.count, 1)
                    search.reveal([0])
                }
                XCTAssertNil(released, "A cancelled fade must not retain a removed page.")
            }
        }
    }
}
