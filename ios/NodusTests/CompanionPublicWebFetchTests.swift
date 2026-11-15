import Foundation
import Testing
@testable import Nodus

@Suite("Public device research HTTP framing")
struct CompanionPublicWebFetchTests {
    let url = URL(string: "https://example.org/article")!
    @Test("Private, loopback, mapped and reserved DNS answers are refused")
    func addresses() {
        for value in ["127.0.0.1", "10.1.2.3", "192.168.1.2", "172.17.1.1", "169.254.2.1", "100.64.0.1", "::1", "fc00::1", "fe80::1", "::ffff:127.0.0.1", "2001:db8::1", "2002:7f00:1::"] { #expect(!CompanionPublicWebFetch.publicAddress(value)) }
        for value in ["1.1.1.1", "8.8.8.8", "2001:4860:4860::8888"] { #expect(CompanionPublicWebFetch.publicAddress(value)) }
        for value in ["http://example.org/", "https://localhost/", "https://service.local/", "https://user:password@example.org/", "https://example.org:8443/"] { #expect(!CompanionPublicWebFetch.allowed(URL(string: value)!)) }
    }
    @Test("Content-Length completes without waiting for EOF")
    func length() throws {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhell".utf8)
        #expect(try !CompanionPublicWebFetch.completeMessage(partial, limit: 20))
        var full = partial; full.append(111)
        #expect(try CompanionPublicWebFetch.completeMessage(full, limit: 20))
        #expect(try CompanionPublicWebFetch.decode(full, url: url, limit: 20).data == Data("hello".utf8))
    }
    @Test("Chunked completion requires its terminal frame and preserves exact bytes")
    func chunked() throws {
        let prefix = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"
        #expect(try !CompanionPublicWebFetch.completeMessage(Data(prefix.utf8), limit: 20))
        let full = Data((prefix + "0\r\n\r\n").utf8)
        #expect(try CompanionPublicWebFetch.completeMessage(full, limit: 20))
        #expect(try CompanionPublicWebFetch.decode(full, url: url, limit: 20).data == Data("hello".utf8))
        #expect(throws: URLError.self) { try CompanionPublicWebFetch.decode(Data((prefix + "0\r\n").utf8), url: url, limit: 20) }
    }
    @Test("Conflicting framing, oversized bodies and compression fail closed")
    func invalid() {
        for value in ["HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na", "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\na", "HTTP/1.1 200 OK\r\nContent-Length: 50\r\n\r\na"] { #expect(throws: URLError.self) { try CompanionPublicWebFetch.completeMessage(Data(value.utf8), limit: 20) } }
        #expect(throws: URLError.self) { try CompanionPublicWebFetch.decode(Data("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nbytes".utf8), url: url, limit: 20) }
    }
    @Test("A redirect can finish at headers before a keepalive server closes")
    func redirect() throws {
        let bytes = Data("HTTP/1.1 302 Found\r\nLocation: https://example.org/next\r\nContent-Length: 500\r\n\r\n".utf8)
        #expect(try CompanionPublicWebFetch.completeMessage(bytes, limit: 1000))
        #expect(try CompanionPublicWebFetch.decode(bytes, url: url, limit: 1000).headers["location"] == "https://example.org/next")
    }
}
