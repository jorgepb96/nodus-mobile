import Foundation
import NodusKit
import Testing
@testable import NodusAI

/// A provider key must reach exactly one place — an `Authorization`-class header on a request
/// to that provider — and nowhere else.
///
/// These are cheap assertions about a property that is expensive to lose. A key that leaks
/// cannot be un-leaked, and the two ways it happens in practice are a URL (which lands in
/// caches, proxy logs and `NSURLErrorFailingURLStringErrorKey`) and a log line.
@Suite("Key handling")
struct KeyHandlingTests {
    private let secret = "sk-test-DO-NOT-LEAK-9f3a"

    @Test("no provider puts its key in a URL")
    func keysNeverAppearInURLs() {
        for provider in AIProvider.allCases {
            guard let base = provider.openAICompatibleBase else { continue }
            let url = base.appendingPathComponent("chat/completions").absoluteString
            #expect(!url.contains(secret))
            #expect(!url.lowercased().contains("key="), "\(provider.rawValue) builds a key into its URL")
            #expect(!url.lowercased().contains("token="), "\(provider.rawValue) builds a token into its URL")
        }
    }

    @Test("the key travels as a header, and the header is the one the provider expects")
    func keysTravelInHeaders() {
        // Anthropic is the odd one out; everybody else is Bearer.
        let anthropic = AIProvider.anthropic.authHeaders(key: secret)
        #expect(anthropic["x-api-key"] == secret)
        #expect(anthropic["Authorization"] == nil)

        for provider in AIProvider.allCases where provider != .anthropic {
            let headers = provider.authHeaders(key: secret)
            #expect(headers["Authorization"] == "Bearer \(secret)", "\(provider.rawValue)")
        }
    }

    @Test("the OpenRouter attribution headers carry no credential")
    func attributionIsNotACredential() {
        let headers = AIProvider.openrouter.authHeaders(key: secret)
        #expect(headers["HTTP-Referer"]?.contains(secret) == false)
        #expect(headers["X-Title"]?.contains(secret) == false)
    }

    // NodusKit is the whole conversation with a Nodus Server. It must have no way to name a
    // provider key, because the server's design rests on never holding one: /context returns
    // material and a budget precisely so the phone calls its own provider itself.
    @Test("the Nodus Server client has no concept of a provider key")
    func theServerClientCannotSeeAKey() {
        // Mutation is the richest thing the client sends. Its table list is closed, and none
        // of the writable tables is a place a credential could ride along in.
        // Worldbuilding legitimately has in-universe secrets and people who know them; those
        // nouns are story data, not credentials. Guard the actual credential-shaped table names
        // instead of rejecting a whole research domain because it contains the word "secret".
        let credentialTables: Set<String> = [
            "api_keys", "provider_keys", "provider_tokens", "auth_tokens", "credentials",
            "secrets", "settings",
        ]
        #expect(credentialTables.isDisjoint(with: MutableTable.allCases.map(\.rawValue)))
        // And the snapshot the client reads has these stripped server-side; asserting the
        // client agrees about which columns are machinery keeps the two in step.
        #expect(!MutableTable.allCases.map(\.rawValue).contains("settings"))
    }

    @Test("an error carries the provider's message, never the request that produced it")
    func errorsDoNotEchoRequests() {
        let body = #"{"error":{"message":"Invalid API key","type":"invalid_request_error"}}"#
        let message = ProviderClient.errorMessage(from: body)
        #expect(message == "Invalid API key")
        #expect(message?.contains(secret) == false)
    }

    @Test("a missing key is reported by provider, not by value")
    func missingKeyNamesTheProviderOnly() {
        let service = EmbeddingService(keyProvider: { _ in nil })
        let identity = EmbeddingIdentity(provider: "openai", model: "text-embedding-3-small", dim: 1536)
        guard case .failure(let reason) = service.availability(for: identity) else {
            Issue.record("expected a missing key"); return
        }
        #expect(reason.explanation.contains("OpenAI"))
        #expect(!reason.explanation.contains(secret))
    }
}
