import Foundation
import NodusKit
import WebKit

/// Payloads are WebKit arguments, never JavaScript source. No retries or ID rewriting.
@MainActor enum MobileJavaScriptDelivery {
    static let replyBody = "window.nodusMobileReply(...envelope); return null;"
    static let eventBody = "for (const event of batch) window.nodusMobileEvent(event); return null;"
    static let optionalEventBody = "for (const event of batch) window.nodusMobileEvent?.(event); return null;"

    static func replyArguments(_ envelope: JSONValue) throws -> [String: Any] {
        // Keep the existing Codable JSON representation (including null/error shapes).
        let data = try JSONEncoder.nodus.encode(envelope)
        return ["envelope": try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])]
    }
    static func reply(_ view: WKWebView?, envelope: JSONValue) throws {
        let arguments = try replyArguments(envelope)
        view?.callAsyncJavaScript(replyBody, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }
    static func events(_ view: WKWebView?, payload: Any, optional: Bool) throws {
        // Public WebKit supports NSDictionary/NSArray/NSString/NSNumber/NSNull.
        // Validation does not re-encode the payload or increase existing RPC/event limits.
        guard let batch = payload as? [[String: Any]], JSONSerialization.isValidJSONObject(batch) else {
            throw DesktopBridgeError.malformedResponse
        }
        view?.callAsyncJavaScript(optional ? optionalEventBody : eventBody,
            arguments: ["batch": batch], in: nil, in: .page, completionHandler: nil)
    }
}
