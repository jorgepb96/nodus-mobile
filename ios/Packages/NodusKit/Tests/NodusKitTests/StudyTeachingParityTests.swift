import Foundation
import Testing
@testable import NodusKit

@Suite("Study and Teaching parity")
struct StudyTeachingParityTests {
    @Test("course hierarchy and mastery remain deterministic")
    func studyProjection() {
        let tables: [String: [Row]] = [
            "study_courses": [row(["id": "course", "short_id": "C-1", "name": "History", "favorite": 1, "position": 0])],
            "study_subjects": [row(["id": "subject", "course_id": "course", "name": "Methods", "position": 0])],
            "study_topics": [row(["id": "topic", "subject_id": "subject", "name": "Archives", "position": 0])],
        ]
        #expect(StudyTeachingParity.courses(in: tables).map(\.name) == ["History"])
        #expect(StudyTeachingParity.subjects(courseId: "course", in: tables).map(\.name) == ["Methods"])
        #expect(StudyTeachingParity.topics(subjectId: "subject", in: tables).map(\.name) == ["Archives"])

        let result = StudyTeachingParity.summarize(.init(correct: 8, incorrect: 2, omitted: 3, studySeconds: 900, reviews: 12, lapses: 1))
        #expect(result.attempts == 10)
        #expect(result.accuracy == 0.8)
        #expect(result.status == "strong")
        #expect(result.mastery > 0.75 && result.mastery < 0.85)
    }

    @Test("gradebook distinguishes a blank, an exemption and missing work")
    func gradebook() {
        let students = StudyTeachingParity.students(in: [
            row(["id": "s1", "group_id": "g", "pseudonym_code": "STU_A", "given_names": "Ada", "surnames": "L.", "position": 0]),
            row(["id": "s2", "group_id": "g", "pseudonym_code": "STU_B", "position": 1]),
        ])
        let items = StudyTeachingParity.assessmentItems(in: [
            row(["id": "essay", "plan_id": "p", "name": "Essay", "weight": 60.0, "weight_alt": 50.0, "max_points": 10.0, "is_mandatory": 1, "position": 0]),
            row(["id": "oral", "plan_id": "p", "name": "Oral", "weight": 40.0, "weight_alt": 50.0, "max_points": 10.0, "position": 1]),
        ])
        let entries = StudyTeachingParity.gradeEntries(in: [
            row(["id": "e1", "student_id": "s1", "item_id": "essay", "raw_value": 8.0, "status": "assessed"]),
            row(["id": "e2", "student_id": "s1", "item_id": "oral", "raw_value": 6.0, "status": "assessed"]),
            row(["id": "e3", "student_id": "s2", "item_id": "essay", "status": "not_submitted"]),
            row(["id": "e4", "student_id": "s2", "item_id": "oral", "status": "exempt"]),
        ])
        let rows = StudyTeachingParity.gradebook(students: students, items: items, entries: entries)
        #expect(abs((rows[0].finalGrade ?? 0) - 7.2) < 0.0001)
        #expect(rows[0].passed == true)
        #expect(rows[1].finalGrade == 0)
        let distribution = StudyTeachingParity.distribution(rows)
        #expect(distribution.evaluated == 2)
        #expect(distribution.passed == 1)
        #expect(abs((distribution.median ?? 0) - 3.6) < 0.0001)
    }

    @Test("rubric descriptors and weighted score match the Desktop grid")
    func rubric() {
        let levels = #"[{"id":"excellent","label":"Excellent","score":5},{"id":"developing","label":"Developing","score":3}]"#
        let criteria = #"[{"id":"evidence","label":"Evidence","weight":3,"descriptors":{"excellent":"Triangulated","developing":"Partial"}},{"id":"argument","label":"Argument","weight":2,"descriptors":{"excellent":"Coherent","developing":"Uneven"}}]"#
        let rubrics = StudyTeachingParity.rubrics(in: [row([
            "id": "r", "title": "Research brief", "scale_max": 5.0, "weighted": 1,
            "levels_json": levels, "criteria_json": criteria,
        ])])
        #expect(rubrics[0].criteria[0].descriptors["excellent"] == "Triangulated")
        let score = StudyTeachingParity.rubricScore(rubrics[0], selections: ["evidence": "excellent", "argument": "developing"])
        #expect(abs((score ?? 0) - 4.2) < 0.0001)
    }

    private func row(_ values: [String: Any]) -> Row {
        Row(values.mapValues { value in
            switch value {
            case let value as String: .string(value)
            case let value as Int: .int(Int64(value))
            case let value as Double: .double(value)
            default: .null
            }
        })
    }
}
