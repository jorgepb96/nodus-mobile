import Foundation

/// Lists what a provider actually offers, rather than shipping a table that goes stale.
///
/// The desktop asks each provider's own endpoint (`electron/ai/providers.ts:237-268`) and so
/// does this — a hard-coded catalogue is wrong the week after it ships, and the user is the
/// one who finds out.
public actor ModelCatalogue {
    private let session: URLSession
    private let keyProvider: @Sendable (AIProvider) -> String?
    private var cached: [AIProvider: [String]] = [:]
    private var cachedImages: [AIProvider: [String]] = [:]
    /// Gemini's list, before either filter. Kept whole because the chat picker and the image
    /// picker want different rows of the same answer, and asking Google twice for it is a
    /// request nobody needed.
    private var cachedGemini: [GeminiModel]?

    public init(
        session: URLSession = .providerDefault,
        keyProvider: @escaping @Sendable (AIProvider) -> String?
    ) {
        self.session = session
        self.keyProvider = keyProvider
    }

    public func models(for provider: AIProvider) async throws -> [String] {
        if let cached = cached[provider] { return cached }

        let ids: [String]
        switch provider {
        case .gemini:
            // Gemini's native list is richer than its OpenAI-compatible one, and only it says
            // which models can actually generate content.
            ids = try await geminiCatalogue()
                .filter { $0.methods.contains("generateContent") }
                .map(\.id)
        default:
            ids = try await openAICompatibleModels(provider)
        }

        let sorted = ids.sorted()
        cached[provider] = sorted
        return sorted
    }

    /// The models this provider can actually draw with.
    ///
    /// Not a filter over `models(for:)`, because for two of the three that would be filtering
    /// the wrong list. OpenRouter publishes image models on their own endpoint and marks them
    /// by output modality rather than by name. Gemini's chat list cannot contain Imagen by
    /// construction: Imagen answers `predict`, not `generateContent`, so it is excluded before
    /// any name-based filter could see it.
    public func imageModels(for provider: AIProvider) async throws -> [String] {
        if let cached = cachedImages[provider] { return cached }
        guard provider.supportsImageGeneration else { return [] }

        let ids: [String]
        switch provider {
        case .openrouter:
            ids = try await openRouterImageModels()
        case .gemini:
            // `predict` is Imagen; `generateContent` covers the Gemini models that answer with
            // a picture. Both lists still go through the name filter, or every chat model in
            // the catalogue would arrive as an image model.
            ids = try await geminiCatalogue()
                .filter { $0.methods.contains("generateContent") || $0.methods.contains("predict") }
                .map(\.id)
                .filter(RequestShaping.isImageModel)
        default:
            ids = try await openAICompatibleModels(provider).filter(RequestShaping.isImageModel)
        }

        let sorted = ids.sorted()
        cachedImages[provider] = sorted
        return sorted
    }

    public func invalidate() {
        cached.removeAll()
        cachedImages.removeAll()
        cachedGemini = nil
    }

    private func openAICompatibleModels(_ provider: AIProvider) async throws -> [String] {
        guard let base = provider.openAICompatibleBase else {
            // Anthropic publishes a list at its own root, not under an OpenAI-shaped base.
            if provider == .anthropic { return try await anthropicModels() }
            throw ProviderError.malformedResponse("\(provider.rawValue) has no model list")
        }
        guard let key = keyProvider(provider) else { throw ProviderError.missingKey(provider) }

        var request = URLRequest(url: base.appendingPathComponent("models"))
        for (name, value) in provider.authHeaders(key: key) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data = try await fetch(request, provider: provider)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["data"] as? [[String: Any]]
        else { throw ProviderError.malformedResponse("no model list in the response") }
        return entries.compactMap { $0["id"] as? String }
    }

    private func anthropicModels() async throws -> [String] {
        guard let key = keyProvider(.anthropic) else { throw ProviderError.missingKey(.anthropic) }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1000")!)
        for (name, value) in AIProvider.anthropic.authHeaders(key: key) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data = try await fetch(request, provider: .anthropic)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["data"] as? [[String: Any]]
        else { throw ProviderError.malformedResponse("no model list in the response") }
        return entries.compactMap { $0["id"] as? String }
    }

    /// One row of Google's catalogue: what it is called and what it will answer.
    struct GeminiModel: Sendable, Hashable {
        let id: String
        let methods: [String]
    }

    private func geminiCatalogue() async throws -> [GeminiModel] {
        if let cachedGemini { return cachedGemini }
        guard let key = keyProvider(.gemini) else { throw ProviderError.missingKey(.gemini) }
        // `x-goog-api-key`, never `?key=`.
        //
        // Google's own examples put the key in the query string and the desktop follows them,
        // but a URL is the least private place to carry a secret: it lands in URLCache, in
        // proxy and server access logs, and in `NSURLErrorFailingURLStringErrorKey` on any
        // failure — which is exactly where a crash reporter would pick it up. The header is
        // equally supported and none of that happens.
        var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let data = try await fetch(request, provider: .gemini)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["models"] as? [[String: Any]]
        else { throw ProviderError.malformedResponse("no model list in the response") }

        let models = entries.compactMap { entry -> GeminiModel? in
            guard let name = entry["name"] as? String else { return nil }
            return GeminiModel(
                id: name.replacingOccurrences(of: "models/", with: ""),
                methods: entry["supportedGenerationMethods"] as? [String] ?? []
            )
        }
        cachedGemini = models
        return models
    }

    /// OpenRouter is the one provider that states outright what a model can emit, so it is
    /// asked rather than guessed at — the same two endpoints the desktop reads
    /// (`electron/ai/imageModels.ts:121-127`).
    ///
    /// The dedicated endpoint first, the filtered general list as a fallback: they answer the
    /// same question, and a picker that shows nothing because one of them changed shape is a
    /// worse failure than one extra request on a path that rarely runs.
    private func openRouterImageModels() async throws -> [String] {
        if let ids = try? await openRouterModels(at: "https://openrouter.ai/api/v1/images/models"),
           !ids.isEmpty {
            return ids
        }
        return try await openRouterModels(at: "https://openrouter.ai/api/v1/models?output_modalities=image")
    }

    private func openRouterModels(at address: String) async throws -> [String] {
        guard let key = keyProvider(.openrouter) else { throw ProviderError.missingKey(.openrouter) }
        guard let url = URL(string: address) else {
            throw ProviderError.malformedResponse("bad OpenRouter URL")
        }

        var request = URLRequest(url: url)
        for (name, value) in AIProvider.openrouter.authHeaders(key: key) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let data = try await fetch(request, provider: .openrouter)
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = object["data"] as? [[String: Any]]
        else { throw ProviderError.malformedResponse("no model list in the response") }

        // The modality is asserted here rather than trusted to the endpoint or the query
        // parameter: if either ever stops filtering, this returns nothing instead of returning
        // the whole text catalogue dressed as image models.
        return entries.compactMap { entry -> String? in
            guard let id = entry["id"] as? String else { return nil }
            let architecture = entry["architecture"] as? [String: Any]
            let modalities = architecture?["output_modalities"] as? [String] ?? []
            return modalities.contains("image") ? id : nil
        }
    }

    private func fetch(_ request: URLRequest, provider: AIProvider) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("no HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ProviderError.http(
                status: http.statusCode,
                provider: provider,
                message: ProviderClient.errorMessage(from: String(data: data, encoding: .utf8) ?? "")
            )
        }
        return data
    }
}
