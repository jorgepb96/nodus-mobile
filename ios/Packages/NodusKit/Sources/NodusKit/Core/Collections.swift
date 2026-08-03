import Foundation

/// A corpus collection: one URL segment, one snapshot table, one array key in the response.
///
/// This is a transcription of `COLLECTIONS` in `server/lib/routes/corpus.mjs:97-124`, and it
/// exists as data rather than as twenty hand-written request methods for one reason: the key
/// of the array in the response is **not** the path segment. `study-subjects` answers under
/// `subjects`, `deep-research` under `reports`, `immersion` under `sessions`. Reading the
/// wrong key gives an empty list and no error, which is the worst possible failure — it looks
/// exactly like a vault that published nothing.
///
/// `scripts/test-ios-contract.mjs` diffs this table against the server's own so the two
/// cannot drift apart in silence.
public struct CollectionDescriptor: Sendable, Hashable {
    /// The URL segment: `/api/v1/spaces/:id/<path>`.
    public let path: String
    /// The snapshot table it projects.
    public let table: String
    /// The key the array of rows arrives under. Often, but not always, `path`.
    public let listKey: String
    /// The primary-key column, used to build the detail URL.
    public let idField: String
    /// Which vault types normally publish it. Never used to gate a request — the server
    /// deliberately answers an empty page for a table a space did not publish
    /// (`corpus.mjs:89-95`) — only to order the menu sensibly.
    public let families: Set<VaultFamily>

    /// The key a generic detail response arrives under: the path with a trailing `s` dropped
    /// (`corpus.mjs:292`). Note it keeps the hyphen — `/study-docs/x` answers under
    /// `study-doc`.
    ///
    /// The enriched handlers answer under their own name, and for most of them the derived
    /// key happens to match (`ideas` → `idea`). The two that do not are named here, because a
    /// computed key that is wrong is indistinguishable from an empty answer.
    public var detailKey: String {
        switch path {
        case "teaching-exams": return "exam"
        case "study-plans": return "plan"
        default: return path.hasSuffix("s") ? String(path.dropLast()) : path
        }
    }
}

/// The broad shape of a vault, used only to order and group the menu.
public enum VaultFamily: String, Sendable, Hashable, CaseIterable {
    case academic
    case records
    case study
    case teaching
    case databases
}

public enum Collections {
    /// Declared in the server's own order, grouped by the vault family it belongs to.
    public static let all: [CollectionDescriptor] = [
        // Academic
        .init(path: "works", table: "works", listKey: "works", idField: "nodus_id", families: [.academic]),
        .init(path: "ideas", table: "ideas", listKey: "ideas", idField: "global_id", families: [.academic]),
        .init(path: "themes", table: "themes", listKey: "themes", idField: "theme_id", families: [.academic]),
        .init(path: "gaps", table: "gaps", listKey: "gaps", idField: "id", families: [.academic]),
        .init(path: "authors", table: "authors", listKey: "authors", idField: "author_id", families: [.academic]),
        .init(path: "passages", table: "passages", listKey: "passages", idField: "passage_id", families: [.academic]),
        // Genealogy and prosopography
        .init(path: "persons", table: "persons", listKey: "persons", idField: "person_id", families: [.records]),
        .init(path: "places", table: "places", listKey: "places", idField: "place_id", families: [.records]),
        .init(path: "events", table: "events", listKey: "events", idField: "event_id", families: [.records]),
        .init(path: "relationships", table: "relationships", listKey: "relationships", idField: "id", families: [.records]),
        // Study.
        //
        // `id`, every one of them. The study and teaching migrations name their primary key
        // `id` throughout (`electron/db/migrations.ts:1573` onwards) and none of these tables
        // has a `subject_id`, `card_id` or `exam_id` of its own. Declaring one meant
        // `row.string(collection.idField)` was nil for every study and teaching row, and that
        // value is what decides whether a detail can be enriched and whether a row listed
        // inside another dossier is a link or dead text. Both said no.
        .init(path: "study-subjects", table: "study_subjects", listKey: "subjects", idField: "id", families: [.study, .teaching]),
        .init(path: "study-courses", table: "study_courses", listKey: "courses", idField: "id", families: [.study, .teaching]),
        .init(path: "study-topics", table: "study_topics", listKey: "topics", idField: "id", families: [.study, .teaching]),
        .init(path: "study-docs", table: "study_docs", listKey: "docs", idField: "id", families: [.study, .teaching]),
        .init(path: "study-materials", table: "study_materials", listKey: "materials", idField: "id", families: [.study, .teaching]),
        .init(path: "study-flashcards", table: "study_flashcards", listKey: "flashcards", idField: "id", families: [.study, .teaching]),
        .init(path: "study-questions", table: "study_questions", listKey: "questions", idField: "id", families: [.study, .teaching]),
        // The week. `study_plan_blocks` has no collection of its own on purpose: a block
        // outside its plan is a title and a timestamp, so it arrives inside the plan and
        // inside the agenda instead.
        .init(path: "study-plans", table: "study_plans", listKey: "plans", idField: "id", families: [.study, .teaching]),
        .init(path: "study-goals", table: "study_goals", listKey: "goals", idField: "id", families: [.study, .teaching]),
        .init(path: "study-calendar", table: "study_calendar_events", listKey: "events", idField: "id", families: [.study, .teaching]),
        // Teaching. Rosters, groups and grades are never published, so there is deliberately
        // no collection here that could ever serve them.
        .init(path: "teaching-exams", table: "teaching_exams", listKey: "exams", idField: "id", families: [.teaching]),
        .init(path: "teaching-rubrics", table: "teaching_rubrics", listKey: "rubrics", idField: "id", families: [.teaching]),
        // Databases
        .init(path: "databases", table: "db_databases", listKey: "databases", idField: "id", families: [.databases]),
    ]

    public static let byPath: [String: CollectionDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.path, $0) }
    )

    public static let byTable: [String: CollectionDescriptor] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.table, $0) }
    )

    public static subscript(path: String) -> CollectionDescriptor? { byPath[path] }
}

/// The resources that are not a plain table projection: each has its own response shape.
public enum SpecialResource: String, Sendable, CaseIterable {
    /// Derived from edges at read time, never stored. A `supports` edge is not a debate.
    case debates
    /// Carries a `folders` array beside the notes, and the list returns summaries with a
    /// 240-character snippet rather than whole bodies.
    case notes
    /// Answers under `reports`. Only drafts whose brief says `kind: "deep_research"` appear.
    case deepResearch = "deep-research"
    /// Answers under `sessions`. `progress_json` is deliberately never served.
    case immersion

    public var listKey: String {
        switch self {
        case .debates: return "debates"
        case .notes: return "notes"
        case .deepResearch: return "reports"
        case .immersion: return "sessions"
        }
    }

    public var detailKey: String {
        switch self {
        case .debates: return "debate"
        case .notes: return "note"
        case .deepResearch: return "report"
        case .immersion: return "session"
        }
    }
}
