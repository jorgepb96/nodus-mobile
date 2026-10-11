import Foundation
import Testing
@testable import NodusKit

@Suite("Actual saved view presentation")
struct DatabaseContainerPresentationTests {
    private var definition:JSONValue { .object(["viewId":.string("view"),"sources":.array([
        .object(["sourceId":.string("primary"),"databaseId":.string("home"),"primary":.bool(true),"propertyMap":.object(["title":.string("home-title"),"year":.string("home-year")])]),
        .object(["sourceId":.string("secondary"),"databaseId":.string("foreign"),"primary":.bool(false),"propertyMap":.object(["title":.string("foreign-title")])])])]) }
    private func row(_ id:String,source:String="primary",database:String="home") -> JSONValue {
        .object(["id":.string("\(source):\(id)"),"rowId":.string(id),"sourceId":.string(source),"databaseId":.string(database),"cells":.object(["title":.string("Texto \(id)"),"year":.null]),"revision":.int(8),"updatedAt":.string("2026-10-11T10:00:00Z")])
    }
    @Test("Canonical order, property mapping and foreign identities survive the native adaptation")
    func identities() throws {
        let rows=try DatabaseContainerPresentation.rows(definition:definition,rows:[row("second"),row("first",source:"secondary",database:"foreign")],databaseId:"home")
        #expect(rows.map(\.id)==["second","first"]);#expect(rows.map(\.position)==[0,1]);#expect(rows[1].databaseId=="foreign")
        #expect(rows[0].cells["home-title"]=="Texto second");#expect(rows[0].cells["home-year"]==nil);#expect(rows[1].cells["home-title"]=="Texto first")
    }
    @Test("Unknown sources, wrong owners and duplicate identities fail visibly")
    func invalid() {
        #expect(throws:DesktopBridgeError.self){try DatabaseContainerPresentation.rows(definition:definition,rows:[row("x",source:"unlinked")],databaseId:"home")}
        #expect(throws:DesktopBridgeError.self){try DatabaseContainerPresentation.rows(definition:definition,rows:[row("x",database:"foreign")],databaseId:"home")}
        #expect(throws:DesktopBridgeError.self){try DatabaseContainerPresentation.rows(definition:definition,rows:[row("x"),row("x")],databaseId:"home")}
        #expect(throws:DesktopBridgeError.self){try DatabaseContainerPresentation.rows(definition:definition,rows:[],databaseId:"unlinked")}
    }
}
