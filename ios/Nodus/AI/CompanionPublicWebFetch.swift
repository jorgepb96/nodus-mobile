import Foundation
import Network
import Security
import Darwin

/// A cookie-free public GET. DNS answers are checked, then the connection uses
/// that exact address while TLS keeps the original host name for SNI/trust.
/// Redirects are new checked requests; URLSession cannot silently resolve again.
nonisolated enum CompanionPublicWebFetch {
    struct Response: Sendable { let url: URL; let status: Int; let headers: [String: String]; let data: Data }
    static func fetch(_ raw: String, limit: Int = 3 * 1_048_576) async throws -> Response {
        guard (1...12 * 1_048_576).contains(limit), let url = URL(string: raw) else { throw URLError(.badURL) }
        var current = url
        for _ in 0..<6 {
            guard allowed(current), let host = current.host else { throw URLError(.unsupportedURL) }
            let addresses = try await PublicDNSLookup(host: host).run()
            guard !addresses.isEmpty, addresses.allSatisfy(publicAddress) else { throw URLError(.cannotFindHost) }
            let result = try await request(current, address: addresses[0], limit: limit)
            if [301, 302, 303, 307, 308].contains(result.status) {
                guard let location = result.headers["location"], let next = URL(string: location, relativeTo: current)?.absoluteURL else { throw URLError(.redirectToNonExistentLocation) }
                current = next; continue
            }
            return result
        }
        throw URLError(.httpTooManyRedirects)
    }
    nonisolated static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.isEmpty, !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), host != "localhost" else { return false }
        return true
    }
    nonisolated static func publicAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            let n = UInt32(bigEndian: v4.s_addr), a = n >> 24, b = (n >> 16) & 255
            if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) || (a == 172 && (16...31).contains(b)) || (a == 192 && [0, 168].contains(b)) || (a == 198 && [18, 19, 51].contains(b)) || (a == 203 && b == 0) { return false }
            return true
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return bytes[0] & 0xe0 == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x02) && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 2) && !(bytes[0...3].elementsEqual([0x20, 0x01, 0x0d, 0xb8]))
    }
    nonisolated fileprivate static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &head) == 0, let first = head else { throw URLError(.cannotFindHost) }
        defer { freeaddrinfo(first) }
        var result: [String] = [], pointer: UnsafeMutablePointer<addrinfo>? = first
        while let item = pointer {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(item.pointee.ai_addr, item.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 { result.append(String(cString: name)) }
            pointer = item.pointee.ai_next
        }
        return Array(Set(result)).sorted()
    }
    private static func request(_ url: URL, address: String, limit: Int) async throws -> Response {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, url.host!)
        let parameters = NWParameters(tls: tls)
        let connection = NWConnection(host: .init(address), port: 443, using: parameters)
        let state = PublicHTTPExchange(connection: connection, url: url, limit: limit)
        return try await withTaskCancellationHandler { try await state.run() } onCancel: { state.cancel() }
    }
    nonisolated static func completeMessage(_ bytes: Data, limit: Int) throws -> Bool {
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > 65_536 { throw URLError(.badServerResponse) }; return false
        }
        guard boundary.lowerBound <= 65_536, let text = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = text.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        if status.map({ [301, 302, 303, 307, 308].contains($0) }) == true { return true }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw URLError(.badServerResponse) }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil || !["content-length", "transfer-encoding"].contains(key) else { throw URLError(.badServerResponse) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(bytes[boundary.upperBound...])
        if let rawLength = headers["content-length"] {
            guard headers["transfer-encoding"] == nil, let length = Int(rawLength), (0...limit).contains(length), body.count <= length else { throw URLError(.badServerResponse) }
            return body.count == length
        }
        guard let transfer = headers["transfer-encoding"] else { return false }
        guard transfer.lowercased() == "chunked" else { throw URLError(.badServerResponse) }
        var decoded = 0
        while true {
            guard let end = body.range(of: Data("\r\n".utf8)) else { return false }
            guard let line = String(data: body[..<end.lowerBound], encoding: .utf8), let size = line.split(separator: ";").first.flatMap({ Int($0, radix: 16) }), size >= 0, size <= limit - decoded else { throw URLError(.badServerResponse) }
            body = Data(body[end.upperBound...])
            if size == 0 { return body.starts(with: Data("\r\n".utf8)) || body.range(of: Data("\r\n\r\n".utf8)) != nil }
            guard body.count >= size + 2 else { return false }
            guard body[size] == 13, body[size + 1] == 10 else { throw URLError(.badServerResponse) }
            decoded += size; body = Data(body.dropFirst(size + 2))
        }
    }
    /// Strict HTTP/1 response framing, including chunked bodies. No decompression
    /// or unbounded decoder allocation is accepted behind a small Content-Length.
    nonisolated static func decode(_ bytes: Data, url: URL, limit: Int) throws -> Response {
        guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)), boundary.lowerBound <= 65_536,
              let header = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = header.components(separatedBy: "\r\n")
        guard let status = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw URLError(.badServerResponse) }
            let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[key] != nil, ["content-length", "transfer-encoding", "location"].contains(key) { throw URLError(.badServerResponse) }
            headers[key] = value
        }
        guard headers["content-encoding"] == nil || headers["content-encoding"] == "identity" else { throw URLError(.cannotDecodeContentData) }
        if [301, 302, 303, 307, 308].contains(status) { return Response(url: url, status: status, headers: headers, data: Data()) }
        var body = Data(bytes[boundary.upperBound...])
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else { throw URLError(.badServerResponse) }
            var decoded = Data()
            while true {
                guard let end = body.range(of: Data("\r\n".utf8)), let line = String(data: body[..<end.lowerBound], encoding: .utf8), let size = line.split(separator: ";").first.flatMap({ Int($0, radix: 16) }), size >= 0, size <= limit - decoded.count else { throw URLError(.badServerResponse) }
                body = Data(body[end.upperBound...]); if size == 0 {
                    guard body.starts(with: Data("\r\n".utf8)) || body.range(of: Data("\r\n\r\n".utf8)) != nil else { throw URLError(.badServerResponse) }; break
                }
                guard body.count >= size + 2, body[size] == 13, body[size + 1] == 10 else { throw URLError(.badServerResponse) }
                decoded.append(body.prefix(size)); body = Data(body.dropFirst(size + 2))
            }
            body = decoded
        } else if let length = headers["content-length"] {
            guard let count = Int(length), count >= 0, count == body.count else { throw URLError(.badServerResponse) }
        }
        guard body.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return Response(url: url, status: status, headers: headers, data: body)
    }
}

