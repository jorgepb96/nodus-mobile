import Foundation
import NodusKit

/// A database vision call sends the actual downloaded image bytes. It never
/// retries a paid request or substitutes a Desktop provider.
public actor DatabaseVisionCompletion {
    public struct Image: Sendable {
        public let data: Data
        public let mime: String
        public init(data: Data, mime: String) { self.data = data; self.mime = mime }
    }
    private let session: URLSession
    private let keyProvider: @Sendable (AIProvider) -> String?
    public init(session: URLSession = .providerDefault, keyProvider: @escaping @Sendable (AIProvider) -> String?) {
        self.session = session; self.keyProvider = keyProvider
    }
    public static func request(model: ModelRef, system: String, prompt: String, images: [Image], key: String) throws -> URLRequest {
        guard !images.isEmpty, images.count <= 2,
              images.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 10_000_000 && ["image/png","image/jpeg","image/webp","image/gif"].contains($0.mime) }) else {
            throw ProviderError.malformedResponse("A database vision request requires one or two valid downloaded images.")
        }
        var body: [String: JSONBody]
        let url: URL
        if model.provider == .anthropic {
            url = URL(string: "https://api.anthropic.com/v1/messages")!
            let parts: [JSONBody] = [.object(["type":.string("text"),"text":.string(prompt)])] + images.map {
                .object(["type":.string("image"),"source":.object(["type":.string("base64"),"media_type":.string($0.mime),"data":.string($0.data.base64EncodedString())])])
            }
            body = ["model":.string(model.model),"system":.string(system),"messages":.array([.object(["role":.string("user"),"content":.array(parts)])]),"max_tokens":.int(1200),"temperature":.double(0.2)]
        } else {
            guard let base = model.provider.openAICompatibleBase else { throw ProviderError.malformedResponse("This provider has no mobile vision transport.") }
            url = base.appendingPathComponent("chat/completions")
            let parts: [JSONBody] = [.object(["type":.string("text"),"text":.string(prompt)])] + images.map {
                .object(["type":.string("image_url"),"image_url":.object(["url":.string("data:\($0.mime);base64,\($0.data.base64EncodedString())")])])
            }
            body = ["model":.string(model.model),"messages":.array([.object(["role":.string("system"),"content":.string(system)]),.object(["role":.string("user"),"content":.array(parts)])]),"max_tokens":.int(1200)]
            body.merge(RequestShaping.samplingBody(provider:model.provider,model:model.model,temperature:0.2)) { _,new in new }
            body.merge(RequestShaping.routingBody(provider:model.provider)) { _,new in new }
        }
        var request = URLRequest(url:url); request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        for (name,value) in model.provider.authHeaders(key:key) { request.setValue(value,forHTTPHeaderField:name) }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }
    public func complete(model: ModelRef, system: String, prompt: String, images: [Image]) async throws -> String {
        guard let key = keyProvider(model.provider), !key.isEmpty else { throw ProviderError.missingKey(model.provider) }
        let request = try Self.request(model:model,system:system,prompt:prompt,images:images,key:key)
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse("no HTTP response") }
        guard (200...299).contains(http.statusCode) else { throw ProviderError.http(status:http.statusCode,provider:model.provider,message:nil) }
        return try Self.response(data,model:model)
    }
    public static func response(_ data: Data, model: ModelRef) throws -> String {
        guard let value = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw ProviderError.malformedResponse("database vision response") }
        if model.provider == .anthropic {
            if value["stop_reason"] as? String == "max_tokens" { throw ProviderError.truncated(model:model.model) }
            guard let blocks = value["content"] as? [[String:Any]], blocks.contains(where: {$0["type"] as? String == "text"}) else { throw ProviderError.malformedResponse("database vision text missing") }
            return blocks.filter {$0["type"] as? String == "text"}.compactMap {$0["text"] as? String}.joined()
        }
        guard let choice = (value["choices"] as? [[String:Any]])?.first else { throw ProviderError.malformedResponse("database vision choice missing") }
        if choice["finish_reason"] as? String == "length" { throw ProviderError.truncated(model:model.model) }
        guard let text = (choice["message"] as? [String:Any])?["content"] as? String else { throw ProviderError.malformedResponse("database vision text missing") }
        return text
    }
}
