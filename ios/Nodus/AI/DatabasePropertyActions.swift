import CryptoKit
import Foundation
import NodusAI
import NodusKit

/// Explicit row actions keep Live provider selection on Mac and autonomous
/// selection on this device. Observation never owns the paid task.
@MainActor enum DatabasePropertyActions {
    private static var journals: [String:CompanionDatabaseActionJournal] = [:]
    private static var active: [String:Task<DesktopJobLedger.Request,Error>] = [:]
    private static func request(rowId:String,columnId:String,kind:String)->JSONValue {.object(["rowId":.string(rowId),"columnId":.string(columnId),"kind":.string(kind)])}
    private static func journal(session:SpaceSession) async throws -> CompanionDatabaseActionJournal {
        let (vault,pairing,_)=try privateBridgeConnection(session,domain:.writing),key=pairing.id+":"+vault
        if let journal=journals[key]{return journal}
        let value=try await CompanionDatabaseActionJournal(cache:PrivateBridgeCache(pairingId:pairing.id),vault:vault);journals[key]=value;return value
    }
    static func download(session:SpaceSession,rowId:String,columnId:String,kind:String,days:Int=7) async throws {
        guard [7,30].contains(days) else {throw PrivateBridgeCache.ReadPackError.invalidSelection}
        let (vault,pairing,token)=try privateBridgeConnection(session,domain:.corpus),client=DesktopBridgeClient(pairing:pairing,token:token)
        let input=request(rowId:rowId,columnId:columnId,kind:kind),source=try await client.operation(vaultId:vault,method:"getMobileDatabaseActionSource",args:[input])
        try validate(source,input:input)
        let key=try CompanionDocumentOutbox.operationKey("getMobileDatabaseActionSource",[input])
        var records=[PrivateBridgeCache.ReadPackRecord(domain:.corpus,recordId:key,data:try JSONEncoder.nodus.encode(source))]
        for image in source.objectValue?["images"]?.arrayValue ?? [] {
            guard let id=image.objectValue?["id"]?.stringValue else {throw DesktopBridgeError.malformedResponse}
            let descriptor=try await client.fileDescriptor(vaultId:vault,kind:.databaseAttachment,id:id)
            guard descriptor.byteSize <= 10_000_000 else {throw PrivateBridgeCache.ReadPackError.perDownloadLimit}
            let data=try await client.fileData(vaultId:vault,descriptor:descriptor),record="file:databaseAttachment:\(id)"
            records.append(.init(domain:DesktopBridgeFileKind.databaseAttachment.domain,recordId:record,data:try JSONEncoder.nodus.encode(descriptor)))
            records.append(.init(domain:DesktopBridgeFileKind.databaseAttachment.domain,recordId:record+":"+descriptor.sha256,data:data))
        }
        guard try await client.operation(vaultId:vault,method:"getMobileDatabaseActionSource",args:[input]) == source else {throw APIError(status:409,code:"database_action_download_changed",message:"La fila o su propiedad cambió durante la descarga.")}
        let selection=try PrivateBridgeCache.readPackSelectionId(vaultId:vault,recordIds:records.map(\.recordId))
        try await PrivateBridgeCache(pairingId:pairing.id).saveReadPack(id:selection,vaultId:vault,title:"Contexto de la propiedad: "+String((source.objectValue?["title"]?.stringValue ?? "Propiedad").prefix(200)),expiresAt:Date().addingTimeInterval(Double(days)*86400),records:records)
        session.didChangeCompanionDownloads()
    }
    private static func validate(_ source:JSONValue,input:JSONValue)throws {
        guard let value=source.objectValue,value["version"] == .int(1),value["rowId"] == input.objectValue?["rowId"],value["columnId"] == input.objectValue?["columnId"],value["kind"] == input.objectValue?["kind"],let revision=value["revision"]?.stringValue,revision.count == 64,
              let images=value["images"]?.arrayValue,images.count<=2 else {throw DesktopBridgeError.malformedResponse}
    }
    private static func source(session:SpaceSession,input:JSONValue) async throws -> JSONValue {
        let (vault,pairing,token)=try privateBridgeConnection(session,domain:.corpus)
        if session.aiExecutionMode == .live {
            let value=try await DesktopBridgeClient(pairing:pairing,token:token).operation(vaultId:vault,method:"getMobileDatabaseActionSource",args:[input]);try validate(value,input:input);return value
        }
        let cache=try PrivateBridgeCache(pairingId:pairing.id),key=try CompanionDocumentOutbox.operationKey("getMobileDatabaseActionSource",[input])
        guard let bytes=try await cache.downloadedData(vaultId:vault,domain:.corpus,recordId:key).first else {throw APIError(status:409,code:"database_action_context_not_downloaded",message:"Descarga el contexto de esta propiedad para generarla en este dispositivo.")}
        let value=try JSONDecoder.nodus.decode(JSONValue.self,from:bytes);try validate(value,input:input);return value
    }
    static func generateText(session:SpaceSession,rowId:String,columnId:String,ai:AISettings)async throws->DesktopJobLedger.Request {try await generate(session:session,rowId:rowId,columnId:columnId,kind:"text",ai:ai)}
    static func generateImage(session:SpaceSession,rowId:String,columnId:String,ai:AISettings)async throws->DesktopJobLedger.Request {try await generate(session:session,rowId:rowId,columnId:columnId,kind:"image",ai:ai)}
    private static func live(session:SpaceSession,request:JSONValue,method:String)async throws->DesktopJobLedger.Request {
        let (vault,pairing,_)=try privateBridgeConnection(session,domain:.writing),ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:vault)
        if let pending=await ledger.all().first(where:{$0.method==method && $0.args == [request] && !["available","cancelled","failed"].contains($0.state) && $0.cancellationRequested != true}) {return pending}
        if let interrupted=await ledger.all().first(where:{$0.method==method && $0.args == [request] && ["failed","cancelled","interrupted"].contains($0.state)}) {
            let recovery:JSONValue = .object(["requestId":.string(interrupted.id),"request":request])
            if let pending=await ledger.all().first(where:{$0.method=="recoverMobileDatabaseAction" && $0.args == [recovery] && $0.state != "available"}) {return pending}
            return try await ledger.prepare(id:UUID().uuidString.lowercased(),method:"recoverMobileDatabaseAction",args:[recovery])
        }
        return try await ledger.prepare(id:UUID().uuidString.lowercased(),method:method,args:[request])
    }
    static func preparePublication(session:SpaceSession,checkpoint:CompanionDatabaseActionCheckpoint)async throws->DesktopJobLedger.Request {
        guard checkpoint.value.objectValue?["recoveryReviewRequired"] != .bool(true),let input=checkpoint.publicationInput else {throw APIError(status:409,code:"database_action_recovery_review",message:"Revisa este resultado conservado antes de publicarlo.")}
        let (vault,pairing,_)=try privateBridgeConnection(session,domain:.writing),ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:vault)
        guard await ledger.all().first(where:{$0.id==checkpoint.id})?.state != "recoveryReview" else {throw DesktopBridgeError.permissionDenied}
        if let bytes=input.objectValue?["bytes"]?.stringValue,bytes.utf8.count>3_600_000 {
            throw APIError(status:409,code:"database_image_chunk_publication_pending",message:"La imagen se conserva en este dispositivo. Su publicación necesita la integración de carga por fragmentos.")
        }
        // The exact retained paid result is never purchased again on retry.
        return try await ledger.prepare(id:checkpoint.id,method:checkpoint.value.objectValue?["request"]?.objectValue?["kind"] == .string("button") ? "saveMobileDatabaseButtonResult":"saveMobileDatabaseGeneratedCell",args:[input])
    }
    private static func generate(session:SpaceSession,rowId:String,columnId:String,kind:String,ai:AISettings)async throws->DesktopJobLedger.Request {
        let input=request(rowId:rowId,columnId:columnId,kind:kind),source=try await source(session:session,input:input)
        var fields=input.objectValue!;fields["revision"]=source.objectValue?["revision"];let captured=JSONValue.object(fields)
        if session.aiExecutionMode == .live {return try await live(session:session,request:captured,method:kind=="image" ? "generateMobileDatabaseImage":"generateMobileDatabaseText")}
        let model:ModelRef
        if let columnModel=source.objectValue?["columnModel"],columnModel.objectValue != nil {
            var object=columnModel.objectValue!;if object["provider"] == .string("google"){object["provider"] = .string("gemini")}
            guard let selected=try? JSONDecoder.nodus.decode(ModelRef.self,from:JSONEncoder.nodus.encode(JSONValue.object(object))) else {throw APIError(status:409,code:"database_column_model_not_mobile",message:"El modelo de esta propiedad requiere Nodus para Mac. Selecciona un modelo disponible en el móvil.")};model=selected
        }else{guard let selected=ai.model(for:kind=="image" ? .image:.chat) else {throw APIError(status:409,code:"database_device_model_missing",message:"Selecciona el modelo de esta generación en los ajustes del móvil.")};model=selected}
        guard ai.hasKey(for:model.provider) else {throw ProviderError.missingKey(model.provider)}
        let modelValue=try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(model)),scope=try CompanionDatabaseActionCheckpoint.scope(request:captured,model:modelValue)
        let (vault,pairing,_)=try privateBridgeConnection(session,domain:.writing),activeKey=pairing.id+":"+vault+":"+scope
        if let task=active[activeKey]{return try await task.value}
        let journal=try await journal(session:session),ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:vault),previous=try await journal.load(scope:scope)
        let completed=previous == nil ? false:await ledger.all().first(where:{$0.id==previous!.id})?.state == "available"
        if let previous,previous.publicationInput != nil,!completed{return try await preparePublication(session:session,checkpoint:previous)}
        let cache=try PrivateBridgeCache(pairingId:pairing.id),provider=ProviderClient(keyProvider:ai.keyProvider),vision=DatabaseVisionCompletion(keyProvider:ai.keyProvider),imageService=ImageService(keyProvider:ai.keyProvider)
        let task=Task { @MainActor in
            try cache.beginAuthoringActivity();defer{cache.endAuthoringActivity()}
            var references:[DatabaseVisionCompletion.Image]=[],referenceValues:[JSONValue]=[]
            for image in source.objectValue?["images"]?.arrayValue ?? [] {
                guard let id=image.objectValue?["id"]?.stringValue else {throw DesktopBridgeError.malformedResponse}
                let file=try await PrivateBridgeDownloadedFile.load(cache:cache,vaultId:vault,kind:.databaseAttachment,id:id)
                guard image.objectValue?["sha256"] == .string(file.descriptor.sha256), image.objectValue?["bytes"] == .int(Int64(file.data.count)) else {throw DesktopBridgeError.malformedResponse}
                references.append(.init(data:file.data,mime:file.descriptor.mime));referenceValues.append(.object(["id":.string(id),"mime":.string(file.descriptor.mime),"bytes":.string(file.data.base64EncodedString())]))
            }
            let accepted=try CompanionDatabaseActionCheckpoint(.object(["version":.int(1),"vaultId":.string(vault),"id":.string(UUID().uuidString.lowercased()),"request":captured,"model":modelValue,"createdAt":.string(ISO8601DateFormatter().string(from:Date())),"state":.string("accepted"),"source":source,"references":.array(referenceValues)]))
            guard let prompt=source.objectValue?["prompt"]?.stringValue else {throw DesktopBridgeError.malformedResponse}
            let images=references
            let result=try await journal.perform(accepted:accepted,regenerateCompleted:completed) {
                if kind=="image" {let image=try await imageService.generate(prompt:prompt,with:model);return .object(["bytes":.string(image.data.base64EncodedString()),"mime":.string(image.mimeType)])}
                let system=source.objectValue?["system"]?.stringValue ?? ""
                let text:String
                if images.isEmpty {text=try await provider.complete(ChatRequest(model:model,messages:[.init(role:.system,content:system),.init(role:.user,content:prompt)],temperature:0.2,maxTokens:1200))}
                else{text=try await vision.complete(model:model,system:system,prompt:prompt,images:images)}
                return .object(["text":.string(text)])
            }
            let current=try privateBridgeConnection(session,domain:.writing);guard current.0==vault,current.1.id==pairing.id else {throw DesktopBridgeError.permissionDenied}
            return try await preparePublication(session:session,checkpoint:result)
        }
        active[activeKey]=task;defer{active[activeKey]=nil};return try await task.value
    }
    static func runButton(session:SpaceSession,rowId:String,columnId:String)async throws->DesktopJobLedger.Request {
        let input=request(rowId:rowId,columnId:columnId,kind:"button"),source=try await source(session:session,input:input)
        var fields=input.objectValue!;fields["revision"]=source.objectValue?["revision"];let captured=JSONValue.object(fields)
        if session.aiExecutionMode == .live {return try await live(session:session,request:captured,method:"runMobileDatabaseButton")}
        guard let plan=source.objectValue?["plan"],let operations=plan.objectValue?["operations"]?.arrayValue,operations.count<=500 else {throw DesktopBridgeError.malformedResponse}
        let (vault,pairing,_)=try privateBridgeConnection(session,domain:.writing),scope=try CompanionDatabaseActionCheckpoint.scope(request:captured,model:.null),key=pairing.id+":"+vault+":"+scope
        if let task=active[key]{return try await task.value}
        let journal=try await journal(session:session),ledger=try await DesktopJobLedgers.shared.ledger(pairingId:pairing.id,vaultId:vault),previous=try await journal.load(scope:scope)
        let completed=previous == nil ? false:await ledger.all().first(where:{$0.id==previous!.id})?.state == "available"
        if let previous,previous.publicationInput != nil,!completed {return try await preparePublication(session:session,checkpoint:previous)}
        let cache=try PrivateBridgeCache(pairingId:pairing.id)
        let task=Task { @MainActor in
            try cache.beginAuthoringActivity();defer{cache.endAuthoringActivity()}
            let accepted=try CompanionDatabaseActionCheckpoint(.object(["version":.int(1),"vaultId":.string(vault),"id":.string(UUID().uuidString.lowercased()),"request":captured,"model":.null,"createdAt":.string(ISO8601DateFormatter().string(from:Date())),"state":.string("accepted"),"source":source]))
            let checkpoint=try await journal.perform(accepted:accepted,regenerateCompleted:completed) {
                try await executeButton(plan:plan,accepted:accepted,journal:journal)
            }
            return try await preparePublication(session:session,checkpoint:checkpoint)
        }
        active[key]=task;defer{active[key]=nil};return try await task.value
    }
    private static func executeButton(plan:JSONValue,accepted:CompanionDatabaseActionCheckpoint,journal:CompanionDatabaseActionJournal)async throws->JSONValue {
        let clickedAt=accepted.value.objectValue!["createdAt"]!.stringValue!,instantiated=try CompanionDatabaseActionCheckpoint.instantiate(plan,requestId:accepted.id,clickedAt:clickedAt)
        guard let operations=instantiated.objectValue?["operations"]?.arrayValue else {throw DesktopBridgeError.malformedResponse}
        var webhooks:[String:JSONValue]=[:],completed=0,failed:Int?
        func progress(pending:Int?=nil,finished:Bool=false)->JSONValue {
            var result:[String:JSONValue]=["clickedAt":.string(clickedAt),"completedSteps":.int(Int64(completed)),"webhooks":.object(webhooks)]
            if let pending {result["pendingWebhook"] = .int(Int64(pending))}
            if let failed {result["failedStep"] = .int(Int64(failed))}
            if finished {result["finishedAt"] = .string(ISO8601DateFormatter().string(from:Date()))}
            return .object(result)
        }
        for (index,operation) in operations.enumerated() {
            try Task.checkCancellation()
            guard let value=operation.objectValue,let type=value["type"]?.stringValue,["button_click","set_property","create_page","notify","webhook"].contains(type) else {throw DesktopBridgeError.malformedResponse}
            if type=="webhook" {
                guard let address=value["url"]?.stringValue,let url=URL(string:address),["http","https"].contains(url.scheme),let method=value["method"]?.stringValue,["POST","PUT","PATCH"].contains(method),let attempts=value["maxAttempts"]?.intValue,(1...10).contains(attempts),let delay=value["retryDelayMs"]?.intValue,delay>=0,delay<=60_000 else {throw DesktopBridgeError.malformedResponse}
                var request=URLRequest(url:url);request.httpMethod=method;request.timeoutInterval=45
                for (name,header) in value["headers"]?.objectValue ?? [:] {guard let text=header.stringValue else {throw DesktopBridgeError.malformedResponse};request.setValue(text,forHTTPHeaderField:name)}
                request.httpBody=Data((value["body"]?.stringValue ?? "").utf8)
                for attempt in 1...Int(attempts) {
                    // Unknown network outcomes remain an interrupted receipt.
                    // Relaunch never sends this external action again.
                    let checkpoint=try accepted.changing(state:.running,output:.object(["buttonResult":progress(pending:index)]));try await journal.put(checkpoint)
                    let connection=URLSession(configuration:.ephemeral)
                    let response:URLResponse
                    do {let (_,received)=try await connection.bytes(for:request);response=received;connection.invalidateAndCancel()}
                    catch{connection.invalidateAndCancel();throw error}
                    guard let http=response as? HTTPURLResponse else {throw DesktopBridgeError.malformedResponse}
                    let succeeded=(200...299).contains(http.statusCode)
                    webhooks[String(index)] = .object(["status":.string(succeeded ? "succeeded":"failed"),"httpStatus":.int(Int64(http.statusCode)),"attempt":.int(Int64(attempt))])
                    if succeeded {break}
                    if attempt==Int(attempts){failed=index;break}
                    try await journal.put(accepted.changing(state:.running,output:.object(["buttonResult":progress(pending:index)])))
                    try await Task.sleep(for:.milliseconds(Int(delay)))
                }
            }
            // These are real authored local deltas, durably projected from the
            // journal. Their single publication invokes the canonical repos.
            completed=index+1
            try await journal.put(accepted.changing(state:.running,output:.object(["buttonResult":progress()])))
            if failed != nil {break}
        }
        return .object(["buttonResult":progress(finished:true)])
    }
    static func overlayTables(_ original:[String: [Row]],session:SpaceSession)async throws->[String: [Row]] {
        let journal=try await journal(session:session);var tables=original
        for summary in await journal.summaries().reversed() {
            guard let scope=summary.objectValue?["scope"]?.stringValue,let checkpoint=try await journal.load(scope:scope),checkpoint.value.objectValue?["recoveryReviewRequired"] != .bool(true) else {continue}
            let cells=try checkpoint.projectedCells()
            for (row,columns) in cells {for (column,value) in columns {
                tables["db_cells"]?.removeAll{$0.string("row_id")==row && $0.string("column_id")==column}
                tables["db_cells",default:[]].append(Row(["row_id":.string(row),"column_id":.string(column),"value_text":value,"mobileSyncState":.string("pending")]))
            }}
        }
        return tables
    }
}
