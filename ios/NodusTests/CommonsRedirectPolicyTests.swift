import Foundation
import Testing
@testable import Nodus

@Suite("Commons redirect decisions")
@MainActor
struct CommonsRedirectPolicyTests {
    @Test("Allowed redirects complete once and preserve the exact request")
    func allowedRequests() throws {
        for address in ["https://commons.wikimedia.org/w/api.php", "https://upload.wikimedia.org:443/example.png"] {
            var request = URLRequest(url: try #require(URL(string: address)), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 19)
            request.httpMethod = "POST"
            request.httpBody = Data("fixture body".utf8)
            request.setValue("image/png", forHTTPHeaderField: "Accept")
            request.setValue("fixture-only", forHTTPHeaderField: "X-Fixture")
            #expect(try decision(request) == request)
        }
    }

    @Test("Every redirect retains the HTTPS, host, port and URL credential restrictions")
    func rejectedRequests() throws {
        for address in [
            "http://commons.wikimedia.org/w/api.php",
            "https://example.org/example.png",
            "https://upload.wikimedia.org.example.org/example.png",
            "https://sub.commons.wikimedia.org/w/api.php",
            "https://upload.wikimedia.org:8443/example.png",
            "https://user@commons.wikimedia.org/w/api.php",
            "https://user:password@upload.wikimedia.org/example.png",
        ] {
            let request = URLRequest(url: try #require(URL(string: address)))
            #expect(try decision(request) == nil)
        }
        var missingURL = URLRequest(url: try #require(URL(string: "https://upload.wikimedia.org/example.png")))
        missingURL.url = nil
        #expect(try decision(missingURL) == nil)
    }

    private func decision(_ request: URLRequest) throws -> URLRequest? {
        let original = try #require(URL(string: "https://commons.wikimedia.org/w/api.php"))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        // The task is never resumed: invoke the delegate directly without a socket.
        let task = session.dataTask(with: original)
        let response = try #require(HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil))
        var count = 0
        var result: URLRequest?
        CommonsRedirectPolicy().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { value in
            count += 1
            result = value
        }
        #expect(count == 1)
        return result
    }
}
