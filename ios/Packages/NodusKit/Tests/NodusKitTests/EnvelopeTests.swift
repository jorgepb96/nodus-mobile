import Foundation
import Testing
@testable import NodusKit

// The envelope is where a client quietly breaks: the array key is not the path segment, and
// reading the wrong one returns an empty list with no error at all — indistinguishable from a
// vault that published nothing. These pin the mapping.

@Suite("Collection descriptors")
struct CollectionDescriptorTests {
    @Test("every collection the server declares is present, and no more")
    func coversTheServerTable() {
        #expect(Collections.all.count == 49)
        #expect(Collections.byPath.count == Collections.all.count, "two descriptors share a path")
        #expect(Collections.byTable.count == Collections.all.count, "two descriptors share a table")
    }

    /// Every study and teaching table names its primary key `id`
    /// (`electron/db/migrations.ts:1573` onwards). This table used to say `subject_id`,
    /// `card_id` and `exam_id` — columns none of those tables has. The server's own lookup
    /// falls through to `candidate.id` and hid it; here `idField` is what decides whether a
    /// detail can be enriched and whether a listed row is a link, and both said no.
    @Test("a collection is keyed on a column its table really has")
    func idFieldsMatchTheSchema() {
        for collection in Collections.all where collection.table.hasPrefix("study_") || collection.table.hasPrefix("teaching_") {
            #expect(collection.idField == "id", "\(collection.path) is keyed on \(collection.idField)")
        }
        // The academic and genealogy tables really do have their own named keys.
        #expect(Collections["works"]?.idField == "nodus_id")
        #expect(Collections["ideas"]?.idField == "global_id")
        #expect(Collections["persons"]?.idField == "person_id")
        #expect(Collections["relationships"]?.idField == "rel_id")
        #expect(Collections["archive-items"]?.idField == "item_id")
        #expect(Collections["archive-units"]?.idField == "unit_id")
        #expect(Collections["source-analyses"]?.idField == "analysis_id")
    }

    @Test("the array key differs from the path exactly where the server says it does")
    func listKeysMatchTheServer() {
        // Straightforward: key == path.
        for path in ["works", "ideas", "themes", "gaps", "authors", "passages", "persons", "places", "events", "relationships", "databases"] {
            #expect(Collections[path]?.listKey == path, "\(path) should answer under its own name")
        }
        // The ones that do not, and which a hand-written client gets wrong.
        #expect(Collections["study-subjects"]?.listKey == "subjects")
        #expect(Collections["study-courses"]?.listKey == "courses")
        #expect(Collections["study-topics"]?.listKey == "topics")
        #expect(Collections["study-docs"]?.listKey == "docs")
        #expect(Collections["study-materials"]?.listKey == "materials")
        #expect(Collections["study-flashcards"]?.listKey == "flashcards")
        #expect(Collections["study-questions"]?.listKey == "questions")
        #expect(Collections["teaching-exams"]?.listKey == "exams")
        #expect(Collections["teaching-rubrics"]?.listKey == "rubrics")
        #expect(Collections["study-plans"]?.listKey == "plans")
        #expect(Collections["study-goals"]?.listKey == "goals")
        #expect(Collections["study-calendar"]?.listKey == "events")
    }

    @Test("the generic detail key keeps its hyphen")
    func detailKeysDropOnlyTheTrailingS() {
        #expect(Collections["themes"]?.detailKey == "theme")
        #expect(Collections["gaps"]?.detailKey == "gap")
        #expect(Collections["relationships"]?.detailKey == "relationship")
        // `corpus.mjs:292` is a bare `head.replace(/s$/,'')`, so the hyphen survives.
        #expect(Collections["study-subjects"]?.detailKey == "study-subject")
        #expect(Collections["study-goals"]?.detailKey == "study-goal")
        // Except where an enriched handler answers under its own name.
        #expect(Collections["teaching-exams"]?.detailKey == "exam")
        #expect(Collections["study-plans"]?.detailKey == "plan")
        #expect(Collections["study-courses"]?.detailKey == "course")
        #expect(Collections["study-materials"]?.detailKey == "material")
        #expect(Collections["teaching-rubrics"]?.detailKey == "rubric")
        #expect(Collections["world-scenes"]?.detailKey == "scene")
        #expect(Collections["dictionary"]?.detailKey == "entry")
        #expect(Collections["archive-items"]?.detailKey == "item")
        #expect(Collections["database-pages"]?.detailKey == "page")
        #expect(Collections["prosopography-public-population"]?.detailKey == "population")
    }

