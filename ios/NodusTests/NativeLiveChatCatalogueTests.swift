import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Native live model catalogue selection") @MainActor
struct NativeLiveChatCatalogueTests {
    @Test("changing provider during loading starts latest request and discards an old response")
    func latestProvider() async throws {
        let options=NativeLiveChatOptions(spaceId:UUID().uuidString)
        let first=PendingCatalogue(),latest=PendingCatalogue()
        let a=Task { await options.catalogue(provider:"ollama",request:first.response) }
        await first.started()
        let b=Task { await options.catalogue(provider:"codex",request:latest.response) }
        await latest.started()
        first.finish(.success(Self.catalogue("local-old")))
        await a.value
        #expect(options.catalogLoading)
        #expect(options.models.isEmpty)
        latest.finish(.success(Self.catalogue("subscription-current")))
        await b.value
        #expect(!options.catalogLoading)
        #expect(options.models == [.object(["provider":.string("codex"),"model":.string("subscription-current")])])
        #expect(options.issue == nil)
    }
    @Test("old failure cannot overwrite successful latest provider or its loading state")
    func staleFailure() async throws {
        let options=NativeLiveChatOptions(spaceId:UUID().uuidString)
        let first=PendingCatalogue(),latest=PendingCatalogue()
        let a=Task { await options.catalogue(provider:"ollama",request:first.response) }
        await first.started()
        let b=Task { await options.catalogue(provider:"github-copilot",request:latest.response) }
        await latest.started()
        latest.finish(.success(Self.catalogue("copilot-current")));await b.value
        first.finish(.failure(URLError(.timedOut)));await a.value
        #expect(!options.catalogLoading)
        #expect(options.issue == nil)
        #expect(options.models.first?.objectValue?["provider"] == .string("github-copilot"))
    }
    @Test("unreadable catalogue remains an explicit error rather than an empty successful list")
    func unreadable() async throws {
        let options=NativeLiveChatOptions(spaceId:UUID().uuidString)
        await options.catalogue(provider:"codex") { .object(["status":.string("unreadable")]) }
        #expect(options.issue != nil)
        #expect(!options.catalogLoading)
        #expect(options.models.isEmpty)
    }
    private static func catalogue(_ id:String) -> JSONValue {
        .object(["status":.string("read"),"selectableModels":.array([.object(["id":.string(id)])])])
    }
}
@MainActor private final class PendingCatalogue {
    private var pending:CheckedContinuation<JSONValue,any Error>?
    func response() async throws -> JSONValue { try await withCheckedThrowingContinuation { pending=$0 } }
    func started() async { while pending == nil { await Task.yield() } }
    func finish(_ result:Result<JSONValue,any Error>) { pending!.resume(with:result);pending=nil }
}
