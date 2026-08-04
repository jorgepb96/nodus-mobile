import Foundation
import NodusKit

/// Bytes and the type they are, which is all a caller needs to store or show a picture.
public struct GeneratedImage: Sendable, Hashable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }

    /// What to call the file. Sniffed from the bytes rather than trusted from the header,
    /// because more than one provider answers `image/jpeg` and sends a PNG.
    public var fileExtension: String {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
        if data.count > 12, data[8..<12].elementsEqual([0x57, 0x45, 0x42, 0x50]) { return "webp" }
        return mimeType.hasSuffix("png") ? "png" : "jpg"
    }
}

/// Turns a prompt into a picture, with whichever of the three drawing providers holds a key.
///
/// A port of `callImageProvider` (`electron/ai/decorativeImages.ts:250-278`) minus the two
/// providers a phone cannot reach: the desktop's local diffusion model and Codex's tool behind a
/// ChatGPT subscription. The three that remain are the three `AIProvider.imageCapable` names, so
/// the picker and this cannot disagree about what will draw.
public actor ImageService {
    private let session: URLSession
    private let keyProvider: @Sendable (AIProvider) -> String?

    /// Two minutes, the desktop's own `IMAGE_TIMEOUT_MS`. An image model is slow in a way a chat
    /// model is not, and the default sixty seconds cancelled runs that were about to succeed.
    public static let timeout: TimeInterval = 120

    public init(
        session: URLSession = .providerDefault,
        keyProvider: @escaping @Sendable (AIProvider) -> String?
    ) {
        self.session = session
        self.keyProvider = keyProvider
    }

    public func generate(prompt: String, with model: ModelRef) async throws -> GeneratedImage {
        guard model.provider.supportsImageGeneration else {
            throw ProviderError.malformedResponse("\(model.provider.rawValue) cannot generate images")
        }
        guard let key = keyProvider(model.provider) else { throw ProviderError.missingKey(model.provider) }

        switch model.provider {
        case .openai:
            return try await base64Image(
                url: URL(string: "https://api.openai.com/v1/images/generations")!,
                body: [
                    "model": .string(model.model),
                    "prompt": .string(prompt),
                    "n": .int(1),
                    "size": .string("1536x1024"),
                    "quality": .string("high"),
                ],
                provider: .openai,
                key: key
            )
        case .openrouter:
            // The documented common denominator plus one explicit output. Model endpoints here
            // expose different optional knobs, and a provider-specific parameter is how an
            // otherwise compatible model starts refusing the request.
            return try await base64Image(
                url: URL(string: "https://openrouter.ai/api/v1/images")!,
                body: [
                    "model": .string(model.model),
                    "prompt": .string(prompt),
                    "n": .int(1),
                ],
                provider: .openrouter,
                key: key
            )
        case .gemini:
            return try await gemini(prompt: prompt, model: model.model, key: key)
        default:
            throw ProviderError.malformedResponse("\(model.provider.rawValue) cannot generate images")
        }
    }

    // MARK: - OpenAI-shaped

    /// `{ data: [{ b64_json }] }`, which OpenAI and OpenRouter both answer with.
    private func base64Image(
        url: URL,
        body: [String: JSONBody],
        provider: AIProvider,
        key: String
    ) async throws -> GeneratedImage {
        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in provider.authHeaders(key: key) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONEncoder().encode(JSONBody.object(body))

        let object = try await json(request, provider: provider)
        guard
            let entries = object["data"] as? [[String: Any]],
            let first = entries.first,
            let encoded = first["b64_json"] as? String ?? first["image"] as? String,
            let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters])
        else {
            throw ProviderError.malformedResponse("\(provider.rawValue) returned no image data")
        }
        return GeneratedImage(data: data, mimeType: first["media_type"] as? String ?? "image/png")
    }

    // MARK: - Google

    /// Two Google endpoints, because Google has two kinds of image model.
    ///
    /// Imagen answers `:predict` and returns `predictions[].bytesBase64Encoded`; the Gemini
    /// models that draw answer `:generateContent` and return the picture as an `inlineData` part
    /// beside whatever text they felt like writing. Which one to call is decided by the model
    /// id, the same way `ModelCatalogue.imageModels` decides which list a model came from.
    private func gemini(prompt: String, model: String, key: String) async throws -> GeneratedImage {
        let isImagen = model.lowercased().contains("imagen")
        let base = "https://generativelanguage.googleapis.com/v1beta/models/\(model)"
        var request = URLRequest(
            url: URL(string: "\(base):\(isImagen ? "predict" : "generateContent")")!,
            timeoutInterval: Self.timeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The header form, not `?key=`: a key in a query string ends up in logs and in the
        // URLSession cache key, and this one belongs to the user.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let body: JSONBody = isImagen
            ? .object([
                "instances": .array([.object(["prompt": .string(prompt)])]),
                "parameters": .object(["sampleCount": .int(1), "aspectRatio": .string("16:9")]),
            ])
            : .object([
                "contents": .array([.object([
                    "role": .string("user"),
                    "parts": .array([.object(["text": .string(prompt)])]),
                ])]),
                "generationConfig": .object(["responseModalities": .array([.string("IMAGE")])]),
            ])
        request.httpBody = try JSONEncoder().encode(body)

        let object = try await json(request, provider: .gemini)
        if isImagen {
            guard
                let predictions = object["predictions"] as? [[String: Any]],
                let encoded = predictions.first?["bytesBase64Encoded"] as? String,
                let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters])
            else { throw ProviderError.malformedResponse("Google returned no image data") }
            return GeneratedImage(
                data: data,
                mimeType: predictions.first?["mimeType"] as? String ?? "image/png"
            )
        }

        guard
            let candidates = object["candidates"] as? [[String: Any]],
            let content = candidates.first?["content"] as? [String: Any],
            let parts = content["parts"] as? [[String: Any]]
        else { throw ProviderError.malformedResponse("Google returned no image data") }

        for part in parts {
            guard
                let inline = part["inlineData"] as? [String: Any] ?? part["inline_data"] as? [String: Any],
                let encoded = inline["data"] as? String,
                let data = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters])
            else { continue }
            return GeneratedImage(data: data, mimeType: inline["mimeType"] as? String ?? "image/png")
        }
        throw ProviderError.malformedResponse("Google returned no image data")
    }

    // MARK: - Transport

    private func json(_ request: URLRequest, provider: AIProvider) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.http(
                status: http.statusCode,
                provider: provider,
                message: ProviderClient.errorMessage(from: String(decoding: data, as: UTF8.self))
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("\(provider.rawValue) did not answer with JSON")
        }
        return object
    }
}
