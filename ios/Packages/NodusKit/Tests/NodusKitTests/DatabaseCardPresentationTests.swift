import Foundation
import Testing
@testable import NodusKit

@Suite("Native database card presentation")
struct DatabaseCardPresentationTests {
    private func row(_ id:String,_ value:String) -> PagesDatabasesParity.DataRow {
        .init(id:id,databaseId:"database",position:0,cells:["group":value],revision:1,updatedAt:nil)
    }
    @Test("Same-label options remain different lanes; empty lanes and capacity use real IDs")
    func lanes() {
        let column=PagesDatabasesParity.Column(id:"group",databaseId:"database",name:"Estado",type:"status",position:0,config:[:],options:[
            .init(id:"first",label:"En curso",color:"blue",position:0),.init(id:"second",label:"En curso",color:"green",position:1),.init(id:"empty",label:"Pendiente",color:nil,position:2)])
        let rows=[row("one","first"),row("two","second"),row("three","")]
        let lanes=DatabaseCardPresentation.lanes(column:column,rows:rows,config:["groupLimits":.object(["first":.int(1)])])
        #expect(lanes.map(\.id)==["first","second","empty","__empty__"])
        #expect(lanes[0].rows.map(\.id)==["one"]);#expect(lanes[1].rows.map(\.id)==["two"])
        #expect(lanes[0].atCapacity);#expect(!lanes[1].atCapacity);#expect(lanes[2].rows.isEmpty)
        let hidden=DatabaseCardPresentation.lanes(column:column,rows:rows,config:["hideEmptyGroups":.bool(true),"groupBy":.object(["dir":.string("desc")])])
        #expect(hidden.map(\.id)==["__empty__","second","first"])
    }
    @Test("People group by the first canonical identity, retaining their labels")
    func people() {
        let value="[{\"id\":\"author\",\"label\":\"Ana López\",\"kind\":\"person\"},{\"id\":\"group\",\"label\":\"Equipo\",\"kind\":\"group\"}]"
        #expect(DatabaseCardPresentation.people(value).map(\.label)==["Ana López","Equipo"])
        #expect(DatabaseCardPresentation.structuredValue(type:"created_by",raw:value)=="Ana López, Equipo")
        let column=PagesDatabasesParity.Column(id:"group",databaseId:"database",name:"Personas",type:"person",position:0,config:[:],options:[])
        let lanes=DatabaseCardPresentation.lanes(column:column,rows:[row("row",value)],config:[:])
        #expect(lanes.first(where:{$0.id=="author"})?.rows.count==1)
        #expect(lanes.first(where:{$0.id=="author"})?.label=="Ana López")
    }
    @Test("Structured dates and places display content without changing stored values")
    func properties() {
        let date="{\"start\":\"2026-10-25T01:30:00Z\",\"end\":\"2026-10-25T02:30:00Z\",\"includeTime\":true,\"timeZone\":\"Europe/Madrid\"}"
        let display=DatabaseCardPresentation.structuredValue(type:"date",raw:date)
        #expect(display?.contains(" – ")==true);#expect(display?.contains("\"start\"")==false)
        #expect(DatabaseCardPresentation.structuredValue(type:"location",raw:"{\"name\":\"Archivo\",\"address\":\"Calle Mayor\",\"latitude\":40.4}")=="Archivo · Calle Mayor")
        #expect(DatabaseCardPresentation.structuredValue(type:"number",raw:"123")==nil)
        #expect(DatabaseCardPresentation.structuredValue(type:"date",raw:"")=="")
    }
}
