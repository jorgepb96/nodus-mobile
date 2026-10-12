import Foundation
import NodusKit
import Testing
@testable import NodusAI

@Suite("Device map reference image requests", .serialized) struct ImageReferenceTests {
    @Test("Gemini receives exact downloaded bytes and direction without a Mac provider") func reference() async throws {
        ImageReferenceProtocol.receive = { request in
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-image:generateContent")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "device-key")
            let body = try JSONDecoder.nodus.decode(JSONValue.self, from: try bodyData(request))
            let parts = try #require(body.objectValue?["contents"]?.arrayValue?.first?.objectValue?["parts"]?.arrayValue)
            #expect(parts.first?.objectValue?["text"] == .string("Continue west"))
            #expect(parts.last?.objectValue?["inlineData"]?.objectValue?["data"] == .string(Data("selected-reference".utf8).base64EncodedString()))
            #expect(parts.last?.objectValue?["inlineData"]?.objectValue?["mimeType"] == .string("image/png"))
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageReferenceProtocol.self]
        let image = try await ImageService(session: URLSession(configuration: config), keyProvider: { _ in "device-key" }).generate(prompt: "Continue west", reference: .init(data: Data("selected-reference".utf8), mimeType: "image/png"), with: .init(provider: .gemini, model: "gemini-flash-image"))
        #expect(image.data == Data("generated".utf8))
    }
    @Test("Text-only providers never silently discard the original reference") func unsupported() async throws {
        for model in [ModelRef(provider: .openai, model: "gpt-image"), ModelRef(provider: .gemini, model: "imagen-4")] {
            await #expect(throws: ProviderError.self) {
                try await ImageService(keyProvider: { _ in "device-key" }).generate(prompt: "Continue west", reference: .init(data: Data("selected".utf8), mimeType: "image/png"), with: model)
            }
        }
    }
}
private final class ImageReferenceProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var receive: (@Sendable (URLRequest) throws -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            try Self.receive?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let body: JSONValue = .object(["candidates":.array([.object(["content":.object(["parts":.array([.object(["inlineData":.object(["mimeType":.string("image/png"),"data":.string(Data("generated".utf8).base64EncodedString())])])])])])])])
            client?.urlProtocol(self, didLoad: try JSONEncoder.nodus.encode(body)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func bodyData(_ request: URLRequest) throws -> Data {
    if let data = request.httpBody { return data }
    let stream = try #require(request.httpBodyStream); stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }; if count == 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
    return data
}
