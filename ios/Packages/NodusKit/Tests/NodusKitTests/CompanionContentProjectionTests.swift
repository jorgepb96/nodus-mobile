import Foundation
import Testing
@testable import NodusKit

@Suite("Reopened companion content")
struct CompanionContentProjectionTests {
    @Test("Pending rows reopen but acknowledged canonical rows and later edits win")
    func rows() {
        let mutation=Mutation(clientId:"phone",kind:.upsert,table:.databaseRows,key:["row"],row:["id":.string("row"),"database_id":.string("database"),"revision":.int(1)],schemaVersion:1)
        let local=CompanionContentProjection.apply(["db_rows":[]],mutations:[mutation],states:[mutation.id:.pending])
        #expect(local["db_rows"]?.first?.string("id")=="row");#expect(local["db_rows"]?.first?.string("mobileSyncState")=="pending")
        let canonical=Row(["id":.string("row"),"revision":.int(2),"position":.int(37)])
        #expect(CompanionContentProjection.apply(["db_rows":[canonical]],mutations:[mutation],states:[mutation.id:.delivered])["db_rows"]==[canonical])
        #expect(CompanionContentProjection.apply(["db_rows":[]],mutations:[mutation],states:[mutation.id:.rejected])["db_rows"]?.isEmpty==true)
    }
    @Test("An acknowledged clear cannot cover a later cell recreated on the Mac")
    func clearedCell() {
        let mutation=Mutation(clientId:"phone",kind:.upsert,table:.databaseCells,key:["row","column"],row:["row_id":.string("row"),"column_id":.string("column"),"revision":.int(7),"_mobileBaseRowRevision":.int(10),"value_text":.string("")],schemaVersion:1)
        let parent=Row(["id":.string("row"),"revision":.int(15)])
        let foreign=Row(["row_id":.string("row"),"column_id":.string("column"),"revision":.int(1),"value_text":.string("Versión posterior")])
        let source=["db_rows":[parent],"db_cells":[foreign]]
        #expect(CompanionContentProjection.apply(source,mutations:[mutation],states:[mutation.id:.delivered])["db_cells"]==[foreign])
        let pending=CompanionContentProjection.apply(source,mutations:[mutation],states:[mutation.id:.pending])
        #expect(pending["db_cells"]?.first?.string("value_text")=="");#expect(pending["db_cells"]?.first?.string("mobileSyncState")=="pending")
    }

    @Test("World keys are generated and delivered overlays compare their own canonical row")
    func worldRows() {
        #expect(MutableTable.worldBeats.identityFields == ["thread_kind","thread_id","scene_id"])
        #expect(MutableTable.companionWorldTables.contains(.worldScenes))
        #expect(!MutableTable.companionWorldTables.contains(.databaseRows))
        let a=Row(["scene_id":.string("a"),"title":.string("A"),"updated_at":.string("2026-10-10T12:00:00.000Z")])
        let b=Row(["scene_id":.string("b"),"title":.string("Edición posterior del Mac"),"updated_at":.string("2026-10-10T14:00:00.000Z")])
        let deleted=Mutation(clientId:"phone",kind:.delete,table:.worldScenes,key:["a"],schemaVersion:1)
        let edited=Mutation(clientId:"phone",kind:.upsert,table:.worldScenes,key:["b"],row:["scene_id":.string("b"),"title":.string("Edición anterior"),"updated_at":.string("2026-10-10T13:00:00.000Z")],schemaVersion:1)
        let result=CompanionContentProjection.apply(["world_scenes":[a,b]],mutations:[deleted,edited],states:[deleted.id:.pending,edited.id:.delivered])
        #expect(result["world_scenes"]==[b]) // Removing A shifts B; the canonical source index must not shift.
        let beat=Mutation(clientId:"phone",kind:.upsert,table:.worldBeats,key:["arc","thread","b"],row:["thread_kind":.string("arc"),"thread_id":.string("thread"),"scene_id":.string("b"),"mark":.string("turn")],schemaVersion:1)
        let beats=CompanionContentProjection.apply(["world_beats":[]],mutations:[beat],states:[beat.id:.pending])
        #expect(beats["world_beats"]?.first?.string("mark")=="turn")
        #expect(CompanionContentProjection.apply(["world_beats":[]],mutations:[beat],states:[beat.id:.rejected])["world_beats"]?.isEmpty==true)
    }

    @Test("Queued repository deletion survives reopening; failures and later Mac recreation remain visible")
    func worldDeletions() {
        let time=ISO8601DateFormatter.nodusFractional.date(from:"2026-10-10T13:00:00.000Z")!
        let action:JSONValue = .object(["kind":.string("worldbuilding.entityDelete"),"payload":.object(["entity":.string("scene"),"id":.string("scene")])])
        var request=DesktopJobLedger.Request(id:"delete",method:"runMobileSpaceAction",args:[action],createdAt:time,jobId:nil,state:"pending",issue:nil)
        let scene=Row(["scene_id":.string("scene"),"title":.string("Scene"),"updated_at":.string("2026-10-10T12:00:00.000Z")])
        let beat=Row(["thread_kind":.string("arc"),"thread_id":.string("thread"),"scene_id":.string("scene")])
        let unrelated=Row(["scene_id":.string("other"),"title":.string("Other")])
        let source=["world_scenes":[scene,unrelated],"world_beats":[beat]]
        let pending=CompanionContentProjection.applyWorldDeletions(source,requests:[request])
        #expect(pending["world_scenes"]==[unrelated]);#expect(pending["world_beats"]?.isEmpty==true)
        request.state="failed";#expect(CompanionContentProjection.applyWorldDeletions(source,requests:[request])==source)
        request.state="pending";request.cancellationRequested=true
        #expect(CompanionContentProjection.applyWorldDeletions(source,requests:[request])==source)
        request.cancellationRequested=false;request.state="available";request.macUpdatedAt=time
        let newer=Row(["scene_id":.string("scene"),"title":.string("Recreated"),"updated_at":.string("2026-10-10T14:00:00.000Z")])
        #expect(CompanionContentProjection.applyWorldDeletions(["world_scenes":[newer]],requests:[request])["world_scenes"]==[newer])
    }

    @Test("Compound beats and new scene rows reopen from the durable authorised outbox")
    func reopenedWorld() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let first=try MutationOutbox(spaceId:"mac-world",directory:root)
        let scene=Mutation(clientId:"phone",kind:.upsert,table:.worldScenes,key:["scene"],row:["scene_id":.string("scene"),"title":.string("Escena sin conexión")],schemaVersion:1)
        let beat=Mutation(clientId:"phone",kind:.upsert,table:.worldBeats,key:["arc","thread","scene"],row:["thread_kind":.string("arc"),"thread_id":.string("thread"),"scene_id":.string("scene"),"mark":.string("step")],schemaVersion:1)
        try await first.enqueue(scene,title:"Scene");try await first.authorise(ids:[scene.id])
        try await first.enqueue(beat,title:"Beat");try await first.authorise(ids:[beat.id])
        let reopened=try MutationOutbox(spaceId:"mac-world",directory:root)
        #expect(try await reopened.authorisedPending(limit:10).map(\.id)==[scene.id,beat.id])
        let projected=try await reopened.companionContentProjection(["world_scenes":[],"world_beats":[]])
        #expect(projected["world_scenes"]?.first?.string("title")=="Escena sin conexión")
        #expect(projected["world_beats"]?.first?.string("scene_id")=="scene")
    }
}
