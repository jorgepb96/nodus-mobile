import Foundation
import NodusKit
import Testing
@testable import NodusAI

@Suite("Device embedding provider contracts", .serialized)
struct EmbeddingRequestTests {
    @Test("Gemini uses its native batch endpoint and the captured chosen identity")
    func gemini() async throws {
        EmbeddingRequestProtocol.inspect = { request in
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-001:batchEmbedContents")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "device-key")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = try embeddingRequestJSON(request)
            #expect(body == .object(["requests": .array([.object(["model": .string("models/gemini-embedding-001"), "content": .object(["parts": .array([.object(["text": .string("Actual selected concept")])])])])])]))
        }
        EmbeddingRequestProtocol.body = Data(#"{"embeddings":[{"values":[0.25,0.5]}]}"#.utf8)
        let vector = try await service().embed("Actual selected concept", as: .init(provider: "gemini", model: "gemini-embedding-001", dim: 2))
        #expect(vector == [0.25, 0.5])
    }

    @Test("OpenAI retains its dimension request and malformed dimensions fail")
    func dimensions() async throws {
        EmbeddingRequestProtocol.inspect = { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/embeddings")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer device-key")
            let body = try embeddingRequestJSON(request)
            #expect(body.objectValue?["dimensions"] == .int(3))
            #expect(body.objectValue?["model"] == .string("text-embedding-3-small"))
        }
        EmbeddingRequestProtocol.body = Data(#"{"data":[{"embedding":[0.25,0.5]}]}"#.utf8)
        await #expect(throws: EmbeddingError.self) {
            try await service().embed("Actual selected concept", as: .init(provider: "openai", model: "text-embedding-3-small", dim: 3))
        }
    }

    private func service() -> EmbeddingService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [EmbeddingRequestProtocol.self]
        return EmbeddingService(session: URLSession(configuration: config), keyProvider: { _ in "device-key" })
    }
}

private final class EmbeddingRequestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var inspect: (@Sendable (URLRequest) throws -> Void)?
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            try Self.inspect?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func embeddingRequestJSON(_ request: URLRequest) throws -> JSONValue {
    if let bytes = request.httpBody { return try JSONDecoder.nodus.decode(JSONValue.self, from: bytes) }
    let stream = try #require(request.httpBodyStream); stream.open(); defer { stream.close() }
    var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
        if count == 0 { break }; bytes.append(contentsOf: buffer.prefix(count))
    }
    return try JSONDecoder.nodus.decode(JSONValue.self, from: bytes)
}
