import Foundation
import Testing
import NodusKit
@testable import Nodus

@Suite("Actual bundled Desktop chat context")
@MainActor
struct CompanionChatContextTests {
    @Test("The isolated native host rejects absent complete sources")
    func genuineSourceFailure() async throws {
        // A missing resource is not a successful input rejection. This contract
        // must execute the current shared implementation built into the app.
        _ = try #require(Bundle.main.url(forResource:"companion-chat",withExtension:"js",subdirectory:"SharedDesktop"))
        let input: JSONValue = .object(["vaultId":.string(UUID().uuidString),"packs":.array([]),"databaseIds":.array([.string("fixture")]),"question":.string("Recuento"),"history":.array([]),"language":.string("es")])
        await #expect(throws:(any Error).self) { try await CompanionChatContext.evaluate(input) }
    }
    @Test("Cancellation before evaluation never opens a context host")
    func cancelledContext() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await CompanionChatContext.evaluate(.null)
        }
        await #expect(throws:CancellationError.self) { try await task.value }
    }
}
