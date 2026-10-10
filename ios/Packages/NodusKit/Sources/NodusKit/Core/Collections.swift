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
    /// The enriched handlers answer under their own domain name. These exceptions
    /// are explicit because a
    /// computed key that is wrong is indistinguishable from an empty answer.
    public var detailKey: String {
        switch path {
        case "teaching-exams": return "exam"
        case "teaching-rubrics": return "rubric"
        case "study-plans": return "plan"
        case "study-courses": return "course"
        case "study-materials": return "material"
        case "study-questions": return "question"
        case "study-ideas": return "idea"
        case "study-schedule": return "period"
        case "dictionary": return "entry"
        case "archive-items": return "item"
        case "archive-repositories": return "repository"
        case "archive-units": return "unit"
        case "archive-excerpts": return "excerpt"
        case "source-analyses": return "analysis"
        case "testimony-interviews": return "interview"
        case "testimony-transcripts": return "transcript"
        case "testimony-codes": return "code"
        case "testimony-contrasts": return "contrast"
        case "database-pages": return "page"
        case "prosopography-public-population": return "population"
        case "prosopography-public-variables": return "variable"
        case "prosopography-public-sources": return "source"
        case "prosopography-public-analysis": return "analysis"
        case "prosopography-public-networks": return "network"
        case let value where value.hasPrefix("world-"):
            let key = String(value.dropFirst(6))
            return key.hasSuffix("s") ? String(key.dropLast()) : key
        default: return path.hasSuffix("s") ? String(path.dropLast()) : path
        }
    }
}

/// The broad shape of a vault, used only to order and group the menu.
public enum VaultFamily: String, Sendable, Hashable, CaseIterable {
    case academic
    case records
    case worldbuilding
    case archive
    case testimonies
    case prosopography
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
        .init(path: "dictionary", table: "dictionary_entries", listKey: "entries", idField: "id", families: [.academic]),
        // Genealogy and prosopography
        .init(path: "persons", table: "persons", listKey: "persons", idField: "person_id", families: [.records]),
        .init(path: "places", table: "places", listKey: "places", idField: "place_id", families: [.records]),
        .init(path: "events", table: "events", listKey: "events", idField: "event_id", families: [.records]),
        .init(path: "relationships", table: "relationships", listKey: "relationships", idField: "rel_id", families: [.records]),
        // Worldbuilding's dossiers have complete published read projections.
        .init(path: "world-groups", table: "world_groups", listKey: "groups", idField: "group_id", families: [.worldbuilding]),
        .init(path: "world-scenes", table: "world_scenes", listKey: "scenes", idField: "scene_id", families: [.worldbuilding]),
        .init(path: "world-articles", table: "world_articles", listKey: "articles", idField: "article_id", families: [.worldbuilding]),
        .init(path: "world-maps", table: "world_maps", listKey: "maps", idField: "map_id", families: [.worldbuilding]),
        .init(path: "world-threads", table: "world_threads", listKey: "threads", idField: "thread_id", families: [.worldbuilding]),
        .init(path: "world-rules", table: "world_rules", listKey: "rules", idField: "rule_id", families: [.worldbuilding]),
        .init(path: "world-questions", table: "world_questions", listKey: "questions", idField: "question_id", families: [.worldbuilding]),
        .init(path: "world-secrets", table: "world_secrets", listKey: "secrets", idField: "secret_id", families: [.worldbuilding]),
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
        .init(path: "study-ideas", table: "study_ideas", listKey: "ideas", idField: "id", families: [.study, .teaching]),
        // The week. `study_plan_blocks` has no collection of its own on purpose: a block
        // outside its plan is a title and a timestamp, so it arrives inside the plan and
        // inside the agenda instead.
        .init(path: "study-plans", table: "study_plans", listKey: "plans", idField: "id", families: [.study, .teaching]),
        .init(path: "study-schedule", table: "study_schedule_periods", listKey: "periods", idField: "id", families: [.study, .teaching]),
        .init(path: "study-goals", table: "study_goals", listKey: "goals", idField: "id", families: [.study, .teaching]),
        .init(path: "study-calendar", table: "study_calendar_events", listKey: "events", idField: "id", families: [.study, .teaching]),
        // Teaching. Rosters, groups and grades are never published, so there is deliberately
        // no collection here that could ever serve them.
        .init(path: "teaching-exams", table: "teaching_exams", listKey: "exams", idField: "id", families: [.teaching]),
        .init(path: "teaching-rubrics", table: "teaching_rubrics", listKey: "rubrics", idField: "id", families: [.teaching]),
        // Source texts and public testimony dossiers. Private contacts/media
        // continue to use their separately granted Bridge domains.
        .init(path: "archive-items", table: "archive_items", listKey: "items", idField: "item_id", families: [.archive]),
        .init(path: "archive-repositories", table: "archive_repositories", listKey: "repositories", idField: "repository_id", families: [.archive]),
        .init(path: "archive-units", table: "archive_description_units", listKey: "units", idField: "unit_id", families: [.archive]),
        .init(path: "archive-excerpts", table: "archive_excerpts", listKey: "excerpts", idField: "excerpt_id", families: [.archive]),
        .init(path: "source-analyses", table: "archive_source_analyses", listKey: "analyses", idField: "analysis_id", families: [.archive]),
        .init(path: "testimony-interviews", table: "testimony_interviews", listKey: "interviews", idField: "id", families: [.testimonies]),
        .init(path: "testimony-transcripts", table: "testimony_transcripts", listKey: "transcripts", idField: "id", families: [.testimonies]),
        .init(path: "testimony-codes", table: "testimony_codes", listKey: "codes", idField: "id", families: [.testimonies]),
        .init(path: "testimony-contrasts", table: "testimony_contrasts", listKey: "contrasts", idField: "id", families: [.testimonies]),
        .init(path: "prosopography-public-population", table: "prosopography_public_population", listKey: "population", idField: "id", families: [.prosopography]),
        .init(path: "prosopography-public-variables", table: "prosopography_public_variables", listKey: "variables", idField: "id", families: [.prosopography]),
        .init(path: "prosopography-public-sources", table: "prosopography_public_sources", listKey: "sources", idField: "id", families: [.prosopography]),
        .init(path: "prosopography-public-analysis", table: "prosopography_public_analysis", listKey: "analyses", idField: "id", families: [.prosopography]),
        .init(path: "prosopography-public-networks", table: "prosopography_public_networks", listKey: "networks", idField: "id", families: [.prosopography]),
        // Databases
        .init(path: "databases", table: "db_databases", listKey: "databases", idField: "id", families: [.databases]),
        .init(path: "database-pages", table: "pages", listKey: "pages", idField: "id", families: [.databases]),
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
