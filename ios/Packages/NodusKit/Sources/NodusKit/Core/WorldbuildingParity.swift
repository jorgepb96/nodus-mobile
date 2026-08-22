import Foundation

/// Portable read models for the worldbuilding workbench.
///
/// Desktop owns SQLite and its canonical repositories; mobile owns an immutable published
/// mirror plus an outbox. These projections deliberately depend only on open `Row` values so
/// the same fixture can be evaluated in TypeScript and Swift without copying repository SQL.
public enum WorldbuildingParity {
    public struct TimelineEntry: Identifiable, Sendable, Hashable {
        public let id: String
        public let kind: String
        public let title: String
        public let worldYear: Int?
        public let worldDay: Int?
        public let narrativeOrder: Int
        public let status: String?

        public init(id: String, kind: String, title: String, worldYear: Int?, worldDay: Int?, narrativeOrder: Int, status: String?) {
            self.id = id
            self.kind = kind
            self.title = title
            self.worldYear = worldYear
            self.worldDay = worldDay
            self.narrativeOrder = narrativeOrder
            self.status = status
        }
    }

    public struct ManuscriptScene: Identifiable, Sendable, Hashable {
        public let id: String
        public let title: String
        public let summary: String?
        public let text: String
        public let wordCount: Int
        public let narrativeOrder: Int
        public let status: String
        public let chapterTitle: String?
        public let bookTitle: String?

        public init(
            id: String,
            title: String,
            summary: String?,
            text: String,
            wordCount: Int,
            narrativeOrder: Int,
            status: String,
            chapterTitle: String?,
            bookTitle: String?
        ) {
            self.id = id
            self.title = title
            self.summary = summary
            self.text = text
            self.wordCount = wordCount
            self.narrativeOrder = narrativeOrder
            self.status = status
            self.chapterTitle = chapterTitle
            self.bookTitle = bookTitle
        }
    }

    public struct ContinuityFinding: Identifiable, Sendable, Hashable {
        public enum Severity: String, Sendable, Hashable, Codable { case info, warning, error }

        public let id: String
        public let checkId: String
        public let severity: Severity
        public let headline: String
        public let detail: String
        public let subjectKind: String
        public let subjectIds: [String]

        public init(
            id: String,
            checkId: String,
            severity: Severity,
            headline: String,
            detail: String,
            subjectKind: String,
            subjectIds: [String]
        ) {
            self.id = id
            self.checkId = checkId
            self.severity = severity
            self.headline = headline
            self.detail = detail
            self.subjectKind = subjectKind
            self.subjectIds = subjectIds
        }
    }

    public struct HierarchyNode: Identifiable, Sendable, Hashable {
        public let id: String
        public let parentId: String?
        public let title: String
        public let kind: String

        public init(id: String, parentId: String?, title: String, kind: String) {
            self.id = id
            self.parentId = parentId
            self.title = title
            self.kind = kind
        }
    }

    /// Chronology and narrative order remain distinct; flashbacks therefore sort correctly in
    /// either lens instead of one view silently rewriting the other.
    public static func timeline(scenes: [Row], events: [Row], chronological: Bool = true) -> [TimelineEntry] {
        let sceneEntries = scenes.compactMap { row -> TimelineEntry? in
            guard let id = row.string("scene_id") else { return nil }
            return TimelineEntry(
                id: "scene:\(id)",
                kind: "scene",
                title: row.text("title") ?? "Untitled scene",
                worldYear: row.int("world_year"),
                worldDay: row.int("world_day"),
                narrativeOrder: row.int("narrative_order") ?? 0,
                status: row.text("status")
            )
        }
        let eventEntries = events.compactMap { row -> TimelineEntry? in
            guard let id = row.string("event_id") else { return nil }
            return TimelineEntry(
                id: "event:\(id)",
                kind: "event",
                title: row.text("label") ?? row.text("type") ?? "Untitled event",
                worldYear: row.int("world_year"),
                worldDay: row.int("world_day"),
                narrativeOrder: row.int("world_order") ?? Int.max,
                status: row.text("type")
            )
        }
        return (sceneEntries + eventEntries).sorted { lhs, rhs in
            if chronological {
                let left = (lhs.worldDay ?? Int.max, lhs.worldYear ?? Int.max, lhs.narrativeOrder)
                let right = (rhs.worldDay ?? Int.max, rhs.worldYear ?? Int.max, rhs.narrativeOrder)
                return left < right
            }
            return lhs.narrativeOrder == rhs.narrativeOrder
                ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                : lhs.narrativeOrder < rhs.narrativeOrder
        }
    }

    public static func manuscript(
        scenes: [Row],
        texts: [Row],
        chapters: [Row],
        books: [Row]
    ) -> [ManuscriptScene] {
        let textByScene = Dictionary(uniqueKeysWithValues: texts.compactMap { row in
            row.string("scene_id").map { ($0, row) }
        })
        let chapterByScene = Dictionary(uniqueKeysWithValues: chapters.compactMap { row in
            row.string("scene_id").map { ($0, row) }
        })
        let bookByScene = Dictionary(uniqueKeysWithValues: books.compactMap { row in
            row.string("scene_id").map { ($0, row) }
        })
        return scenes.compactMap { row -> ManuscriptScene? in
            guard let id = row.string("scene_id") else { return nil }
            let textRow = textByScene[id]
            let text = textRow?.string("text") ?? ""
            return ManuscriptScene(
                id: id,
                title: row.text("title") ?? "Untitled scene",
                summary: row.text("summary"),
                text: text,
                wordCount: textRow?.int("word_count") ?? wordCount(text),
                narrativeOrder: row.int("narrative_order") ?? 0,
                status: row.text("status") ?? "outline",
                chapterTitle: chapterByScene[id]?.text("title"),
                bookTitle: bookByScene[id]?.text("title")
            )
        }.sorted { lhs, rhs in
            lhs.narrativeOrder == rhs.narrativeOrder ? lhs.id < rhs.id : lhs.narrativeOrder < rhs.narrativeOrder
        }
    }

