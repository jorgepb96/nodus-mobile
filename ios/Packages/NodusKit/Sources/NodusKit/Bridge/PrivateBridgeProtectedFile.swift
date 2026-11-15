import Foundation

/// Foundation's file-protection write flags are iOS-specific. Keep each caller's
/// device protection there; Mac package hosts retain atomic 0600 files.
enum PrivateBridgeProtectedFile {
    static func write(_ data: Data, to url: URL, protection: Data.WritingOptions = .completeFileProtection) throws {
#if os(iOS)
        try data.write(to: url, options: protection.union(.atomic))
#else
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
#endif
    }
}
