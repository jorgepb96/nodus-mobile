import Foundation

/// Returns an isolated fixture directory on the volume selected by CI.
///
/// GitHub's macOS 15 image rejects SQLite opens under its per-user `/var/folders`
/// temporary directory. App storage is unaffected; only tests opt into the workspace path.
func testDatabaseDirectory(prefix: String) throws -> URL {
    let environmentRoot = ProcessInfo.processInfo.environment["NODUS_TEST_DATABASE_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
    let root = environmentRoot ?? FileManager.default.temporaryDirectory
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
