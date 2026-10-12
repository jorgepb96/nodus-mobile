import Foundation

/// Foundation's completeFileProtection write flag is iOS-specific. Keep the
/// same device protection there; Mac package hosts retain atomic 0600 files.
enum PrivateBridgeProtectedFile {
    static func write(_ data: Data, to url: URL) throws {
#if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#endif
    }
}
