import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Complete canonical saved views") @MainActor
struct CompanionDatabaseViewSourceTests {
    private var definition:JSONValue { .object(["viewId":.string("view"),"sources":.array([]),"properties":.array([])]) }
    private func wrapper(_ action:String,_ data:JSONValue,vault:String="vault") -> JSONValue {
        .object(["version":.int(1),"vaultId":.string(vault),"action":.string(action),"data":data])
    }
    private func page(_ start:Int,revision:String="actual-revision",cursor:String?=nil) -> JSONValue {
        let end=min(start+30,73)
        return .object(["rows":.array((start..<end).map{.object(["id":.string("source:row-\($0)")])}),"totalCount":.int(73),"revision":.string(revision),"queryHash":.string("actual-query"),"sources":.array([]),"properties":.array([]),"nextCursor":end<73 ? .string(cursor ?? "cursor-\(end)"):.null,"hasMore":.bool(end<73)])
    }
    @Test("All query pages are consumed in order and their epoch is checked again")
    func complete() async throws {
        var requests:[JSONValue]=[]
        let source=try await CompanionDatabaseViewSource.load(vault:"vault",viewId:"view"){method,args in
            #expect(method=="getMobileLinkedDatabaseRead");requests.append(args[0])
            if args[0].objectValue?["action"] == .string("definition"){return wrapper("definition",definition)}
            let cursor=args[0].objectValue?["input"]?.objectValue?["cursor"]?.stringValue
            let start=cursor.flatMap{Int($0.replacingOccurrences(of:"cursor-",with:""))} ?? 0
            return wrapper("rows",page(start))
        }
        #expect(source.rows.count==73);#expect(source.rows.first?.objectValue?["id"] == .string("source:row-0"));#expect(source.rows.last?.objectValue?["id"] == .string("source:row-72"))
        #expect(requests.count==5);#expect(requests.last?.objectValue?["input"]?.objectValue?["cursor"] == .null)
    }
    @Test("Changed epochs and another vault do not become empty result sets")
    func epochs() async {
        var pages=0
        await #expect(throws:DesktopBridgeError.self){try await CompanionDatabaseViewSource.load(vault:"vault",viewId:"view"){_,args in
            if args[0].objectValue?["action"] == .string("definition"){return wrapper("definition",definition)}
            pages += 1;return wrapper("rows",page((pages-1)*30,revision:pages==1 ? "before":"after"))
        }}
        await #expect(throws:DesktopBridgeError.self){try await CompanionDatabaseViewSource.load(vault:"vault",viewId:"view"){_,_ in wrapper("definition",definition,vault:"other")}}
    }
    @Test("A repeated cursor cannot duplicate rows or loop indefinitely")
    func repeatedCursor() async {
        await #expect(throws:DesktopBridgeError.self){try await CompanionDatabaseViewSource.load(vault:"vault",viewId:"view"){_,args in
            if args[0].objectValue?["action"] == .string("definition"){return wrapper("definition",definition)}
            return wrapper("rows",page(0,cursor:"loop"))
        }}
    }
}
