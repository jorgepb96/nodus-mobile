import Foundation
import Testing
@testable import NodusKit

@Suite("Desktop specialised citation routes")
struct SpecialisedCorpusReferenceTests {
    @Test("actual Desktop schemes open known corpus collections without a guessed vault identity")
    func routes() throws {
        let targets = [
            ("world/character", "persons"), ("world/place", "places"), ("world/group", "world-groups"),
            ("world/scene", "world-scenes"), ("world/map", "world-maps"), ("world/article", "world-articles"),
            ("world/rule", "world-rules"), ("world/thread", "world-threads"), ("world/event", "events"),
            ("world/question", "world-questions"), ("world/secret", "world-secrets"),
            ("study/doc", "study-docs"), ("study/material", "study-materials"), ("archive", "archive-items"),
            ("primary-source", "archive-items"), ("testimonios/interview", "testimony-interviews"),
            ("testimonios/participant", "persons"), ("testimonios/contrast", "testimony-contrasts")]
        for (route, path) in targets {
            let target = try #require(SpecialisedCorpusReference(URL(string: "nodus://\(route)/actual-id")!))
            #expect(target.collectionPath == path); #expect(target.recordId == "actual-id")
        }
        #expect(SpecialisedCorpusReference(URL(string: "nodus://world/browser/private-id")!) == nil)
        #expect(SpecialisedCorpusReference(URL(string: "https://world/character/id")!) == nil)
        #expect(SpecialisedCorpusReference(URL(string: "nodus://user@archive/id")!) == nil)
        #expect(SpecialisedCorpusReference(URL(string: "nodus://world/character/id/extra")!) == nil)
    }

    @Test("a primary-source excerpt must belong to the cited document")
    func ownership() throws {
        let target = try #require(SpecialisedCorpusReference(URL(string: "nodus://primary-source/source-a/excerpt/excerpt-a")!))
        #expect(target.collectionPath == "archive-excerpts")
        #expect(target.accepts(Row(["excerpt_id": .string("excerpt-a"), "item_id": .string("source-a")])))
        #expect(!target.accepts(Row(["excerpt_id": .string("excerpt-a"), "item_id": .string("source-b")])))
        #expect(!target.accepts(Row(["excerpt_id": .string("other"), "item_id": .string("source-a")])))
    }

    @Test("encoded identifiers decode once and preserve actual source locators")
    func identities() throws {
        let target = try #require(SpecialisedCorpusReference(URL(string: "nodus://study/material/item%252Fpart?page=37&slide=4")!))
        #expect(target.recordId == "item%2Fpart"); #expect(target.page == 37); #expect(target.slide == 4)
        let recording = try #require(SpecialisedCorpusReference(URL(string: "nodus://testimonios/interview/i?t=12.4&transcript=t-1")!))
        #expect(recording.timestamp == 12.4); #expect(recording.transcriptId == "t-1")
        #expect(SpecialisedCorpusReference(URL(string: "nodus://primary-source/..")!) == nil)
    }
}
