import Foundation
import NodusKit

/// The native screen observes a durable Mac job. Leaving the screen stops only
/// observation; cancellation is a separate durable action against its identity.
@MainActor
enum NativeLiveChat {
    private static var inFlight:[String:(token:UUID,task:Task<Bool,any Error>)]=[:]
    static func step(id:String,session:SpaceSession,cancel:Bool = false) async throws -> Bool {
        try NodusLinkPolicy.requireAuthoring()
        let key=session.connection.storageId+"|"+id
        if cancel {
            let store=ChatHistoryStore.shared(spaceId:session.connection.storageId)
            if let pending=store.conversations.first(where:{$0.id == id})?.pendingLive,let pairing=session.connection.desktopPairingId,let vault=session.vaultId {
                guard pairing == pending.pairingId else { throw DesktopBridgeError.permissionDenied }
                let ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing,vaultId:vault)
                _=try await ledger.prepare(id:pending.request.requestId,method:"streamMobileCompanionChat",args:[try pending.request.value])
                try await ledger.requestCancellation(id:pending.request.requestId)
            }
        }
        if let current=inFlight[key] {
            do { let result=try await current.task.value;if !cancel { return result } }
            catch { if !cancel { throw error } }
        }
        let token=UUID()
        let operation=Task { try await perform(id:id,session:session,cancel:cancel) }
        inFlight[key]=(token,operation)
        defer { if inFlight[key]?.token == token { inFlight[key]=nil } }
        return try await operation.value
    }
    private static func perform(id:String,session:SpaceSession,cancel:Bool) async throws -> Bool {
        let store=ChatHistoryStore.shared(spaceId:session.connection.storageId)
        guard let pending=store.conversations.first(where:{$0.id == id})?.pendingLive else { return true }
        guard let pairingId=session.connection.desktopPairingId,pairingId == pending.pairingId,let vaultId=session.vaultId else { throw DesktopBridgeError.permissionDenied }
        let request=pending.request,bridge=try ConnectionClient.companionChat(for:session.connection)
        let ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairingId,vaultId:vaultId)
        let receipt=try await ledger.prepare(id:request.requestId,method:"streamMobileCompanionChat",args:[try request.value])
        if cancel { try await ledger.requestCancellation(id:request.requestId) }
        let stopping=cancel || receipt.cancellationRequested == true
        var job:DesktopBridgeJob?
        if let jobId=receipt.jobId { job=try await bridge.readJob(vaultId:vaultId,id:jobId,cursor:pending.sequence) }
        else if stopping {
            job=try await bridge.jobForRequest(vaultId:vaultId,requestId:request.requestId)
            if job == nil {
                try await ledger.cancelUnsubmitted(id:request.requestId)
                try store.cancelUnsubmittedLive(id:id,request:request)
                try await ledger.releaseLivePayload(id:request.requestId)
                return true
            }
        } else {
            guard session.aiExecutionMode == .live else { return false }
            let capabilities=try await bridge.liveCapabilities()
            guard capabilities.operations.contains("streamMobileCompanionChat") else { throw APIError(status:409,code:"native_live_chat_unsupported",message:"Actualiza Nodus en tu Mac para utilizar el chat nativo del móvil. La pregunta se conserva sin generar.") }
            job=try await bridge.submitJob(vaultId:vaultId,method:"streamMobileCompanionChat",args:[try request.value],idempotencyKey:request.requestId)
        }
        guard var current=job else { throw DesktopBridgeError.malformedResponse }
        if stopping,[.accepted,.running,.interrupted].contains(current.state) { current=try await bridge.cancelJob(vaultId:vaultId,id:current.id) }
        try await ledger.update(id:request.requestId,job:current)
        try store.applyLiveEvents(id:id,requestId:request.requestId,events:current.events)
        switch current.state {
        case .available: try store.finishLive(current.result,request:request);try await ledger.releaseLivePayload(id:request.requestId);return true
        case .failed,.interrupted,.cancelled:
            var remote:CompanionChatDocument?
            do { remote=try await bridge.chatDocument(vaultId:vaultId,kind:request.kind,id:id) }
            catch let error as APIError where error.status == 404 { remote=nil }
            try store.finishInterruptedLive(id:id,request:request,remote:remote,state:current.state.rawValue,issue:current.error ?? "La respuesta se detuvo. Se conserva el texto recibido.")
            try await ledger.releaseLivePayload(id:request.requestId)
            return true
        case .accepted,.running,.saved: return false
        }
    }
    static func observe(id:String,session:SpaceSession,refresh:@MainActor () -> Void) async {
        do {
            while true {
                try Task.checkCancellation()
                let done=try await step(id:id,session:session);refresh()
                if done { return }
                try await Task.sleep(for:.milliseconds(700))
            }
        } catch where error.isCancellation { return }
        catch { recordIssue(id:id,session:session,error:error);refresh() }
    }
    static func reconcile(session:SpaceSession) async {
        guard !NodusLinkPolicy.readOnly else { return }
        let store=ChatHistoryStore.shared(spaceId:session.connection.storageId)
        for conversation in store.conversations where conversation.pendingLive != nil {
            if Task.isCancelled { return }
            do { _=try await step(id:conversation.id,session:session) }
            catch where error.isCancellation { return }
            catch { recordIssue(id:conversation.id,session:session,error:error) }
        }
    }
    static func recordIssue(id:String,session:SpaceSession,error:Error) {
        let store=ChatHistoryStore.shared(spaceId:session.connection.storageId)
        guard let request=store.conversations.first(where:{$0.id == id})?.pendingLive?.request else { return }
        do { try store.liveIssue(id:id,requestId:request.requestId,issue:error.localizedDescription) } catch { /* The store surfaces the failed own-file write. */ }
    }
}
