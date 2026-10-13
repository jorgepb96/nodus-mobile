import Foundation
import NodusKit
import Testing
@testable import NodusAI

/// HTTP contracts from the providers' documented request/response formats.
/// These exercise URLSession shaping; they are not live generation evidence.
@Suite("Image provider format and chosen aspect ratio", .serialized)
struct ImageRequestTests {
    @Test("Gemini uses the Desktop Interactions options without storing the prompt")
    func gemini() async throws {
        ImageRequestProtocol.inspect = { request in
            #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-key")
            #expect(request.url?.query == nil)
            let value = try requestJSON(request)
            #expect(value == .object([
                "model": .string("gemini-3.1-flash-image"), "input": .string("A landscape"), "store": .bool(false),
                "response_format": .object(["type": .string("image"), "mime_type": .string("image/jpeg"),
                    "aspect_ratio": .string("16:9"), "image_size": .string("1K")])
            ]))
        }
        ImageRequestProtocol.body = Data(#"{"output_image":{"mime_type":"image/jpeg","data":"aW1hZ2U="}}"#.utf8)
        ImageRequestProtocol.status = 200; ImageRequestProtocol.calls = 0
        let image = try await service().generate(prompt: "A landscape", with: .init(provider: .gemini, model: "gemini-3.1-flash-image"))
        #expect(image.data == Data("image".utf8)); #expect(image.mimeType == "image/jpeg")
        #expect(ImageRequestProtocol.calls == 1)
    }

    @Test("OpenRouter receives the chosen portrait ratio and preserves the returned MIME type")
    func openrouter() async throws {
        ImageRequestProtocol.inspect = { request in
            #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/images")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            let value = try requestJSON(request)
            #expect(value == .object([
                "model": .string("google/gemini-3.1-flash-image"), "prompt": .string("A portrait"),
                "n": .int(1), "aspect_ratio": .string("9:16")
            ]))
        }
        ImageRequestProtocol.body = Data(#"{"data":[{"b64_json":"aW1hZ2U=","media_type":"image/webp"}]}"#.utf8)
        ImageRequestProtocol.status = 200; ImageRequestProtocol.calls = 0
        let image = try await service().generate(prompt: "A portrait", with: .init(provider: .openrouter, model: "google/gemini-3.1-flash-image"), aspectRatio: "9:16")
        #expect(image.data == Data("image".utf8)); #expect(image.mimeType == "image/webp")
    }

    @Test("OpenAI maps square and portrait choices to supported dimensions")
    func openai() async throws {
        for (ratio, size) in [("1:1", "1024x1024"), ("3:4", "1024x1536")] {
            ImageRequestProtocol.inspect = { request in
                #expect(request.url?.absoluteString == "https://api.openai.com/v1/images/generations")
                let value = try requestJSON(request)
                #expect(value.objectValue?["size"] == .string(size))
                #expect(value.objectValue?["output_format"] == .string("png"))
            }
            ImageRequestProtocol.body = Data(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#.utf8)
            ImageRequestProtocol.status = 200
            _ = try await service().generate(prompt: "A portrait", with: .init(provider: .openai, model: "gpt-image-1.5"), aspectRatio: ratio)
        }
    }

    @Test("Unsupported ratios never send a request and provider rejection is not retried")
    func rejection() async throws {
        ImageRequestProtocol.inspect = nil; ImageRequestProtocol.calls = 0
        ImageRequestProtocol.status = 400
        ImageRequestProtocol.body = Data(#"{"error":{"message":"unsupported model"}}"#.utf8)
        await #expect(throws: ProviderError.self) {
            try await service().generate(prompt: "A landscape", with: .init(provider: .gemini, model: "gemini-3.1-flash-image"), aspectRatio: "100:1")
        }
        #expect(ImageRequestProtocol.calls == 0)
        await #expect(throws: ProviderError.self) {
            try await service().generate(prompt: "A landscape", with: .init(provider: .gemini, model: "gemini-3.1-flash-image"))
        }
        #expect(ImageRequestProtocol.calls == 1)
    }

    private func service() -> ImageService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageRequestProtocol.self]
        return ImageService(session: URLSession(configuration: configuration), keyProvider: { _ in "fixture-key" })
    }
}

private final class ImageRequestProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var inspect: (@Sendable (URLRequest) throws -> Void)?
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.calls += 1; try Self.inspect?(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func requestJSON(_ request: URLRequest) throws -> JSONValue {
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
