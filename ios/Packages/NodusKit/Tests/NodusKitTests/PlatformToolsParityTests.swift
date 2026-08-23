import Foundation
import Testing
@testable import NodusKit

@Suite("Browser, Radar and Toolkit parity")
struct PlatformToolsParityTests {
    @Test func browserNormalizesSearchesAndRejectsLocalTargets() throws {
        #expect(NodusWebURLPolicy.browserDestination(for: "digital humanities")?.host == "www.google.com")
        #expect(NodusWebURLPolicy.browserDestination(for: "example.org")?.absoluteString == "https://example.org")
        #expect(NodusWebURLPolicy.browserDestination(for: "file:///private/etc/hosts") == nil)
        #expect(NodusWebURLPolicy.browserDestination(for: "http://127.0.0.1:8787") == nil)
        #expect(NodusWebURLPolicy.browserDestination(for: "https://192.168.1.20/admin") == nil)
        #expect(NodusWebURLPolicy.isAllowedRadarSource(try #require(URL(string: "https://openalex.org/works"))))
        #expect(!NodusWebURLPolicy.isAllowedRadarSource(try #require(URL(string: "http://example.org/feed"))))
    }

    @Test func radarMergePreservesReadAndSavedState() {
        let old = RadarUpdateRecord(id: "doi:one", followId: "f", followTitle: "Topic", title: "Old", source: "Crossref", detectedAt: .distantPast, isRead: true)
        let fresh = RadarUpdateRecord(id: "doi:one", followId: "f", followTitle: "Topic", title: "New", source: "Crossref", detectedAt: .now, savedToLibrary: true)
        let merged = RadarProjection.merge([old], incoming: [fresh])
        #expect(merged.count == 1)
        #expect(merged[0].title == "New")
        #expect(merged[0].isRead)
        #expect(merged[0].savedToLibrary)
        #expect(RadarProjection.filtered(merged, query: "crossref", unreadOnly: true).isEmpty)
    }

    @Test func desktopToolkitPayloadCannotContainPathsOrNativeOperations() {
        #expect(ToolkitDesktopPayload(operation: .mergePDF, libraryObjectIds: ["sha256"], outputFormat: "pdf") == nil)
        #expect(ToolkitDesktopPayload(operation: .officeToPDF, libraryObjectIds: ["/Users/me/private.docx"], outputFormat: "pdf") == nil)
        let safe = ToolkitDesktopPayload(operation: .officeToPDF, libraryObjectIds: ["sha256-deadbeef"], outputFormat: "pdf")
        #expect(safe?.operation == "docx-to-text")
    }
}