/// All mutable transport state is confined to one serial queue.
private nonisolated final class PublicHTTPExchange: @unchecked Sendable {
    let queue = DispatchQueue(label: "nodus.public-web-get")
    let connection: NWConnection; let url: URL; let limit: Int
    var continuation: CheckedContinuation<CompanionPublicWebFetch.Response, Error>?
    var bytes = Data(); var ended = false
    init(connection: NWConnection, url: URL, limit: Int) { self.connection = connection; self.url = url; self.limit = limit }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    func run() async throws -> CompanionPublicWebFetch.Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard !self.ended else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        let components = URLComponents(url: self.url, resolvingAgainstBaseURL: false)
                        var target = components?.percentEncodedPath.isEmpty == false ? components!.percentEncodedPath : "/"
                        if let query = components?.percentEncodedQuery { target += "?" + query }
                        guard !target.contains("\r"), !target.contains("\n") else { self.finish(.failure(URLError(.badURL))); return }
                        let request = "GET \(target) HTTP/1.1\r\nHost: \(self.url.host!)\r\nAccept: text/html,text/plain,application/json,application/pdf\r\nAccept-Encoding: identity\r\nConnection: close\r\nUser-Agent: Nodus-Research-Mobile/0.1\r\n\r\n"
                        self.connection.send(content: Data(request.utf8), completion: .contentProcessed { error in if let error { self.finish(.failure(error)) } else { self.receive() } })
                    case .failed(let error): self.finish(.failure(error))
                    case .cancelled: self.finish(.failure(CancellationError()))
                    default: break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 20) { self.finish(.failure(URLError(.timedOut))) }
            }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { data, _, complete, error in
            if let data { self.bytes.append(data) }
            guard self.bytes.count <= self.limit + 65_536 else { self.finish(.failure(URLError(.dataLengthExceedsMaximum))); return }
            if let error { self.finish(.failure(error)); return }
            do {
                let framed = try CompanionPublicWebFetch.completeMessage(self.bytes, limit: self.limit)
                if complete || framed {
                    self.finish(Result { try CompanionPublicWebFetch.decode(self.bytes, url: self.url, limit: self.limit) })
                } else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<CompanionPublicWebFetch.Response, Error>) {
        guard !ended else { return }; ended = true
        connection.stateUpdateHandler = nil; connection.cancel()
        continuation?.resume(with: result); continuation = nil
    }
}

/// An OS resolver may finish late, but its answer cannot open a connection after
/// this request times out or is cancelled. The caller never waits indefinitely.
private nonisolated final class PublicDNSLookup: @unchecked Sendable {
    let host: String
    private let lock = NSLock()
    private var ended = false
    private var continuation: CheckedContinuation<[String], Error>?
    init(host: String) { self.host = host }
    func run() async throws -> [String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if ended { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation; lock.unlock()
                DispatchQueue.global(qos: .utility).async { self.finish(Result { try CompanionPublicWebFetch.resolve(self.host) }) }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { self.finish(.failure(URLError(.timedOut))) }
            }
        } onCancel: { self.finish(.failure(CancellationError())) }
    }
    private func finish(_ result: Result<[String], Error>) {
        lock.lock()
        guard !ended else { lock.unlock(); return }; ended = true
        let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
    }
}
