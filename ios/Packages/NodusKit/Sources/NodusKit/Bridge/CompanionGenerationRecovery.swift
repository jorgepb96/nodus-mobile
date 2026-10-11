import Foundation

public enum CompanionGenerationRecovery {
    /// Only unfinished work with the same inputs can resume. A definite failed
    /// publication needs a new explicit attempt against current sources; the
    /// previous paid response remains in the ledger for consultation.
    public static func resumeAcademic(checkpoint: JSONValue?, work: JSONValue, receiptState: String?) -> Bool {
        guard let value = checkpoint?.objectValue, value["request"] == work,
              let id = value["id"]?.stringValue, UUID(uuidString: id) != nil else { return false }
        if let receiptState { return ["pending", "accepted", "running", "saved"].contains(receiptState) }
        return ["accepted", "running", "saved"].contains(value["state"]?.stringValue ?? "")
    }
}
