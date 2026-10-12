import Foundation

/// Recovery always compares the complete canonical generation input, including
/// the exact source text and Mac model. A transport retry cannot buy another call.
public enum CompanionTranslationRecovery {
    public enum Decision: Sendable {
        case resume(DesktopJobLedger.Request)
        case recover(DesktopJobLedger.Request)
        case failed(DesktopJobLedger.Request)
        case create
        case none
    }

    public static func decide(request: JSONValue, records: [DesktopJobLedger.Request],
                              savedTranslationId: String?, explicit: Bool, pendingDeletion: Bool = false) -> Decision {
        // A queued owner deletion cannot be undone by reopening the reader.
        if pendingDeletion { return explicit ? .create : .none }
        guard let record = records.filter({ $0.method == "generateContentTranslation" && $0.args == [request] })
            .max(by: { $0.createdAt < $1.createdAt }) else { return explicit ? .create : .none }
        switch record.state {
        case "pending", "accepted", "running", "saved": return .resume(record)
        case "available":
            // A completed acknowledgement must be materialised before the user
            // can explicitly regenerate that same request.
            if explicit, let id = record.result?.objectValue?["id"]?.stringValue, id == savedTranslationId { return .create }
            return .recover(record)
        case "failed", "cancelled", "interrupted": return explicit ? .create : .failed(record)
        default: return .failed(record)
        }
    }
}
