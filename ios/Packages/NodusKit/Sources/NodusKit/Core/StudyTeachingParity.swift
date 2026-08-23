import Foundation

/// Portable projections shared by the Study and Teaching surfaces.
///
/// Identity, grades and recordings may arrive only from the explicitly paired Desktop Bridge;
/// this type deliberately knows nothing about transport and therefore cannot accidentally publish
/// a private row. It mirrors the deterministic parts of Desktop's studyStats/assessment/rubric
/// modules so the same material produces the same progress and grade on every Apple device.
public enum StudyTeachingParity {
    public struct Course: Sendable, Hashable, Identifiable {
        public let id: String
        public let shortId: String
        public let name: String
        public let description: String
        public let color: String?
        public let icon: String?
        public let favorite: Bool
        public let position: Int
    }

    public struct Subject: Sendable, Hashable, Identifiable {
        public let id: String
        public let courseId: String
        public let name: String
        public let description: String
        public let color: String?
        public let icon: String?
        public let position: Int
    }

    public struct Topic: Sendable, Hashable, Identifiable {
        public let id: String
        public let subjectId: String
        public let parentId: String?
        public let name: String
        public let position: Int
    }

    public struct PerformanceEvidence: Sendable, Hashable {
        public var correct: Int
        public var incorrect: Int
        public var omitted: Int
        public var studySeconds: Int
        public var reviews: Int
        public var lapses: Int

        public init(correct: Int, incorrect: Int, omitted: Int, studySeconds: Int, reviews: Int, lapses: Int) {
            self.correct = correct
            self.incorrect = incorrect
            self.omitted = omitted
            self.studySeconds = studySeconds
            self.reviews = reviews
            self.lapses = lapses
        }
    }

    public struct PerformanceSummary: Sendable, Hashable {
        public let attempts: Int
        public let accuracy: Double?
        public let mastery: Double
        public let status: String
        public let studySeconds: Int
        public let reviews: Int
        public let lapses: Int
    }

    public struct Student: Sendable, Hashable, Identifiable {
        public let id: String
        public let groupId: String
        public let pseudonymCode: String
        public let givenNames: String
        public let surnames: String
        public let comments: String
        public let position: Int

        public var displayName: String {
            let value = [givenNames, surnames].filter { !$0.isEmpty }.joined(separator: " ")
            return value.isEmpty ? pseudonymCode : value
        }
    }

    public struct AssessmentItem: Sendable, Hashable, Identifiable {
        public let id: String
        public let planId: String
        public let parentId: String?
        public let name: String
        public let kind: String
        public let position: Int
        public let weight: Double
        public let alternateWeight: Double
        public let maxPoints: Double
        public let mandatory: Bool
    }

    public struct GradeEntry: Sendable, Hashable, Identifiable {
        public let id: String
        public let studentId: String
        public let itemId: String
        public let call: String
        public let rawValue: Double?
        public let status: String
        public let note: String
    }

    public struct GradebookRow: Sendable, Hashable, Identifiable {
        public let student: Student
        public let values: [String: Double?]
        public let finalGrade: Double?
        public let passed: Bool?
        public let missingMandatory: Bool
        public var id: String { student.id }
    }

    public struct GradeDistribution: Sendable, Hashable {
        public let evaluated: Int
        public let passed: Int
        public let passRate: Double?
        public let mean: Double?
        public let median: Double?
        public let minimum: Double?
        public let maximum: Double?
    }

    public struct RubricLevel: Sendable, Hashable, Identifiable {
        public let id: String
        public let label: String
        public let score: Double
    }

    public struct RubricCriterion: Sendable, Hashable, Identifiable {
        public let id: String
        public let label: String
        public let weight: Double
        public let descriptors: [String: String]
    }

    public struct Rubric: Sendable, Hashable, Identifiable {
        public let id: String
        public let title: String
        public let description: String
        public let scaleMax: Double
        public let weighted: Bool
        public let levels: [RubricLevel]
        public let criteria: [RubricCriterion]
    }