    @Test("special resources answer under their own keys")
    func specialResourceKeys() {
        #expect(SpecialResource.deepResearch.rawValue == "deep-research")
        #expect(SpecialResource.deepResearch.listKey == "reports")
        #expect(SpecialResource.immersion.listKey == "sessions")
        #expect(SpecialResource.debates.listKey == "debates")
        #expect(SpecialResource.notes.listKey == "notes")
    }
}

@Suite("Page bounds")
struct PageBoundsTests {
    @Test("a limit the server would rewrite is never sent")
    func clampsLikeTheServer() {
        // The server treats 0, negative and non-numeric as "use the default", and caps 999.
        #expect(PageBounds.clampedLimit(0) == 100)
        #expect(PageBounds.clampedLimit(-5) == 100)
        #expect(PageBounds.clampedLimit(nil) == 100)
        #expect(PageBounds.clampedLimit(999) == 200)
        #expect(PageBounds.clampedLimit(50) == 50)
        // /search is stricter.
        #expect(PageBounds.clampedLimit(999, max: PageBounds.searchMaxLimit, fallback: PageBounds.searchDefaultLimit) == 50)
        #expect(PageBounds.clampedLimit(nil, max: PageBounds.searchMaxLimit, fallback: PageBounds.searchDefaultLimit) == 20)
    }

    @Test("graph depth is held inside the server's 1…3")
    func clampsDepth() {
        #expect(PageBounds.clampedDepth(0) == 1)
        #expect(PageBounds.clampedDepth(nil) == 1)
        #expect(PageBounds.clampedDepth(7) == 3)
        #expect(PageBounds.clampedDepth(2) == 2)
    }

    @Test("a negative offset becomes zero rather than an error")
    func clampsOffset() {
        #expect(PageBounds.clampedOffset(-1) == 0)
        #expect(PageBounds.clampedOffset(nil) == 0)
        #expect(PageBounds.clampedOffset(240) == 240)
    }
}

@Suite("Row accessors")
struct RowTests {
    @Test("SQLite's integer booleans read as booleans")
    func booleansFromIntegers() {
        let row = Row(["archived": .int(0), "pinned": .int(1), "flag": .bool(true)])
        #expect(row.bool("archived") == false)
        #expect(row.bool("pinned") == true)
        #expect(row.bool("flag") == true)
    }

    @Test("an empty string is absent, because the snapshot writes '' and NULL interchangeably")
    func emptyStringIsAbsent() {
        let row = Row(["title": .string("  "), "subtitle": .null, "label": .string("Idea")])
        #expect(row.text("title") == nil)
        #expect(row.text("subtitle") == nil)
        #expect(row.text("label") == "Idea")
        // `string` is the raw form and keeps the whitespace.
        #expect(row.string("title") == "  ")
    }

