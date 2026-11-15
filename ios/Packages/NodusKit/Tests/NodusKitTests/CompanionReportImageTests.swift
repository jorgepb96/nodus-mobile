import Foundation
import Testing
@testable import NodusKit

struct CompanionReportImageTests {
    private let metadata: JSONValue = .object(["entityKind": .string("deep_research"), "entityId": .string("report"), "status": .string("ready")])
    @Test func validatesSavedIdentityAndImageEncoding() throws {
        let result = try CompanionReportImage.bytes(metadata: metadata, dataURL: .string("data:image/png;base64,AQID"), reportId: "report")
        #expect(result.data == Data([1, 2, 3]))
        #expect(result.mime == "image/png")
        #expect(throws: DesktopBridgeError.self) { try CompanionReportImage.bytes(metadata: metadata, dataURL: .string("data:image/png;base64,AQID"), reportId: "other") }
        #expect(throws: DesktopBridgeError.self) { try CompanionReportImage.bytes(metadata: metadata, dataURL: .string("data:text/html;base64,AQID"), reportId: "report") }
        #expect(throws: DesktopBridgeError.self) { try CompanionReportImage.bytes(metadata: metadata, dataURL: .string("data:image/png;base64,"), reportId: "report") }
    }
}