    public static func courses(in tables: [String: [Row]]) -> [Course] {
        (tables["study_courses"] ?? []).compactMap { row in
            guard let id = row.string("id"), let name = row.text("name"), row.text("deleted_at") == nil else { return nil }
            return Course(
                id: id, shortId: row.text("short_id") ?? id, name: name,
                description: row.text("description") ?? "", color: row.text("color"), icon: row.text("icon"),
                favorite: row.int("favorite") == 1, position: row.int("position") ?? 0
            )
        }.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite && !rhs.favorite }
            if lhs.position != rhs.position { return lhs.position < rhs.position }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    public static func subjects(courseId: String? = nil, in tables: [String: [Row]]) -> [Subject] {
        (tables["study_subjects"] ?? []).compactMap { row in
            guard
                let id = row.string("id"), let owner = row.string("course_id"), let name = row.text("name"),
                courseId == nil || owner == courseId, row.text("deleted_at") == nil
            else { return nil }
            return Subject(
                id: id, courseId: owner, name: name, description: row.text("description") ?? "",
                color: row.text("color"), icon: row.text("icon"), position: row.int("position") ?? 0
            )
        }.sorted { $0.position == $1.position ? $0.name < $1.name : $0.position < $1.position }
    }

    public static func topics(subjectId: String? = nil, in tables: [String: [Row]]) -> [Topic] {
        (tables["study_topics"] ?? []).compactMap { row in
            guard
                let id = row.string("id"), let owner = row.string("subject_id"), let name = row.text("name"),
                subjectId == nil || owner == subjectId, row.text("deleted_at") == nil
            else { return nil }
            return Topic(id: id, subjectId: owner, parentId: row.string("parent_id"), name: name, position: row.int("position") ?? 0)
        }.sorted { $0.position == $1.position ? $0.name < $1.name : $0.position < $1.position }
    }

    /// Same bounded mastery signal as Desktop: accuracy leads, reviews add confidence and lapses
    /// reduce it. An unanswered item is not silently counted as an incorrect answer.
    public static func summarize(_ evidence: PerformanceEvidence) -> PerformanceSummary {
        let attempts = max(0, evidence.correct) + max(0, evidence.incorrect)
        let accuracy = attempts == 0 ? nil : Double(max(0, evidence.correct)) / Double(attempts)
        let reviewConfidence = min(1, log1p(Double(max(0, evidence.reviews))) / log(13))
        let lapsePenalty = min(0.35, Double(max(0, evidence.lapses)) * 0.04)
        let mastery = min(1, max(0, (accuracy ?? 0) * 0.82 + reviewConfidence * 0.18 - lapsePenalty))
        let status: String
        switch mastery {
        case 0 where attempts == 0 && evidence.reviews == 0: status = "unrated"
        case ..<0.35: status = "problematic"
        case ..<0.65: status = "learning"
        case ..<0.85: status = "strong"
        default: status = "mastered"
        }
        return PerformanceSummary(
            attempts: attempts, accuracy: accuracy, mastery: mastery, status: status,
            studySeconds: max(0, evidence.studySeconds), reviews: max(0, evidence.reviews), lapses: max(0, evidence.lapses)
        )
    }

    public static func students(in rows: [Row]) -> [Student] {
        rows.compactMap { row in
            guard let id = row.string("id"), let groupId = row.string("group_id"), let code = row.text("pseudonym_code") else { return nil }
            return Student(
                id: id, groupId: groupId, pseudonymCode: code, givenNames: row.text("given_names") ?? "",
                surnames: row.text("surnames") ?? "", comments: row.text("comments") ?? "", position: row.int("position") ?? 0
            )
        }.sorted { $0.position < $1.position }
    }

    public static func assessmentItems(in rows: [Row], planId: String? = nil) -> [AssessmentItem] {
        rows.compactMap { row in
            guard
                let id = row.string("id"), let owner = row.string("plan_id"),
                planId == nil || owner == planId
            else { return nil }
            return AssessmentItem(
                id: id, planId: owner, parentId: row.string("parent_id"), name: row.text("name") ?? "Assessment",
                kind: row.text("kind") ?? "activity", position: row.int("position") ?? 0,
                weight: max(0, row.double("weight") ?? 1), alternateWeight: max(0, row.double("weight_alt") ?? row.double("weight") ?? 1),
                maxPoints: max(0.0001, row.double("max_points") ?? 10), mandatory: row.int("is_mandatory") == 1
            )
        }.sorted { $0.position < $1.position }
    }

    public static func gradeEntries(in rows: [Row], call: String = "ordinaria") -> [GradeEntry] {
        rows.compactMap { row in
            guard
                let id = row.string("id"), let student = row.string("student_id"), let item = row.string("item_id"),
                (row.text("convocatoria") ?? "ordinaria") == call
            else { return nil }
            return GradeEntry(
                id: id, studentId: student, itemId: item, call: call, rawValue: row.double("raw_value"),
                status: row.text("status") ?? "not_assessed", note: row.text("note") ?? ""
            )
        }
    }

