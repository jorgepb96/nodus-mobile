import Foundation
import NodusKit
import Testing
import WebKit
@testable import Nodus

@Suite("Typed WebKit bridge delivery", .serialized)
@MainActor struct MobileJavaScriptDeliveryTests {
    @Test("real WebKit preserves null, Unicode, structured errors and exact RPC IDs without evaluating payload text")
    func repliesRemainData() async throws {
        let page = Page(); defer { page.close() }; try await page.load()
        let text = "\";window.injected=true;//\n` ${notCode} \u{2028} \u{2029} 🧭"
        let envelope: JSONValue = .array([.string("rpc-exact-0007"), .object(["text": .string(text), "empty": .null, "ok": .bool(true)]), .object(["code": .string("cancelled"), "message": .string("Conservar mensaje exacto")])])
        let arguments = try MobileJavaScriptDelivery.replyArguments(envelope)
        _ = try await page.call(MobileJavaScriptDelivery.replyBody, arguments: arguments)
        let raw = try await page.call("return JSON.stringify(window.reply);", arguments: [:])
        let encoded = try #require(raw as? String)
        let actual = try JSONDecoder.nodus.decode(JSONValue.self, from: Data(encoded.utf8))
        #expect(actual == envelope)
        let injected = try await page.call("return Boolean(window.injected);", arguments: [:])
        #expect(injected as? Bool == false)
    }

    @Test("real WebKit receives large ordered event batches then the final reply with unchanged channel, sequence and request ID")
    func eventsThenReply() async throws {
        let page = Page(); defer { page.close() }; try await page.load()
        let requestID = "stable-request-123", text = String(repeating: "texto 🧭\n", count: 20_000)
        let batch: [[String: Any]] = (1...12).map { sequence in ["sequence": sequence, "channel": sequence == 12 ? "research:chatStream:replace" : "research:chatStream:delta", "args": [requestID, sequence == 12 ? text : "delta-\(sequence)"]] }
        // Exercise the production non-awaiting submission wrappers in the same order.
        try MobileJavaScriptDelivery.events(page.web, payload: batch, optional: false)
        try MobileJavaScriptDelivery.reply(page.web, envelope: .array([.string(requestID), .object(["answer": .string(text)]), .null]))
        let raw = try await page.call("return JSON.stringify({events:window.events,reply:window.reply,order:window.order});", arguments: [:])
        let encoded = try #require(raw as? String)
        let actual = try JSONDecoder.nodus.decode(JSONValue.self, from: Data(encoded.utf8))
        let events = try #require(actual.objectValue?["events"]?.arrayValue)
        #expect(events.count == batch.count)
        #expect(events.compactMap { $0.objectValue?["sequence"]?.intValue } == Array(1...12))
        #expect(events.allSatisfy { $0.objectValue?["args"]?.arrayValue?.first == .string(requestID) })
        #expect(events.last?.objectValue?["args"]?.arrayValue?.last == .string(text))
        #expect(actual.objectValue?["reply"]?.arrayValue == [.string(requestID), .object(["answer": .string(text)]), .null])
        #expect(actual.objectValue?["order"]?.arrayValue?.last == .string("reply"))
    }

    @Test("optional events before a listener remain harmless and malformed native batches are rejected")
    func optionalEvents() async throws {
        let page = Page(); defer { page.close() }; try await page.load()
        _ = try await page.call("delete window.nodusMobileEvent; return null;", arguments: [:])
        _ = try await page.call(MobileJavaScriptDelivery.optionalEventBody, arguments: ["batch": [["channel": "mobile:corpus:changed", "args": []]]])
        #expect(throws: DesktopBridgeError.self) { try MobileJavaScriptDelivery.events(page.web, payload: "invalid", optional: false) }
        do {
            _ = try await page.call(MobileJavaScriptDelivery.eventBody, arguments: ["batch": [["channel": "strict", "args": []]]])
            Issue.record("The strict event callback must still fail when absent")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == WKError.errorDomain)
            #expect(failure.code == WKError.Code.javaScriptExceptionOccurred.rawValue)
        }
    }

    @MainActor private final class Page: NSObject, WKNavigationDelegate {
        enum Deadline: Error { case load, javaScript, invalidConcurrentCall, processTerminated }
        let web = WKWebView(frame: .zero)
        private var loaded: CheckedContinuation<Void, any Error>?
        private var loadTimeout: Task<Void, Never>?
        private var pendingCall: (id: UUID, continuation: CheckedContinuation<Any?, any Error>)?
        private var callTimeout: Task<Void, Never>?

        func load() async throws {
            try Task.checkCancellation()
            web.navigationDelegate = self
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    loaded = continuation
                    loadTimeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(20)) } catch { return }
                        self?.finishLoad(.failure(Deadline.load))
                        self?.web.stopLoading()
                    }
                    web.loadHTMLString("<html><body><script>window.events=[];window.order=[];window.nodusMobileReply=(...args)=>{window.reply=args;window.order.push('reply')};window.nodusMobileEvent=event=>{window.events.push(event);window.order.push('event')};</script></body></html>", baseURL: nil)
                }
            }, onCancel: { Task { @MainActor [weak self] in self?.finishLoad(.failure(CancellationError())); self?.web.stopLoading() } })
        }

        /// Bounded public WebKit completion path. Late completions cannot resume
        /// another call's continuation; all state is isolated to the main actor.
        func call(_ body: String, arguments: [String: Any] = [:]) async throws -> Any? {
            try Task.checkCancellation()
            guard pendingCall == nil else { throw Deadline.invalidConcurrentCall }
            let id = UUID()
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                    pendingCall = (id, continuation)
                    callTimeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                        self?.finishCall(id, .failure(Deadline.javaScript))
                    }
                    web.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { [weak self] result in
                        switch result {
                        case .success(let value): self?.finishCall(id, .success(value))
                        case .failure(let error): self?.finishCall(id, .failure(error))
                        }
                    }
                }
            }, onCancel: { Task { @MainActor [weak self] in self?.finishCall(id, .failure(CancellationError())) } })
        }
        private func finishLoad(_ result: Result<Void, any Error>) {
            guard let continuation = loaded else { return }
            loaded = nil; loadTimeout?.cancel(); loadTimeout = nil
            continuation.resume(with: result)
        }
        private func finishCall(_ id: UUID, _ result: Result<Any?, any Error>) {
            guard let call = pendingCall, call.id == id else { return }
            pendingCall = nil; callTimeout?.cancel(); callTimeout = nil
            call.continuation.resume(with: result)
        }
        func close() {
            finishLoad(.failure(CancellationError()))
            if let call = pendingCall { finishCall(call.id, .failure(CancellationError())) }
            web.stopLoading(); web.navigationDelegate = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoad(.success(())) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finishLoad(.failure(error)) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finishLoad(.failure(error)) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            finishLoad(.failure(Deadline.processTerminated))
            if let call = pendingCall { finishCall(call.id, .failure(Deadline.processTerminated)) }
        }
    }
}
