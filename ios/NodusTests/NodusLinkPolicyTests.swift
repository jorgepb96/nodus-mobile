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