    /// Builds a read-only grade projection. `not_assessed` and `exempt` renormalise weights;
    /// `not_submitted` is zero, matching Desktop's distinction between blank and missing work.
    public static func gradebook(
        students: [Student], items: [AssessmentItem], entries: [GradeEntry],
        alternateTrack: Bool = false, passMark: Double = 5, scale: Double = 10
    ) -> [GradebookRow] {
        let byKey = Dictionary(entries.map { ("\($0.studentId):\($0.itemId)", $0) }, uniquingKeysWith: { _, last in last })
        return students.map { student in
            var values: [String: Double?] = [:]
            var weighted = 0.0
            var totalWeight = 0.0
            var missingMandatory = false
            for item in items where item.kind != "block" {
                let entry = byKey["\(student.id):\(item.id)"]
                let value: Double?
                switch entry?.status ?? "not_assessed" {
                case "not_submitted": value = 0
                case "exempt", "not_assessed": value = nil
                default: value = entry?.rawValue.map { min(item.maxPoints, max(0, $0)) }
                }
                values[item.id] = value
                if item.mandatory && value == nil { missingMandatory = true }
                guard let value else { continue }
                let weight = alternateTrack ? item.alternateWeight : item.weight
                weighted += (value / item.maxPoints) * weight
                totalWeight += weight
            }
            let grade = totalWeight > 0 && !missingMandatory ? min(scale, max(0, weighted / totalWeight * scale)) : nil
            return GradebookRow(student: student, values: values, finalGrade: grade, passed: grade.map { $0 >= passMark }, missingMandatory: missingMandatory)
        }
    }

    public static func distribution(_ rows: [GradebookRow]) -> GradeDistribution {
        let values = rows.compactMap(\.finalGrade).sorted()
        guard !values.isEmpty else { return GradeDistribution(evaluated: 0, passed: 0, passRate: nil, mean: nil, median: nil, minimum: nil, maximum: nil) }
        let passed = rows.filter { $0.passed == true }.count
        let middle = values.count / 2
        let median = values.count.isMultiple(of: 2) ? (values[middle - 1] + values[middle]) / 2 : values[middle]
        return GradeDistribution(
            evaluated: values.count, passed: passed, passRate: Double(passed) / Double(values.count),
            mean: values.reduce(0, +) / Double(values.count), median: median, minimum: values.first, maximum: values.last
        )
    }

    public static func rubrics(in rows: [Row]) -> [Rubric] {
        rows.compactMap { row in
            guard let id = row.string("id"), let title = row.text("title"), row.text("deleted_at") == nil else { return nil }
            let levels = (row.embeddedJSON("levels_json")?.arrayValue ?? []).compactMap { value -> RubricLevel? in
                guard let object = value.objectValue, let id = object["id"]?.stringValue else { return nil }
                return RubricLevel(id: id, label: object["label"]?.stringValue ?? object["name"]?.stringValue ?? id, score: object["score"]?.doubleValue ?? object["value"]?.doubleValue ?? 0)
            }
            let criteria = (row.embeddedJSON("criteria_json")?.arrayValue ?? []).compactMap { value -> RubricCriterion? in
                guard let object = value.objectValue, let id = object["id"]?.stringValue else { return nil }
                let raw = object["descriptors"]?.objectValue ?? object["cells"]?.objectValue ?? [:]
                return RubricCriterion(
                    id: id, label: object["label"]?.stringValue ?? object["title"]?.stringValue ?? id,
                    weight: object["weight"]?.doubleValue ?? 1,
                    descriptors: raw.compactMapValues(\.stringValue)
                )
            }
            return Rubric(
                id: id, title: title, description: row.text("description") ?? "", scaleMax: row.double("scale_max") ?? 5,
                weighted: row.int("weighted") == 1, levels: levels, criteria: criteria
            )
        }
    }

    public static func rubricScore(_ rubric: Rubric, selections: [String: String]) -> Double? {
        var earned = 0.0
        var denominator = 0.0
        for criterion in rubric.criteria {
            guard let levelId = selections[criterion.id], let level = rubric.levels.first(where: { $0.id == levelId }) else { continue }
            let weight = rubric.weighted ? max(0, criterion.weight) : 1
            earned += min(rubric.scaleMax, max(0, level.score)) * weight
            denominator += weight
        }
        return denominator > 0 ? earned / denominator : nil
    }
}
