import Foundation

/// Reopening a companion must also show durable mutations that have not reached
/// the Mac. A canonical row at the acknowledged revision supersedes its overlay.
public enum CompanionContentProjection {
    static let keys:[String:[String]] = ["db_databases":["id"],"db_columns":["id"],"db_rows":["id"],"db_cells":["row_id","column_id"],"pages":["id"],"page_favorites":["page_id"]]
    public static func apply(_ source:[String:[Row]],mutations:[Mutation],states:[String:MutationOutbox.State])->[String:[Row]] {
        var result=source
        for mutation in mutations {
            guard let key=keys[mutation.table],key.count==mutation.key.count,let state=states[mutation.id],state != .rejected else {continue}
            let index=result[mutation.table]?.firstIndex{row in zip(key,mutation.key).allSatisfy{row.string($0.0)==$0.1}}
            if state == .delivered,mutation.table == "page_favorites" {continue}
            if state == .delivered,mutation.table == "db_cells",let incoming=mutation.row,
                let base=incoming["_mobileBaseRowRevision"]?.intValue,
                let parent=source["db_rows"]?.first(where:{$0.string("id")==mutation.key[0]}),
                let canonical=parent.columns["revision"]?.intValue,canonical > base {continue}
            if state == .delivered,let incoming=mutation.row,let index,
                let current=result[mutation.table]?[index].columns["revision"]?.intValue,
                let expected=incoming["revision"]?.intValue,current >= expected {continue}
            if mutation.kind == .delete {
                if let index {result[mutation.table]?.remove(at:index)}
            } else if var incoming=mutation.row {
                incoming["mobileSyncState"] = .string(state == .delivered ? "available":"pending")
                if let index {var row=result[mutation.table]![index].columns;row.merge(incoming){_,new in new};result[mutation.table]![index]=Row(row)}
                else {result[mutation.table,default:[]].append(Row(incoming))}
            }
        }
        return result
    }
}
