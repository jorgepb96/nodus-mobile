import Foundation
@preconcurrency import Network

/// Serves only bundled presentation assets on loopback. WKWebView file origins cannot
/// run the shared graph's workers. Vault data and credentials never enter this server.
@MainActor
final class LocalSurfaceHost {
    func owns(_ url: URL) -> Bool { url.scheme == origin?.scheme && url.host == origin?.host && url.port == origin?.port && url.path == "/index.html" }
    static let shared = LocalSurfaceHost()
    private let queue = DispatchQueue(label: "nodus.local-surfaces")
    private var listener: NWListener?
    private var origin: URL?
    private var waiters: [CheckedContinuation<URL, any Error>] = []

    func documentURL() async throws -> URL {
        if let origin { return origin.appendingPathComponent("index.html") }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let server = try NWListener(using: parameters)
                listener = server
                server.stateUpdateHandler = { state in
                    Task { @MainActor in
                        switch state {
                        case .ready:
                            guard let port = server.port, let url = URL(string: "http://127.0.0.1:\(port.rawValue)") else { return }
                            self.origin = url
                            self.finish(.success(url.appendingPathComponent("index.html")))
                        case .failed(let error): self.listener = nil; self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                server.newConnectionHandler = { connection in
                    connection.start(queue: self.queue)
                    self.receive(connection, buffer: Data())
                }
                server.start(queue: queue)
            } catch { listener = nil; finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<URL, any Error>) {
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }
    nonisolated private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, complete, error in
            var request = buffer; if let data { request.append(data) }
            guard request.count <= 16_384, error == nil else { connection.cancel(); return }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                Task { @MainActor in self.respond(connection, request: request) }
            } else if complete { connection.cancel() }
            else { self.receive(connection, buffer: request) }
        }
    }
    private func respond(_ connection: NWConnection, request: Data) {
        let line = String(decoding: request, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let components = line.split(separator: " ")
        let method = components.first.map(String.init) ?? ""
        let file = components.count == 3 ? String(components[1]) : ""
        let allowed: [String: String] = ["/index.html": "text/html; charset=utf-8", "/surface.css": "text/css; charset=utf-8",
            "/surface.iife.js": "text/javascript; charset=utf-8"]
        let resource = Bundle.main.resourceURL?.appendingPathComponent("SharedDesktop").appendingPathComponent(String(file.dropFirst()))
        var bytes = ["GET", "HEAD"].contains(method) && allowed[file] != nil ? resource.flatMap { try? Data(contentsOf: $0) } : nil
        if file == "/index.html", let raw = bytes {
            if var html = String(data: raw, encoding: .utf8), let end = html.range(of: "</body>", options: [.backwards, .caseInsensitive]) {
                html.insert(contentsOf: "<script src=\"./surface.iife.js\"></script>", at: end.lowerBound)
                bytes = Data(html.utf8)
            } else { bytes = nil }
        }
        let data = bytes ?? Data()
        let headers = "HTTP/1.1 \(bytes == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(allowed[file] ?? "text/plain")\r\nContent-Length: \(data.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var response = Data(headers.utf8); if method != "HEAD" { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
