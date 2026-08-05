import Foundation

/// Everything the app says to one Nodus Server.
///
/// It is an actor because the token can be replaced under it — a 401 mid-flight has to
/// invalidate the credential exactly once, not once per in-flight request — and because the
/// ETag cache must not be read and written concurrently for the same key.
///
/// The cross-cutting rules live in `perform` and nowhere else:
///
/// - `If-None-Match` on every GET that has a cached tag, and a 304 served from disk.
/// - 401 clears the credential and surfaces as `APIError.isUnauthorized`. It never means "the
///   token is invalid" in general: a token scoped to another space also answers 401, on
///   purpose, so membership cannot be probed by status code.
/// - 409 `not_published` is passed through as an error but flagged, because it is an empty
///   state and every screen has to be able to tell the two apart.
/// - 429 is retried once after the server's own `Retry-After`. Semantic search allows 30
///   requests a minute and a user typing in a search field will hit that without help.
public actor NodusClient {
    public let address: ServerAddress
    private let session: URLSession
    private let cache: ResponseCache
    private var bearerToken: String?
    /// Raised when the server answers 401, so the app can drop the stored credential once
    /// rather than every screen discovering it separately.
    private var onUnauthorized: (@Sendable () async -> Void)?
    /// A corpus held on this device that answers instead of a server.
    ///
    /// Set only for the example vault the app carries in its bundle. Every screen in the app
    /// reads through this client, so a demo that opened no socket had to be either a second
    /// `SpaceSession` — two of everything, drifting apart — or a client that answers from the
    /// device. It is the second, and the seam is the first four lines of `perform`.
    private let local: LocalCorpus?

    public init(
        address: ServerAddress,
        token: String? = nil,
        session: URLSession = .nodusDefault,
        cache: ResponseCache
    ) {
        self.address = address
        self.bearerToken = token
        self.session = session
        self.cache = cache
        self.local = nil
    }

    /// A client for a corpus that lives on this device and nowhere else.
    ///
    /// It holds no token and no session because it needs neither: nothing it is asked for
    /// leaves the process. The address is a name for the space, not a place — `perform`
    /// returns before it is ever resolved — and it is what the routes are built from, so the
    /// paths this answers are the paths a real server would have been asked for.
    public init(local: LocalCorpus, address: ServerAddress, cache: ResponseCache) {
        self.address = address
        self.bearerToken = nil
        self.session = .nodusProbe
        self.cache = cache
        self.local = local
    }

    public func setToken(_ token: String?) {
        bearerToken = token
    }

    public func setUnauthorizedHandler(_ handler: (@Sendable () async -> Void)?) {
        onUnauthorized = handler
    }

    public var hasToken: Bool { bearerToken != nil }

    // MARK: - Transport

    struct Request: Sendable {
        var method: String = "GET"
        var path: String
        var query: [URLQueryItem] = []
        var body: Data?
        var contentType: String?
        var extraHeaders: [String: String] = [:]
        /// Unauthenticated endpoints — `/capabilities`, `/auth/login`, `/healthz` — must not
        /// send a stale token, or a server that has revoked it answers 401 to a public route.
        var authenticated: Bool = true
        /// Only GETs revalidate; a POST has no tag to send.
        var cacheable: Bool = false
        /// Overrides the session's 30 s default.
        ///
        /// A probe is asking "is there a Nodus Server at this address?", and the answer "no" is
        /// most often silence — a name that resolves to a machine with nothing listening on the
        /// port. Half a minute of a dead button is not a reasonable way to say that.
        var timeout: TimeInterval?
    }

    struct Response: Sendable {
        let data: Data
        let status: Int
        let headers: [String: String]
        /// True when the server answered 304 and this body came from disk.
        let fromCache: Bool
        var etag: String? { headers["etag"] }
        var revision: String? { headers["x-nodus-revision"] }
    }

    func perform(_ request: Request, allowRetry: Bool = true) async throws -> Response {
        // Before the URL is even built. A local corpus is not a cache in front of a server and
        // must never fall through to one: the example vault has no server behind it, and a
        // request it cannot answer is a 404 from this device rather than a socket left open in
        // aeroplane mode.
        if let local {
            return try await local.answer(request)
        }

        let url = try address.url(path: request.path, query: request.query)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        if let timeout = request.timeout { urlRequest.timeoutInterval = timeout }
        urlRequest.httpBody = request.body
        if let contentType = request.contentType {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if request.authenticated, let bearerToken {
            urlRequest.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in request.extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        // The server compresses nothing by default and the snapshot arrives pre-gzipped, so
        // URLSession's automatic decoding must not be asked to touch it.
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let cacheKey = ResponseCache.key(
            origin: address.origin,
            method: request.method,
            path: request.path,
            query: url.query
        )
        var cachedEntry: ResponseCache.Entry?
        if request.cacheable {
            cachedEntry = await cache.entry(for: cacheKey)
            if let cachedEntry {
                urlRequest.setValue(cachedEntry.etag, forHTTPHeaderField: "If-None-Match")
            }
        }

        let data: Data
        let httpResponse: HTTPURLResponse
        do {
            let (responseData, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.malformedResponse(expected: "an HTTP response")
            }
            data = responseData
            httpResponse = http
        } catch let error as URLError {
            throw TransportError.from(error)
        }

        var headers: [String: String] = [:]
        for (name, value) in httpResponse.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }

        switch httpResponse.statusCode {
        case 304:
            guard let cachedEntry else {
                // The server revalidated against a tag we no longer hold. Ask again without
                // one rather than returning an empty body as if it were data.
                var retry = request
                retry.cacheable = false
                return try await perform(retry, allowRetry: allowRetry)
            }
            await cache.touch(cacheKey)
            return Response(data: cachedEntry.data, status: 200, headers: headers, fromCache: true)

        case 200...299:
            if request.cacheable, let etag = headers["etag"] {
                await cache.store(
                    .init(etag: etag, data: data, storedAt: Date(), revision: headers["x-nodus-revision"]),
                    for: cacheKey
                )
            }
            return Response(data: data, status: httpResponse.statusCode, headers: headers, fromCache: false)

        case 401:
            bearerToken = nil
            if let onUnauthorized { await onUnauthorized() }
            throw APIError.decode(status: 401, data: data, headers: httpResponse.allHeaderFields)

        case 429 where allowRetry:
            let error = APIError.decode(status: 429, data: data, headers: httpResponse.allHeaderFields)
            // Honour the server's own number, but never sleep so long that a search field
            // feels broken; past that the caller is told to try again.
            let delay = min(error.retryAfter ?? 2, 8)
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            return try await perform(request, allowRetry: false)

        default:
            throw APIError.decode(status: httpResponse.statusCode, data: data, headers: httpResponse.allHeaderFields)
        }
    }

    func object(from response: Response) throws -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode([String: JSONValue].self, from: response.data) else {
            throw TransportError.malformedResponse(expected: "a JSON object")
        }
        return value
    }
}

