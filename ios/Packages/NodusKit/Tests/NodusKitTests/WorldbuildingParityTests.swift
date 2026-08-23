import Testing
@testable import NodusKit

@Suite("Worldbuilding parity projections")
struct WorldbuildingParityTests {
    @Test("chronology and narrative order remain independent")
    func timelineLenses() {
        let scenes = [
            Row(["scene_id": .string("prologue"), "title": .string("Prologue"), "world_day": .int(900), "narrative_order": .int(0)]),
            Row(["scene_id": .string("present"), "title": .string("The present"), "world_day": .int(1200), "narrative_order": .int(1)]),
            Row(["scene_id": .string("flashback"), "title": .string("The promise"), "world_day": .int(1000), "narrative_order": .int(2)]),
        ]
        #expect(WorldbuildingParity.timeline(scenes: scenes, events: [], chronological: false).map(\.id) == ["scene:prologue", "scene:present", "scene:flashback"])
        #expect(WorldbuildingParity.timeline(scenes: scenes, events: [], chronological: true).map(\.id) == ["scene:prologue", "scene:flashback", "scene:present"])
    }

    @Test("manuscript composes books and chapters from scene-start markers")
    func manuscript() {
        let scenes = [
            Row(["scene_id": .string("s2"), "title": .string("Second"), "status": .string("draft"), "narrative_order": .int(1)]),
            Row(["scene_id": .string("s1"), "title": .string("First"), "status": .string("written"), "narrative_order": .int(0)]),
        ]
        let result = WorldbuildingParity.manuscript(
            scenes: scenes,
            texts: [Row(["scene_id": .string("s1"), "text": .string("One two three"), "word_count": .int(3)])],
            chapters: [Row(["scene_id": .string("s1"), "title": .string("Arrival")])],
            books: [Row(["scene_id": .string("s1"), "title": .string("Volume I")])]
        )
        #expect(result.map(\.id) == ["s1", "s2"])
        #expect(result[0].chapterTitle == "Arrival")
        #expect(result[0].bookTitle == "Volume I")
        #expect(result[0].wordCount == 3)
    }

    @Test("portable continuity findings are stable and honour content fingerprints")
    func continuity() {
        let scenes = [
            Row(["scene_id": .string("a"), "title": .string("Later"), "world_day": .int(20), "narrative_order": .int(0)]),
            Row(["scene_id": .string("b"), "title": .string("Earlier"), "world_day": .int(10), "narrative_order": .int(1)]),
        ]
        let rules = [Row(["rule_id": .string("r1"), "title": .string("Magic demands payment"), "status": .string("canon"), "hardness": .string("costly")])]
        let first = WorldbuildingParity.continuity(scenes: scenes, threads: [], beats: [], rules: rules, questions: [])
        #expect(Set(first.map(\.checkId)) == ["scene-day-reversal", "costly-rule-without-cost"])
        let muted = Set([WorldbuildingParity.fingerprint(check: "scene-day-reversal", subjects: ["scene:a", "scene:b"])])
        let second = WorldbuildingParity.continuity(scenes: scenes, threads: [], beats: [], rules: rules, questions: [], mutedFingerprints: muted)
        #expect(second.map(\.checkId) == ["costly-rule-without-cost"])
    }

    @Test("hierarchy keeps group and place namespaces separate")
    func hierarchy() {
        let result = WorldbuildingParity.hierarchy(
            groups: [Row(["group_id": .string("capital"), "name": .string("Capital House"), "kind": .string("house")])],
            places: [Row(["place_id": .string("capital"), "name": .string("Capital City"), "kind": .string("city")])]
        )
        #expect(Set(result.map(\.id)) == ["group:capital", "place:capital"])
    }
}
