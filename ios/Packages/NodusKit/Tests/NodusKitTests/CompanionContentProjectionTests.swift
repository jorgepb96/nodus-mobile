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
}
