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
        for type in VaultType.allCases {
            let routes = Set(NodusNavigationContract.visibleItems(for: type).map(\.route))
            #expect(routes.isSubset(of: NodusLinkPolicy.routes))
            #expect(routes.isDisjoint(with: [.workspace, .writing, .researchChat, .browser, .radar, .toolkit]))
            #expect(routes.contains(.podcast))
            if type == .estudio || type == .docencia {
                #expect(routes.contains(.studyIdeas) && routes.contains(.studyGraph))
                #expect(!routes.contains(.ideas) && !routes.contains(.graph))
            }
        }
    }
}
