import Foundation
import NodusAI
import NodusKit
import WebKit

/// A small isolated JavaScript host for the actual shared Desktop context
/// writers. It owns no navigation, credentials, model calls or persistent data.
@MainActor
enum CompanionChatContext {
    struct Prepared: Decodable {
        let system: String,user: String
        let temperature: Double
        let maxTokens: Int
        let names: [String]
    }
    struct StudyPrepared: Decodable {
        let system: String,user: String
        let temperature: Double
        let maxTokens: Int
        let citations: [JSONValue]
        let evidence: JSONValue
        let truncated: Bool
        let sourceChars: Int
        let immediateAnswer: String?
    }
    struct StudyAnswer: Decodable { let answer: String,citations: [JSONValue],citationWarning: Bool }
    static func study(session: SpaceSession,options: CompanionStudyChatOptions,question: String,history: [ChatMessage]) async throws -> StudyPrepared {
        guard session.aiExecutionMode == .autonomous,let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
        let bridge = try ConnectionClient.companionChat(for:session.connection),selection = try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(options.selection))
        let packs: [JSONValue]
        do { packs = [try await bridge.operation(vaultId:vault,method:"getMobileStudyChatSourcePack",args:[selection])] }
        catch { guard isPrivateBridgeOffline(error) else { throw error };packs = try await CompanionStudyChatSources.packs(session:session) }
        var request = try options.value.objectValue!
        request["messages"] = .array((history.filter { $0.role != .system } + [.init(role:.user,content:question)]).map { .object(["role":.string($0.role.rawValue),"content":.string($0.content)]) })
        let input: JSONValue = .object(["vaultId":.string(vault),"packs":.array(packs),"request":.object(request),"interfaceLanguage":.string(Prompts.interfaceLanguage)])
        return try JSONDecoder.nodus.decode(StudyPrepared.self,from:JSONEncoder.nodus.encode(try await evaluateValue(input,operation:.study)))
    }
    static func validateStudyAnswer(_ text: String,citations: [JSONValue]) async throws -> StudyAnswer {
        let value = try await evaluateValue(.object(["answer":.string(text),"citations":.array(citations)]),operation:.studyAnswer)
        return try JSONDecoder.nodus.decode(StudyAnswer.self,from:JSONEncoder.nodus.encode(value))
    }
    static func validateStudySources(_ pack: JSONValue,vaultId: String) async throws {
        let result = try await evaluateValue(.object(["pack":pack,"vaultId":.string(vaultId)]),operation:.studySources)
        guard result.objectValue?["valid"] == .bool(true) else { throw DesktopBridgeError.malformedResponse }
    }
    static func database(session: SpaceSession,settings: AISettings,ids: [String],question: String,history: [ChatMessage]) async throws -> Prepared {
        guard session.aiExecutionMode == .autonomous,!ids.isEmpty,ids.count <= 30,let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
        let bridge = try ConnectionClient.companionChat(for:session.connection)
        let request: JSONValue = .object(["databaseIds":.array(ids.map(JSONValue.string))])
        let packs: JSONValue
        do { packs = .array([try await bridge.operation(vaultId:vault,method:"getMobileDatabaseResearchSourcePack",args:[request])]) }
        catch {
            guard isPrivateBridgeOffline(error) else { throw error }
            let downloaded = try await AutonomousSurfaceProvider(settings:settings).databaseOfflineSource([request],session:session)
            guard let values = downloaded.objectValue?["packs"] else { throw DesktopBridgeError.malformedResponse };packs = values
        }
        let input: JSONValue = .object(["vaultId":.string(vault),"databaseIds":.array(ids.map(JSONValue.string)),"packs":packs,"question":.string(question),"history":.array(history.filter{$0.role != .system}.map{.object(["role":.string($0.role.rawValue),"content":.string($0.content)])}),"language":.string(Prompts.interfaceLanguage)])
        return try await evaluate(input)
    }
    static func evaluate(_ input: JSONValue) async throws -> Prepared {
        let value = try await evaluateValue(input,operation:.database)
        let prepared = try JSONDecoder.nodus.decode(Prepared.self,from:JSONEncoder.nodus.encode(value))
        guard !prepared.system.isEmpty,!prepared.user.isEmpty,prepared.maxTokens > 0 else { throw DesktopBridgeError.malformedResponse }
        return prepared
    }
    private enum Operation {
        case database,study,studyAnswer,studySources
        var script: String {
            switch self {
            case .database: "return NodusCompanionChat.prepareDatabaseChat(input);"
            case .study: "return NodusCompanionChat.prepareStudyChat(input);"
            case .studyAnswer: "return NodusCompanionChat.validateStudyAssistantAnswer(input.answer,input.citations);"
            case .studySources: "NodusCompanionChat.validateMobileStudyChatSourcePack(input.pack,input.vaultId);return {valid:true};"
            }
        }
    }
    private static func evaluateValue(_ input: JSONValue,operation: Operation) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let resource = Bundle.main.url(forResource:"companion-chat",withExtension:"js",subdirectory:"SharedDesktop") else {
            throw APIError(status:503,code:"companion_chat_engine_missing",message:"El motor compartido de chat no está incluido en esta compilación.")
        }
        let script = try String(contentsOf:resource,encoding:.utf8)
        let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame:.zero,configuration:config),loader = Loader()
        view.navigationDelegate = loader
        defer { view.stopLoading();view.navigationDelegate = nil;loader.cancel() }
        view.loadHTMLString("<meta http-equiv='Content-Security-Policy' content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; base-uri 'none'; form-action 'none'\">",baseURL:nil)
        try await withTaskCancellationHandler { try await loader.wait() } onCancel: { Task { @MainActor in loader.cancel() } }
        try Task.checkCancellation()
        let arguments = try JSONSerialization.jsonObject(with:JSONEncoder.nodus.encode(input))
        // Structured arguments remain data. No source/question text is inserted
        // into JavaScript, and this host cannot fetch files or contact providers.
        let value = try await view.callAsyncJavaScript(script + "\n" + operation.script,arguments:["input":arguments],in:nil,contentWorld:.page)
        try Task.checkCancellation()
        let data = try JSONSerialization.data(withJSONObject:value)
        return try JSONDecoder.nodus.decode(JSONValue.self,from:data)
    }
    private final class Loader: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void,any Error>?
        private var result: Result<Void,any Error>?
        private var deadline: Task<Void,Never>?
        func wait() async throws {
            if let result { return try result.get() }
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for:.seconds(20));self?.finish(.failure(URLError(.timedOut))) } catch {}
                }
            }
        }
        private func finish(_ value: Result<Void,any Error>) {
            guard result == nil else { return };result = value;deadline?.cancel();deadline = nil
            continuation?.resume(with:value);continuation = nil
        }
        func cancel() { finish(.failure(CancellationError())) }
        func webView(_ webView: WKWebView,didFinish navigation: WKNavigation!) { finish(.success(())) }
        func webView(_ webView: WKWebView,didFail navigation: WKNavigation!,withError error: any Error) { finish(.failure(error)) }
        func webView(_ webView: WKWebView,didFailProvisionalNavigation navigation: WKNavigation!,withError error: any Error) { finish(.failure(error)) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.networkConnectionLost))) }
    }
}
