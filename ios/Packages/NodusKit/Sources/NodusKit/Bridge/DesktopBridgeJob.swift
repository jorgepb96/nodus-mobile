import Foundation

public struct DesktopBridgeJob: Decodable, Sendable, Identifiable {
    public enum State: String, Decodable, Sendable { case accepted, running, saved, available, failed, interrupted, cancelled }
    public struct Event: Codable, Sendable {
        public let sequence: Int
        public let channel: String
        public let args: [JSONValue]
    }
    public let id: String
    public let vaultId: String
    public let method: String
    public let state: State
    public let nextSequence: Int
    public let events: [Event]
    public let result: JSONValue
    public let error: String?
    public var actionSequence: Int? = nil
    public var createdAt: Date? = nil
    public var updatedAt: Date? = nil
}

public extension DesktopBridgeClient {
    static let jobMethods: Set<String> = ["runMobileSpaceAction", "streamMobileCompanionChat", "saveMobileAcademicResult", "saveDictionaryGeneratedVersion", "saveImmersionGeneratedSession", "saveContentTranslationFromMobile", "saveStudyImprovementFromMobile", "saveWritingWorkshopFromMobile", "saveMobileDatabaseResearchReport", "startDictionaryGeneration", "enqueueDeepResearchJob", "enqueueDatabaseDeepResearch", "exportWritingWorkshopDraft", "exportDeepResearchArchive", "exportImmersionSessionPdf", "exportDatabaseDeepResearchReport", "generateImmersionSession", "generateWritingWorkshopDraft", "generateContentTranslation", "researchChat", "researchChatStream", "worldChatStream", "dbChatStream", "streamStudyAssistant", "improveStudyText", "buildArgumentMap", "scanDictionaryNewEvidence", "generateConversationTitle"]
    /// Synchronizing an already generated device result or exporting a saved
    /// document does not select or invoke the Mac's research model.
    static let providerFreeJobMethods: Set<String> = ["saveMobileAcademicResult", "saveDictionaryGeneratedVersion", "saveImmersionGeneratedSession", "saveContentTranslationFromMobile", "saveStudyImprovementFromMobile", "saveWritingWorkshopFromMobile", "saveMobileDatabaseResearchReport", "exportWritingWorkshopDraft", "exportDeepResearchArchive", "exportImmersionSessionPdf", "exportDatabaseDeepResearchReport"]

    /// A stable key can be resubmitted after transport failure; the Mac returns the
    /// existing job instead of generating and saving the same content twice.
    func submitJob(vaultId: String, method: String, args: [JSONValue], idempotencyKey: String) async throws -> DesktopBridgeJob {
        guard Self.jobMethods.contains(method) else { throw DesktopBridgeError.permissionDenied }
        var key = idempotencyKey
        if method == "runMobileSpaceAction" {
            key = try DesktopCompanionActions.validateJob(args: args, domains: pairing.domains)
        }
        let response = try await jobRequest(vaultId: vaultId, method: "POST", body: .object([
            "method": .string(method), "args": .array(args), "idempotencyKey": .string(key)
        ]))
        guard response.job.vaultId == vaultId, response.job.method == method else { throw DesktopBridgeError.malformedResponse }
        return response.job
    }
    func readJob(vaultId: String, id: String, cursor: Int = 0) async throws -> DesktopBridgeJob {
        try await jobRequest(vaultId: vaultId, id: id, query: [URLQueryItem(name: "cursor", value: String(cursor))], method: "GET").job
    }
    func jobForRequest(vaultId:String,requestId:String) async throws -> DesktopBridgeJob? {
        guard UUID(uuidString:requestId) != nil else { throw DesktopBridgeError.malformedResponse }
        do { return try await jobRequest(vaultId:vaultId,query:[URLQueryItem(name:"requestId",value:requestId)],method:"GET").job }
        catch let error as APIError where error.status == 404 { return nil }
    }
    func jobForSpaceAction(vaultId: String, idempotencyKey: String) async throws -> DesktopBridgeJob? {
        guard !idempotencyKey.isEmpty, idempotencyKey.count <= 4096 else { throw DesktopBridgeError.malformedResponse }
        do {
            let job = try await jobRequest(vaultId: vaultId,
                query: [URLQueryItem(name: "requestId", value: DesktopCompanionActions.key(idempotencyKey))], method: "GET").job
            guard job.vaultId == vaultId, job.method == "runMobileSpaceAction" else { throw DesktopBridgeError.malformedResponse }
            return job
        } catch let error as APIError where error.status == 404 { return nil }
    }
    static func isProviderFreeJob(method: String, args: [JSONValue]) -> Bool {
        if providerFreeJobMethods.contains(method) { return true }
        guard method == "runMobileSpaceAction", args.count == 1,
              let kind = args[0].objectValue?["kind"]?.stringValue else { return false }
        return DesktopCompanionActions.content.contains(kind)
    }
    func cancelJob(vaultId: String, id: String) async throws -> DesktopBridgeJob {
        try await jobRequest(vaultId: vaultId, id: id, method: "DELETE").job
    }
    func awaitJob(vaultId: String, job: DesktopBridgeJob, onState: @Sendable (DesktopBridgeJob) async throws -> Void = { _ in }, onEvents: @Sendable ([DesktopBridgeJob.Event]) async -> Void) async throws -> JSONValue {
        var current = job
        var cursor = 0
        while true {
            try Task.checkCancellation()
            try await onState(current)
            await onEvents(current.events)
            cursor = max(cursor, current.events.last?.sequence ?? 0)
            switch current.state {
            case .available: return current.result
            case .failed, .interrupted:
                throw APIError(status: 409, code: current.state.rawValue, message: current.error ?? "The Mac could not finish this request.")
            case .cancelled: throw CancellationError()
            case .accepted, .running, .saved: break
            }
            try await Task.sleep(for: .milliseconds(700))
            current = try await readJob(vaultId: vaultId, id: current.id, cursor: cursor)
        }
    }
}

struct DesktopBridgeJobEnvelope: Decodable, Sendable { let job: DesktopBridgeJob }
