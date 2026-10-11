import Foundation

/// Reopening a companion must also show durable mutations that have not reached
/// the Mac. A canonical row at the acknowledged revision supersedes its overlay.
public enum CompanionContentProjection {
    static let keys:[String:[String]] = {
        var value = ["db_databases":["id"],"db_columns":["id"],"db_rows":["id"],"db_cells":["row_id","column_id"],"pages":["id"],"page_favorites":["page_id"]]
        for table in MutableTable.companionWorldTables { value[table.rawValue] = table.identityFields }
        return value
    }()
    public static func apply(_ source:[String:[Row]],mutations:[Mutation],states:[String:MutationOutbox.State])->[String:[Row]] {
        var result=source
        for mutation in mutations {
            guard let key=keys[mutation.table],key.count==mutation.key.count,let state=states[mutation.id],state != .rejected else {continue}
            let index=result[mutation.table]?.firstIndex{row in zip(key,mutation.key).allSatisfy{row.string($0.0)==$0.1}}
            let canonical = source[mutation.table]?.first{row in zip(key,mutation.key).allSatisfy{row.string($0.0)==$0.1}}
            if state == .delivered,mutation.table == "page_favorites" {continue}
            if state == .delivered,mutation.table == "db_cells",let incoming=mutation.row,
                let base=incoming["_mobileBaseRowRevision"]?.intValue,
                let parent=source["db_rows"]?.first(where:{$0.string("id")==mutation.key[0]}),
                let canonical=parent.columns["revision"]?.intValue,canonical > base {continue}
            if state == .delivered,let incoming=mutation.row,
                let current=canonical?.columns["revision"]?.intValue,
                let expected=incoming["revision"]?.intValue,current >= expected {continue}
            if state == .delivered, let table = MutableTable(rawValue: mutation.table), MutableTable.companionWorldTables.contains(table),
               let incoming = mutation.row, let stamp = incoming["updated_at"]?.stringValue,
               let current = canonical?.string("updated_at"), let currentDate = date(current), let incomingDate = date(stamp),
               currentDate >= incomingDate { continue }
            if state == .delivered, let incoming = mutation.row, let canonical,
               incoming.allSatisfy({ $0.key.hasPrefix("_mobile") || canonical.columns[$0.key] == $0.value }) { continue }
            if state == .delivered, mutation.kind == .delete, let canonical,
               let stamp = canonical.string("updated_at") ?? canonical.string("created_at"),
               let current = date(stamp), current > mutation.createdAt { continue }
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

    /// Repository deletions are durable jobs, not raw parent-row tombstones.
    /// Show that intent on reopening while retaining failed/cancelled entities.
    public static func applyWorldDeletions(_ source:[String:[Row]], requests:[DesktopJobLedger.Request]) -> [String:[Row]] {
        let owners:[String:(String,String)] = ["article":("world_articles","article_id"), "character":("persons","person_id"),
            "place":("places","place_id"), "group":("world_groups","group_id"), "scene":("world_scenes","scene_id"),
            "thread":("world_threads","thread_id"), "rule":("world_rules","rule_id"), "question":("world_questions","question_id")]
        var result = source
        for request in requests where request.method == "runMobileSpaceAction" && request.cancellationRequested != true
            && ["pending","accepted","running","saved","available"].contains(request.state) {
            guard let action = request.args.first?.objectValue, action["kind"] == .string("worldbuilding.entityDelete"),
                  let payload = action["payload"]?.objectValue, let entity = payload["entity"]?.stringValue,
                  let id = payload["id"]?.stringValue, let owner = owners[entity] else { continue }
            if request.state == "available", let canonical = source[owner.0]?.first(where:{$0.string(owner.1)==id}),
               let stamp = canonical.string("updated_at") ?? canonical.string("created_at"), let time = date(stamp),
               time > (request.macUpdatedAt ?? request.createdAt) { continue }
            result[owner.0]?.removeAll{ $0.string(owner.1) == id }
            for table in MutableTable.companionWorldTables where table.rawValue != owner.0 {
                result[table.rawValue]?.removeAll { row in
                    if row.string("entity_kind") == entity && row.string("entity_id") == id { return true }
                    if row.string("source_kind") == (entity == "thread" ? "conflict" : entity) && row.string("source_id") == id { return true }
                    if entity == "character", row.string("party_kind") == "character" && row.string("party_id") == id { return true }
                    if entity == "group", row.string("party_kind") == "group" && row.string("party_id") == id { return true }
                    if entity == "rule", table == .worldBeats { return row.string("thread_kind") == "rule" && row.string("thread_id") == id }
                    if entity == "thread", table == .worldBeats { return row.string("thread_kind") != "rule" && row.string("thread_id") == id }
                    if entity == "rule" { return false } // Rule exceptions are reparented by the canonical repository.
                    return row.string(owner.1) == id
                }
            }
        }
        return result
    }
    private static func date(_ stamp:String) -> Date? {
        ISO8601DateFormatter.nodusFractional.date(from:stamp) ?? ISO8601DateFormatter.nodusPlain.date(from:stamp)
    }
}
