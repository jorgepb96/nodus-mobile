import Foundation
import GRDB

/// Serializes only the brief SQLite handle creation performed while a store starts.
///
/// Store operations remain independently concurrent after this call returns. Keeping the
/// gate here also protects real launches where the mirror, mutation outbox and account
/// library can all be restored by separate tasks at the same time.
enum SerializedDatabaseOpen {
    private static let lock = NSLock()

    static func queue(
        path: String,
        configuration: Configuration = Configuration()
    ) throws -> DatabaseQueue {
        lock.lock()
        defer { lock.unlock() }
        return try DatabaseQueue(path: path, configuration: configuration)
    }
}
