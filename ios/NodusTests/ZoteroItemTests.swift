import Foundation
import Testing
@testable import Nodus

/// The `zotero://` addresses this app builds.
///
/// This is a contract with two parties the tests cannot reach: Zotero, which decides what the
/// scheme means, and the Nodus desktop, which writes the keys. The desktop's own spelling lives
/// in `shared/pageLocation.ts` of the Nodus repository — including the `groups:<id>:<key>` form
/// it uses for a work from a shared library — and the expectations below are that file's output,
/// copied by hand. A key that opens the right item on a Mac has to open the right item here, and
/// nothing but this suite is watching.
@Suite("Zotero item links")
struct ZoteroItemTests {
    @Test("a personal-library key becomes a select URL")
    func personalLibrary() {
        #expect(ZoteroItem.selectURL(key: "8FMQ4T2J")?.absoluteString == "zotero://select/library/items/8FMQ4T2J")
    }

    @Test("a group-library key keeps its group")
    func groupLibrary() {
        #expect(
            ZoteroItem.selectURL(key: "groups:1234567:8FMQ4T2J")?.absoluteString
                == "zotero://select/groups/1234567/items/8FMQ4T2J"
        )
    }

    // The corpus is somebody's library, not a test fixture, and a key with a space or a slash in
    // it must not silently address a different item — or, worse, fail to be a URL at all and
    // leave the control doing nothing.
    @Test("anything that is not alphanumeric is escaped rather than trusted")
    func awkwardKeysAreEscaped() {
        let url = try! #require(ZoteroItem.selectURL(key: "a b/c"))
        #expect(url.absoluteString == "zotero://select/library/items/a%20b%2Fc")
    }

    @Test("a key that says nothing produces no link")
    func emptyKeys() {
        #expect(ZoteroItem.selectURL(key: "") == nil)
        #expect(ZoteroItem.selectURL(key: "   \n ") == nil)
    }

    @Test("surrounding whitespace is not part of the key")
    func keysAreTrimmed() {
        #expect(ZoteroItem.selectURL(key: "  8FMQ4T2J\n")?.absoluteString == "zotero://select/library/items/8FMQ4T2J")
    }

    // A malformed group key must not be read as one: `groups::KEY` addresses no group, and
    // sending it as one would open nothing while looking exactly like a working link.
    @Test("a half-written group key falls back to the personal library")
    func malformedGroupKeys() {
        #expect(
            ZoteroItem.selectURL(key: "groups::8FMQ4T2J")?.absoluteString
                == "zotero://select/library/items/groups%3A%3A8FMQ4T2J"
        )
        #expect(
            ZoteroItem.selectURL(key: "groups:1234567:")?.absoluteString
                == "zotero://select/library/items/groups%3A1234567%3A"
        )
    }
}
