import Foundation
import NodusKit
import Testing
@testable import Nodus

/// The example vault, asked of the built bundle rather than of the script that made it.
///
/// `make-demo-snapshot.mjs` validates what it writes, and that proves nothing about what is
/// inside the binary: a resource can fail to be copied, a language can be added to the app and
/// not to the corpus, and either mistake ships an app whose demo button opens an empty board.
/// The failure mode is quiet — the app reports an empty publication and looks broken — so it is
/// worth a test that reads the file the app will actually read.
@Suite("Demo space")
struct DemoSpaceTests {
    /// The tables Home reads to draw its sections.
    ///
    /// `works`, `ideas`, `themes`, `authors`, `gaps` and `passages` are collections and become
    /// tiles; `edges` is what `hasDebates` is measured by, and it gates the Debates tile and the
    /// argument map; `notes` gates the Notes tile. A corpus missing any of them still imports
    /// and still opens — on a screen with a hole in it.
    private nonisolated static let sectionsHomeDraws = [
        "works", "ideas", "themes", "authors", "gaps", "passages", "edges", "notes",
    ]

    /// Every language the corpus was built for. The app picks one; the test reads them all,
    /// because a Spanish phone is the only place a missing Spanish corpus shows up.
    private nonisolated static let languages = ["en", "es"]

    private func snapshot(_ language: String) throws -> SnapshotDownload {
        let url = try #require(
            Bundle.main.url(forResource: "demo-space.\(language)", withExtension: "json.gz"),
            "the bundle carries no example corpus for “\(language)”"
        )
        return try SnapshotDownload.read(try Data(contentsOf: url))
    }

    @Test("every language the app speaks has a corpus the app can read", arguments: languages)
    func bundledSnapshotParses(language: String) throws {
        let snapshot = try snapshot(language)
        #expect(SnapshotFormat.supportedVersions.contains(snapshot.formatVersion))
        // Read out of the document rather than off a header, because there is no header: this
        // is the value the mirror is keyed on, and an empty one would make every launch
        // re-import.
        #expect(snapshot.revision?.isEmpty == false)
        #expect(snapshot.vault?.type == .academic)
        #expect(snapshot.vault?.name?.isEmpty == false)
    }

    @Test("the corpus carries the tables Home draws its sections from", arguments: languages)
    func carriesEverySectionHomeDraws(language: String) throws {
        let snapshot = try snapshot(language)
        for table in Self.sectionsHomeDraws {
            #expect(!snapshot.rows(of: table).isEmpty, "the example corpus has no rows in “\(table)”")
        }
    }

    /// The same question asked of the mirror, which is what the app actually reads.
    ///
    /// Parsing the document proves the file is well formed; importing it proves the rows
    /// survive `SortKeys` and land in a table the list screens can page. Those are different
    /// claims, and the second one is the one a reader experiences.
    @Test("importing it leaves a mirror the collection screens can read", arguments: languages)
    func importsIntoAMirror(language: String) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent("nodus-demo-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = try snapshot(language)
        let mirror = try await MirrorStore.open(spaceId: "demo-test", directory: directory)
        let summary = try await mirror.replace(with: snapshot, revision: snapshot.revision ?? "")

        for table in Self.sectionsHomeDraws {
            #expect((summary.counts[table] ?? 0) > 0, "“\(table)” imported empty")
        }

        // The six that are collections have to be reachable the way a tile reaches them: by
        // their declared key, through a page.
        for table in ["works", "ideas", "themes", "authors", "gaps", "passages"] {
            let collection = try #require(Collections.byTable[table])
            let page = try await mirror.page(table: collection.table, limit: 5)
            #expect(page.total > 0)
            let first = try #require(page.items.first)
            #expect(first.string(collection.idField) != nil, "a “\(table)” row has no \(collection.idField)")
        }
    }

    /// A corpus in the reader's language, not merely an interface in it.
    ///
    /// The two documents are built from the same ids and the same bibliography, so what tells
    /// them apart is exactly what was translated — and if a build ever shipped the same file
    /// twice under two names, everything above would still pass.
    @Test("the two corpora really are different documents")
    func languagesDiffer() throws {
        let english = try snapshot("en")
        let spanish = try snapshot("es")
        #expect(english.revision != spanish.revision)

        let label = { (snapshot: SnapshotDownload) in
            snapshot.rows(of: "ideas").first { $0.string("global_id") == "demo-i-harm-principle" }?.text("label")
        }
        #expect(label(english) == "The harm principle")
        #expect(label(spanish) == "El principio del daño")
    }

    /// The demo is a connection like any other and must never be mistaken for one that has a
    /// server: it holds no credential, and a background job that picked it up would wake the
    /// device to talk to nobody.
    @Test("the demo connection is recognisable without a stored flag")
    func demoConnectionIsMarkedByItsOrigin() {
        let demo = DemoSpace.connection()
        #expect(demo.isDemo)
        #expect(demo.role == .reader)

        let real = AppModel.Connection(
            origin: "https://nodus.example.org",
            spaceId: "abc",
            spaceName: "Real",
            serverName: "Server",
            role: .owner
        )
        #expect(!real.isDemo)
    }
}
