import Foundation
import NodusKit
import Testing
@testable import Nodus

@Suite("Nodus Link release boundary") @MainActor
struct NodusLinkPolicyTests {
    @Test func authoringCannotBeReenabledByAnOldRouteOrForgedSurfaceCall() throws {
        #expect(throws: APIError.self) { try NodusLinkPolicy.requireAuthoring() }
        for method in ["startDictionaryGeneration", "updateDictionaryEntry", "enqueueDeepResearchJob",
            "generateImmersionSession", "savePageDocument", "mobileStructuredCompletion", "runMobileSpaceAction"] {
            #expect(throws: APIError.self) { try NodusLinkPolicy.requireSurfaceMethod(method, domain: "writing") }
            #expect(throws: APIError.self) { try NodusLinkPolicy.requireSurfaceMethod(method, domain: nil) }
        }
        for method in ["listDictionaryEntries", "getWritingWorkshopDraft", "getMobileStructuralArgumentMap", "podcastEpisodes"] {
            try NodusLinkPolicy.requireSurfaceMethod(method, domain: "corpus")
        }
        try NodusLinkPolicy.requireSurfaceMethod("navigate", domain: nil)
        for kind in ["citation", "idea", "work", "author", "deepResearchReport", "legacyResearchReports"] {
            try NodusLinkPolicy.requireReaderNavigation(kind, record: "fixture")
        }
        try NodusLinkPolicy.requireReaderNavigation("section", record: "dictionary")
        for kind in ["studyAssistant", "trashedStudyDocument", "generate", "unknown"] {
            #expect(throws: APIError.self) { try NodusLinkPolicy.requireReaderNavigation(kind, record: "fixture") }
        }
        #expect(throws: APIError.self) { try NodusLinkPolicy.requireReaderNavigation("section", record: "writing") }
        let invite = PageChatInvite()
        invite.reportId = "link-read-only-fixture"
        invite.ask(about: "Selected text")
        #expect(!invite.isOpen)
        for type in VaultType.allCases {
            let routes = Set(NodusNavigationContract.visibleItems(for: type).map(\.route))
            #expect(routes.isSubset(of: NodusLinkPolicy.routes))
            #expect(routes.isDisjoint(with: [.workspace, .writing, .researchChat, .browser, .radar, .toolkit]))
            if type == .academic {
                #expect(routes.contains(.podcast))
                #expect(routes.contains(.ideas) && routes.contains(.graph))
            } else {
                #expect(routes.isEmpty)
                #expect(!NodusLinkPolicy.supports(type))
            }
        }
    }
    @Test("phone shortcuts preserve three slots, reject unsupported tools and restore the same choices")
    func phoneShortcuts() throws {
        let suite = "nodus.tests.pins.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SyncedDefaults(defaults: defaults, cloud: nil)
        let preferences = AppPreferences(store: store)
        #expect(preferences.phonePinnedRoutes == [.ideas, .graph, .deepResearch])
        preferences.pinPhoneRoute(.podcast)
        #expect(preferences.phonePinnedRoutes.count == 3)
        preferences.pinPhoneRoute(.podcast, replacing: .graph)
        #expect(preferences.phonePinnedRoutes == [.ideas, .podcast, .deepResearch])
        preferences.pinPhoneRoute(.browser, replacing: .ideas)
        #expect(preferences.phonePinnedRoutes == [.ideas, .podcast, .deepResearch])
        preferences.unpinPhoneRoute(.ideas)
        preferences.pinPhoneRoute(.library)
        #expect(AppPreferences(store: store).phonePinnedRoutes == [.podcast, .deepResearch, .library])
    }

}
