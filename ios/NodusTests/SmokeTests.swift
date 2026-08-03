import Foundation
import NodusKit
import Testing
@testable import Nodus

/// The app target's own tests. The interesting assertions live in the packages, where they
/// run without a simulator; this bundle exists to prove the app links what it claims to.
@Suite("App wiring")
struct AppWiringTests {
    @Test("NodusKit is linked into the app and its contract table is intact")
    func linksNodusKit() {
        #expect(Collections.all.count == 23)
        #expect(Collections["deep-research"] == nil, "deep-research is a special resource, not a collection")
        #expect(SpecialResource.deepResearch.listKey == "reports")
    }

    /// The primary key of every study and teaching table is `id`.
    ///
    /// The table used to declare `subject_id`, `card_id`, `exam_id` and six more — columns
    /// none of those tables has (`electron/db/migrations.ts:1573` onwards). `idField` is what
    /// decides whether a detail can be enriched and whether a row listed inside another
    /// dossier is a link, so every study and teaching row was un-openable and no exam could
    /// ever have loaded its questions.
    @Test("study and teaching collections are keyed on the column their table really has")
    func studyCollectionsUseId() {
        let studyAndTeaching = Collections.all.filter {
            $0.table.hasPrefix("study_") || $0.table.hasPrefix("teaching_")
        }
        #expect(studyAndTeaching.count == 12)
        for collection in studyAndTeaching {
            #expect(collection.idField == "id", "\(collection.path) is keyed on \(collection.idField)")
        }
    }

    /// Two closed vocabularies the agenda and the goals translate, and the rule for everything
    /// else: say nothing rather than print a raw column value beside translated text.
    ///
    /// A block's `type` is a free string in the schema (`shared/studyPlanner.ts:3`), which is
    /// why it is not in this list and not on the screen — whatever the planner wrote, in
    /// whatever language, would have gone straight onto a Spanish page.
    @Test("only the closed vocabularies are put into words")
    func studyVocabularies() {
        #expect(AgendaView.eventLabel("exam") != nil)
        #expect(AgendaView.eventLabel("assignment") != nil)
        #expect(AgendaView.eventLabel("class") != nil)
        #expect(AgendaView.eventLabel("session") != nil)
        #expect(AgendaView.eventLabel("whatever-the-planner-wrote") == nil)
        #expect(AgendaView.eventLabel(nil) == nil)

        #expect(GoalsView.periodLabel("daily") != nil)
        #expect(GoalsView.periodLabel("weekly") != nil)
        #expect(GoalsView.periodLabel("monthly") != nil)
        #expect(GoalsView.periodLabel("fortnightly") == nil)
    }

    /// The two enriched handlers whose response key is not the path with its `s` dropped.
    @Test("an enriched detail is read under the key the server actually answers with")
    func enrichedDetailKeys() {
        #expect(Collections["teaching-exams"]?.detailKey == "exam")
        #expect(Collections["study-plans"]?.detailKey == "plan")
        #expect(Collections["study-docs"]?.detailKey == "study-doc")
        #expect(Collections["ideas"]?.detailKey == "idea")
    }

    /// Info.plist and the code have to agree, and nothing else checks that they do.
    ///
    /// An identifier the bundle permits but nobody registers is a capability the app claims and
    /// does not have — which is exactly what these three were for a year. An identifier
    /// registered but not permitted is worse: `BGTaskScheduler` traps at launch, on a device,
    /// and never in the simulator where it would have been noticed.
    @Test("every permitted background identifier is one the app actually claims")
    func backgroundIdentifiersMatchTheBundle() {
        let permitted = Set(BackgroundWork.permittedIdentifiers)
        #expect(!permitted.isEmpty, "the test bundle must be reading the app's own Info.plist")
        #expect(Set(BackgroundWork.identifiers) == permitted)
    }

    /// A processing task needs the background mode that permits it. Declaring the identifiers
    /// without the mode gives a scheduler that accepts submissions and never runs them.
    @Test("the background modes cover the tasks the app submits")
    func backgroundModesAreDeclared() {
        let modes = Set(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [])
        #expect(modes.contains("processing"))
    }
}