    public static func hierarchy(groups: [Row], places: [Row]) -> [HierarchyNode] {
        let groupNodes = groups.compactMap { row -> HierarchyNode? in
            guard let id = row.string("group_id") else { return nil }
            return HierarchyNode(
                id: "group:\(id)",
                parentId: row.string("parent_id").map { "group:\($0)" },
                title: row.text("name") ?? "Untitled group",
                kind: row.text("kind") ?? "group"
            )
        }
        let placeNodes = places.compactMap { row -> HierarchyNode? in
            guard let id = row.string("place_id") else { return nil }
            return HierarchyNode(
                id: "place:\(id)",
                parentId: row.string("parent_id").map { "place:\($0)" },
                title: row.text("name") ?? "Untitled place",
                kind: row.text("kind") ?? "place"
            )
        }
        return (groupNodes + placeNodes).sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Fast deterministic checks shown immediately. Desktop can run its larger canonical suite
    /// through `worldbuilding.continuity`; these checks never pretend to replace that engine.
    public static func continuity(
        scenes: [Row],
        threads: [Row],
        beats: [Row],
        rules: [Row],
        questions: [Row],
        mutedFingerprints: Set<String> = []
    ) -> [ContinuityFinding] {
        var findings: [ContinuityFinding] = []
        let ordered = scenes.sorted {
            ($0.int("narrative_order") ?? 0, $0.string("scene_id") ?? "")
                < ($1.int("narrative_order") ?? 0, $1.string("scene_id") ?? "")
        }

        for pair in zip(ordered, ordered.dropFirst()) {
            guard
                let leftId = pair.0.string("scene_id"), let rightId = pair.1.string("scene_id"),
                let leftDay = pair.0.int("world_day"), let rightDay = pair.1.int("world_day"),
                rightDay < leftDay
            else { continue }
            let id = fingerprint(check: "scene-day-reversal", subjects: ["scene:\(leftId)", "scene:\(rightId)"])
            guard !mutedFingerprints.contains(id) else { continue }
            findings.append(ContinuityFinding(
                id: id,
                checkId: "scene-day-reversal",
                severity: .warning,
                headline: "The story moves backwards in world time",
                detail: "\(pair.0.text("title") ?? leftId) is day \(leftDay), followed by \(pair.1.text("title") ?? rightId) on day \(rightDay). This may be an intentional flashback.",
                subjectKind: "scene",
                subjectIds: [leftId, rightId]
            ))
        }

        let beatThreadIds = Set(beats.compactMap { $0.string("thread_id") })
        for row in threads where row.text("status") != "archived" {
            guard let id = row.string("thread_id"), !beatThreadIds.contains(id) else { continue }
            let fingerprint = fingerprint(check: "thread-without-beats", subjects: ["thread:\(id)"])
            guard !mutedFingerprints.contains(fingerprint) else { continue }
            findings.append(ContinuityFinding(
                id: fingerprint,
                checkId: "thread-without-beats",
                severity: .info,
                headline: "A story thread has no scene beats",
                detail: "\(row.text("title") ?? id) is active but is not anchored to any scene.",
                subjectKind: "thread",
                subjectIds: [id]
            ))
        }

        for row in rules where row.text("status") == "canon" && row.text("hardness") == "costly" && row.text("cost") == nil {
            guard let id = row.string("rule_id") else { continue }
            let fingerprint = fingerprint(check: "costly-rule-without-cost", subjects: ["rule:\(id)"])
            guard !mutedFingerprints.contains(fingerprint) else { continue }
            findings.append(ContinuityFinding(
                id: fingerprint,
                checkId: "costly-rule-without-cost",
                severity: .warning,
                headline: "A costly rule has no stated price",
                detail: "\(row.text("title") ?? id) is canon and costly, but its cost is empty.",
                subjectKind: "rule",
                subjectIds: [id]
            ))
        }

        let blocking = questions.filter { $0.text("status") == "open" && ($0.bool("blocking") ?? false) }
        if !blocking.isEmpty {
            let ids = blocking.compactMap { $0.string("question_id") }.sorted()
            let fingerprint = fingerprint(check: "blocking-questions", subjects: ids.map { "question:\($0)" })
            if !mutedFingerprints.contains(fingerprint) {
                findings.append(ContinuityFinding(
                    id: fingerprint,
                    checkId: "blocking-questions",
                    severity: .error,
                    headline: "Open decisions block the manuscript",
                    detail: "\(blocking.count) blocking question(s) still need an answer.",
                    subjectKind: "question",
                    subjectIds: ids
                ))
            }
        }
        return findings.sorted {
            severityRank($0.severity) == severityRank($1.severity)
                ? $0.headline < $1.headline
                : severityRank($0.severity) > severityRank($1.severity)
        }
    }

    public static func fingerprint(check: String, subjects: [String]) -> String {
        "\(check)|\(subjects.sorted().joined(separator: ","))"
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private static func severityRank(_ value: ContinuityFinding.Severity) -> Int {
        switch value { case .info: 0; case .warning: 1; case .error: 2 }
    }
}
