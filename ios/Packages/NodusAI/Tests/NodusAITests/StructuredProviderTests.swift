import Foundation
import NodusKit
import Testing
@testable import NodusAI

@Suite("Structured provider transport", .serialized)
struct StructuredProviderTests {
    @Test("shared reasoning controls reach the provider with a separate answer budget")
    func sharedControls() async throws {
        StructuredProviderProtocol.receive = { request in
            let bytes: Data
            if let body = request.httpBody { bytes = body }
            else {
                let stream = try #require(request.httpBodyStream)
                stream.open(); defer { stream.close() }
                var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
                    if count == 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                bytes = body
            }
            let body = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(body["max_tokens"] as? Int == 11_792)
            #expect(body["reasoning_effort"] as? String == "low")
            #expect((body["thinking"] as? [String: String])?["type"] == "enabled")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer phone-owned-test")
            #expect(!String(decoding: bytes, as: UTF8.self).contains("phone-owned-test"))
        }
        let result = try await client().complete(ChatRequest(model: .init(provider: .deepseek, model: "deepseek-flash"), messages: [.init(role: .user, content: "Return JSON")], maxTokens: 11_792, jsonMode: true,
            researchParameters: ["thinking": .object(["type": .string("enabled")]), "reasoning_effort": .string("low")]))
        #expect(result == "{\"ok\":true}")
    }
    @Test("truncated output remains a failure with a diagnosable error")
    func truncated() async throws {
        StructuredProviderProtocol.receive = { _ in }
        StructuredProviderProtocol.finishReason = "length"
        defer { StructuredProviderProtocol.finishReason = "stop" }
        do { _ = try await client().complete(.init(model: .init(provider: .deepseek, model: "deepseek-flash"), messages: [.init(role: .user, content: "Return JSON")]))
            Issue.record("A truncated answer must not be accepted.")
        } catch let error as ProviderError {
            guard case .truncated = error else { throw error }
            #expect(error.localizedDescription.contains("output_truncated"))
        }
    }
    private func client() -> ProviderClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StructuredProviderProtocol.self]
        return ProviderClient(session: URLSession(configuration: config), keyProvider: { _ in "phone-owned-test" })
    }
}
private final class StructuredProviderProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var receive: (@Sendable (URLRequest) throws -> Void)?
    nonisolated(unsafe) static var finishReason = "stop"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            try Self.receive?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"{\\\"ok\\\":true}\"},\"finish_reason\":\"\(Self.finishReason)\"}]}\n\ndata: [DONE]\n\n"
            client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