    @Test("authors_json arrives as text and still decodes")
    func embeddedJSONFromText() throws {
        let row = Row(["authors_json": .string(#"[{"family":"Bloch","given":"Marc"}]"#)])
        let value = try #require(row.embeddedJSON("authors_json"))
        let authors = try #require(value.arrayValue)
        #expect(authors.count == 1)
        #expect(authors[0].objectValue?["family"]?.stringValue == "Bloch")
    }

    @Test("timestamps decode with and without fractional seconds")
    func decodesBothISOShapes() {
        let plain = Row(["created_at": .string("2026-08-02T09:48:03Z")])
        let fractional = Row(["created_at": .string("2026-08-02T09:48:03.479Z")])
        #expect(plain.date("created_at") != nil)
        #expect(fractional.date("created_at") != nil)
    }
}

@Suite("Error decoding")
struct APIErrorTests {
    @Test("the OAuth-shaped error keeps its code and sentence apart")
    func machineShape() {
        let data = #"{"error":"not_published","error_description":"This space has not received a publication yet."}"#.data(using: .utf8)!
        let error = APIError.decode(status: 409, data: data, headers: [:])
        #expect(error.code == "not_published")
        #expect(error.isNotPublished)
        #expect(error.message?.hasPrefix("This space") == true)
    }

    @Test("the bare shape puts a sentence where a code would go, and is not mistaken for one")
    func bareShape() {
        let data = #"{"error":"Ruta no encontrada."}"#.data(using: .utf8)!
        let error = APIError.decode(status: 404, data: data, headers: [:])
        #expect(error.code == nil)
        #expect(error.message == "Ruta no encontrada.")
        #expect(error.isNotFound)
    }

    // `required` and `actual` are in two different vocabularies — a need and a role. A client
    // that decodes both as the same type drops `required` on the floor and can only say "you
    // cannot do that", never what would let the user do it.
    @Test("a 403 names the need it wanted and the role held, in their own vocabularies")
    func forbiddenCarriesNeedAndRole() {
        let data = #"{"error":"forbidden","required":"write","actual":"reader"}"#.data(using: .utf8)!
        let error = APIError.decode(status: 403, data: data, headers: [:])
        #expect(error.isForbidden)
        #expect(error.requiredNeed == .write)
        #expect(error.actualRole == .reader)
        #expect(error.requiredNeed?.lowestSufficientRole == .writer)
        #expect(error.actualRole?.satisfies(.write) == false)
    }

    @Test("draining the ledger needs own, which a writer does not have")
    func ownIsAboveWrite() {
        let data = #"{"error":"forbidden","required":"own","actual":"writer"}"#.data(using: .utf8)!
        let error = APIError.decode(status: 403, data: data, headers: [:])
        #expect(error.requiredNeed == .own)
        #expect(error.actualRole?.satisfies(.write) == true)
        #expect(error.actualRole?.satisfies(.own) == false)
    }

    @Test("a 413 names the ceiling instead of leaving the app to guess")
    func tooLargeCarriesLimit() {
        let data = #"{"error":"too_large","error_description":"At most 8388608 bytes.","limitBytes":8388608}"#.data(using: .utf8)!
        let error = APIError.decode(status: 413, data: data, headers: [:])
        #expect(error.limitBytes == 8_388_608)
    }

    @Test("Retry-After is read from the headers, not invented")
    func rateLimited() {
        let data = #"{"error":"rate_limited"}"#.data(using: .utf8)!
        let error = APIError.decode(status: 429, data: data, headers: ["Retry-After": "42"])
        #expect(error.isRateLimited)
        #expect(error.retryAfter == 42)
    }

    @Test("a body that is not JSON at all still produces a usable error")
    func nonJSONBody() {
        let error = APIError.decode(status: 403, data: Data("Forbidden".utf8), headers: [:])
        #expect(error.status == 403)
        #expect(error.message == "Forbidden")
    }
}

@Suite("Roles")
struct SpaceRoleTests {
    @Test("the role ladder matches what each route demands")
    func ordering() {
        #expect(SpaceRole.reader < .writer)
        #expect(SpaceRole.writer < .owner)
        #expect(!SpaceRole.reader.canSendChanges)
        #expect(SpaceRole.writer.canSendChanges)
        // Draining the ledger is the owner's side of the relay: a writer must not be able to
        // empty the queue that feeds it.
        #expect(!SpaceRole.writer.canDrainLedger)
        #expect(SpaceRole.owner.canDrainLedger)
    }
}

@Suite("Vault types")
struct VaultTypeTests {
    @Test("the accent palette matches shared/vaultTypes.ts")
    func accents() {
        #expect(VaultType.academic.accentHex == "#6366f1")
        #expect(VaultType.genealogy.accentHex == "#ca8a04")
        #expect(VaultType.databases.accentHex == "#b30333")
        #expect(VaultType.worldbuilding.accentHex == "#7c3aed")
        #expect(VaultType.docencia.accentHex == "#ea580c")
        #expect(VaultType.estudio.accentHex == "#0f766e")
        #expect(VaultType.testimonios.accentHex == "#0891b2")
        #expect(VaultType.prosopography.accentHex == "#2563eb")
        #expect(VaultType.primarySources.accentHex == "#6366f1")
    }

    @Test("a vault type this build has never heard of does not sink the space")
    func unknownTypeDecodesToNil() throws {
        let data = #"{"name":"Futuro","type":"something-new"}"#.data(using: .utf8)!
        let vault = try JSONDecoder().decode(VaultDescriptor.self, from: data)
        #expect(vault.name == "Futuro")
        #expect(vault.type == nil)
    }
}

/// What a failed connection is allowed to say.
///
/// A Nodus Server usually lives on a private network, so the two ordinary failures — "this
/// device is not on that network" and "nothing is listening" — are the ones a user actually
/// hits, and they need opposite things done about them. Collapsing both into "could not
/// connect" is what left a real user staring at a screen with nothing to act on.
@Suite("Transport errors")
struct TransportErrorTests {
    @Test("a name that resolves to nothing is told apart from a port with nothing behind it")
    func namingTheTwoFailures() {
        #expect(TransportError.from(URLError(.cannotFindHost)) == .hostNotFound)
        #expect(TransportError.from(URLError(.dnsLookupFailed)) == .hostNotFound)
        #expect(TransportError.from(URLError(.cannotConnectToHost)) == .cannotConnect)

        let notFound = TransportError.hostNotFound.errorDescription ?? ""
        let refused = TransportError.cannotConnect.errorDescription ?? ""
        #expect(notFound != refused)
        #expect(notFound.contains("private network"), "the fix is to join the network, and it should say so")
        #expect(refused.contains("stopped") || refused.contains("reachable"))
    }

    @Test("a refused certificate is not reported as a missing server")
    func certificatesAreTheirOwnFailure() {
        for code: URLError.Code in [.secureConnectionFailed, .serverCertificateUntrusted,
                                    .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot] {
            #expect(TransportError.from(URLError(code)) == .certificateRejected)
        }
        #expect(TransportError.certificateRejected.errorDescription?.contains("certificate") == true)
    }

    @Test("ATS blocking cleartext says what to type instead")
    func cleartextIsExplained() {
        #expect(TransportError.from(URLError(.appTransportSecurityRequiresSecureConnection)) == .insecureBlocked)
        #expect(TransportError.insecureBlocked.errorDescription?.contains("https://") == true)
    }

    @Test("the ordinary three keep their meaning")
    func theUsualSuspects() {
        #expect(TransportError.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(TransportError.from(URLError(.cancelled)) == .cancelled)
        #expect(TransportError.from(URLError(.timedOut)) == .timedOut)
        // A code with no case of its own keeps the system's own words rather than being
        // flattened into a wrong one.
        #expect(TransportError.from(URLError(.badServerResponse)) != .hostNotFound)
    }

    @Test("every case says something, because a blank error is worse than a wrong one")
    func nothingIsSilent() {
        let cases: [TransportError] = [
            .offline, .cancelled, .timedOut, .hostNotFound, .cannotConnect,
            .certificateRejected, .insecureBlocked, .badServerURL("x"),
            .malformedResponse(expected: "y"), .underlying("z"),
        ]
        for value in cases {
            let text = value.errorDescription ?? ""
            #expect(!text.isEmpty, "\(value) has no description")
        }
    }
}