public extension URLSession {
    /// The session the app talks to a Nodus Server with.
    ///
    /// `URLCache` is disabled on purpose: revalidation is handled explicitly by
    /// `ResponseCache` so a 304 is observable, and two caches over one connection would
    /// disagree about what "fresh" means.
    static let nodusDefault: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        // A Deep Research run's own model calls do not go through here, but a snapshot of a
        // large corpus does, and it is worth waiting for.
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        configuration.httpAdditionalHeaders = ["User-Agent": "Nodus-iOS/3.2.0"]
        return URLSession(configuration: configuration)
    }()

    /// The session for the first knock at an address somebody just typed.
    ///
    /// `nodusDefault` sets `waitsForConnectivity`, which is right for an app that is already
    /// talking to a server it knows: a tunnel coming back up resumes the request instead of
    /// failing it. It is wrong here, and quietly so — while URLSession is *waiting for
    /// connectivity* it ignores `timeoutIntervalForRequest` entirely, so a 12-second timeout on
    /// an unreachable host bought nothing and the screen sat on "looking for the server" until
    /// `timeoutIntervalForResource` gave up ten minutes later.
    ///
    /// A probe has to be able to answer "there is nothing here", so it does not wait.
    static let nodusProbe = URLSession(configuration: .nodusProbe)
}

public extension URLSessionConfiguration {
    /// What a probe session is configured with, apart from who watches it.
    ///
    /// Shared by `URLSession.nodusProbe` and by the diagnostics session that carries a
    /// certificate inspector, because two copies of these five lines is two places for the one
    /// setting that matters — `waitsForConnectivity` — to be turned back on by accident.
    static var nodusProbe: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        // Bounded as well as the request: the two are different clocks, and only this one caps
        // the whole attempt.
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Nodus-iOS/3.2.0"]
        return configuration
    }
}
