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

    @Test("every desktop route is classified exactly once")
    func desktopRoutesAreClassified() {
        #expect(Set(NodusNavigationContract.items.map(\.route)) == Set(NodusRoute.allCases))
        #expect(NodusNavigationContract.items.count == NodusRoute.allCases.count)
    }

    @Test("every vault has the universal pinned and tools routes")
    func navigationHasUniversalRoutes() {
        for vaultType in VaultType.allCases {
            let visible = NodusNavigationContract.visibleItems(for: vaultType)
            #expect(visible.first?.route == .home)
            #expect(visible.last?.route == .settings)
            #expect(visible.allSatisfy { $0.support.isVisible })
            #expect([.library, .browser, .radar, .toolkit].allSatisfy { route in
                visible.contains { $0.route == route }
            })
        }
    }

    @Test("academic sidebar matches the current Desktop hierarchy")
    func academicSidebarMatchesDesktop() {
        let visible = NodusNavigationContract.visibleItems(for: .academic).map(\.route)
        #expect(visible == [
            .home, .library,
            .search, .ideas, .authors, .graph, .argument,
            .research, .immersion, .deepResearch,
            .workspace,
            .browser, .radar, .toolkit,
            .settings,
        ])
        #expect(NodusNavigationContract.groupedItems(for: .academic).map(\.0) == [.explore, .analyze, .create, .tools])
        #expect(NodusNavigationContract.items.first(where: { $0.route == .deepResearch })?.systemImage == "megaphone")
    }

    @Test("dedicated vault sidebars use Desktop closed allow-lists")
    func dedicatedSidebarAllowlists() {
        let expected: [VaultType: Set<NodusRoute>] = [
            .prosopography: [.prosopSearch, .prosopPopulation, .prosopPersons, .prosopSources, .prosopAnalysis, .prosopNetworks, .notes, .browser, .radar, .toolkit],
            .primarySources: [.search, .archive, .persons, .timeline, .map, .relations, .notes, .browser, .radar, .toolkit],
            .estudio: [.studyCourses, .studySchedule, .studyCalendar, .studySearch, .studyLibrary, .studyRecordings, .studyChat, .studyIdeas, .studyGraph, .studyQuestions, .studyReview, .studyDeepResearch, .browser, .radar, .toolkit],
            .docencia: [.studyCourses, .teachingGroups, .studySchedule, .studyCalendar, .studyLibrary, .studyRecordings, .studyChat, .studyIdeas, .studyGraph, .studyQuestions, .teachingRubrics, .teachingExams, .teachingGrades, .teachingUnits, .browser, .radar, .toolkit],
            .databases: [.pages, .dbSearch, .dbAnalysis, .dbChat, .notes, .browser, .radar, .toolkit],
            .testimonios: [.search, .testimonyInterviews, .testimonyParticipants, .testimonyContrasts, .notes, .browser, .radar, .toolkit],
            .worldbuilding: [.encyclopedia, .characters, .places, .factions, .cultures, .timeline, .map, .relations, .tree, .dynasties, .worldChat, .rules, .conflicts, .arcs, .continuity, .questions, .notes, .scenes, .manuscript, .browser, .radar, .toolkit],
        ]
        let pinned: Set<NodusRoute> = [.home, .library, .settings]
        for (vaultType, routes) in expected {
            #expect(Set(NodusNavigationContract.visibleItems(for: vaultType).map(\.route)) == routes.union(pinned))
        }
    }

    @Test("every visible data-driven route has a concrete replica source")
    func visibleRoutesHaveSources() {
        for item in NodusNavigationContract.items where item.support.isVisible {
            switch item.support {
            case .collection(let path):
                #expect(Collections[path] != nil, "\(item.route.rawValue) points at an unknown collection: \(path)")
            case .mirror(let table, let field, let values):
                #expect(!table.isEmpty)
                #expect(field != nil || values.isEmpty)
                #expect(field == nil || !values.isEmpty)
            case .native:
                break
            default:
                Issue.record("a hidden support kind was marked visible")
            }
        }

        let studyIdeas = NodusNavigationContract.items.first { $0.route == .studyIdeas }
        #expect(studyIdeas?.support == .collection(path: "ideas"))
    }

    @Test("Worldbuilding exposes its complete current Desktop workspace")
    func worldbuildingContract() {
        let visible = Set(NodusNavigationContract.visibleItems(for: .worldbuilding).map(\.route))
        #expect(visible.isSuperset(of: [
            .encyclopedia, .characters, .places, .factions, .cultures, .dynasties,
            .rules, .conflicts, .arcs, .continuity, .questions, .worldChat,
            .scenes, .manuscript, .notes,
        ]))
        #expect(!NodusNavigationContract.visibleItems(for: .academic).contains {
            [.hypothesis, .reading, .writing, .projects].contains($0.route)
        })
    }

    @Test("one breakpoint model drives iPhone, split view and iPad")
    func adaptiveSidebarBreakpoints() {
        let phone = SidebarPresentation(availableWidth: 430, isUserCollapsed: false)
        #expect(!phone.isPersistent)

        let split = SidebarPresentation(availableWidth: 640, isUserCollapsed: false)
        #expect(split.isPersistent)
        #expect(split.isCollapsed)
        #expect(split.sidebarWidth == 64)

        let ipad = SidebarPresentation(availableWidth: 1_024, isUserCollapsed: false)
        #expect(ipad.isPersistent)
        #expect(!ipad.isCollapsed)
        #expect(ipad.sidebarWidth == 176)

        let resized = SidebarPresentation(availableWidth: 1_024, isUserCollapsed: false, expandedWidth: 284)
        #expect(resized.sidebarWidth == 284)
        #expect(SidebarPresentation(availableWidth: 1_024, isUserCollapsed: false, expandedWidth: 500).sidebarWidth == 360)

        let userCollapsed = SidebarPresentation(availableWidth: 1_024, isUserCollapsed: true)
        #expect(userCollapsed.isCollapsed)
    }

    @Test("every known vault type can draw its Home sections before counts arrive")
    @MainActor
    func homeSectionsDoNotWaitForTheOverview() {
        for vaultType in VaultType.allCases {
            let sections = SpaceSession.anticipatedSections(for: vaultType)

            #expect(!sections.isEmpty, "\(vaultType.rawValue) would open onto an empty Home board")
            #expect(sections.allSatisfy { !$0.families.isDisjoint(with: vaultType.families) })
            #expect(!sections.contains { ["passages", "study-calendar", "study-goals"].contains($0.path) })
        }
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
