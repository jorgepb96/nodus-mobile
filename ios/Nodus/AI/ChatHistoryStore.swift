import Foundation
import NodusAI
import NodusKit
import Observation

/// Conversations with the vault, kept.
///
/// A chat turn costs a retrieval and a model call, and until now the whole exchange vanished
/// the moment the tab changed — the app's own answers were the one thing it did not keep. They
/// live in Application Support beside the reports, per space, for the same reason: the system
/// may empty Caches whenever it likes.
///
/// What is saved is the conversation, not the run. The retrieved material a turn was built
/// from is deliberately dropped: it is a snapshot of a corpus at one moment, it is by far the
/// largest part of a turn, and re-reading it later would show material the answer may no
/// longer rest on. The citations survive, because those are claims the answer actually made.
@Observable
@MainActor
final class ChatHistoryStore {
    struct Message: Codable, Identifiable, Hashable {
        var id = UUID()
        var role: Role
        var text: String
        var citations: [CitationCatalog.Entry]
        /// Whether the material behind it was ranked by meaning or by spelling.
        var wasSemantic: Bool?
        var warning: String?
        var delivery: Delivery?

        enum Role: String, Codable { case user, assistant }
        enum Delivery: String, Codable { case streaming, completed, cancelled, failed }
    }

    struct Conversation: Codable, Identifiable, Hashable {
        var id: String
        var title: String
        var messages: [Message]
        var createdAt: Date
        var updatedAt: Date
        /// Out of the way but not gone. The desktop's own history works the same.
        var isArchived: Bool

        var preview: String {
            messages.last(where: { $0.role == .assistant })?.text
                ?? messages.first?.text
                ?? ""
        }
    }

    private(set) var conversations: [Conversation] = []
    private(set) var issue: String?
    private let directory: URL
    private let spaceId: String
    private let backup: CloudBackup?

    var active: [Conversation] { conversations.filter { !$0.isArchived } }
    var archived: [Conversation] { conversations.filter(\.isArchived) }

    /// Where one space's conversations sit.
    ///
    /// `nonisolated static` because the iCloud copy has to find these files without a store to
    /// ask — it runs before any chat screen exists, and often for spaces that are not open. One
    /// definition of the path, so a sync and a store cannot disagree about where a chat lives.
    nonisolated static func directory(spaceId: String, root: URL = .applicationSupportDirectory) -> URL {
        root
            .appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
    }

    nonisolated static func fileURL(spaceId: String, id: String, root: URL = .applicationSupportDirectory) -> URL {
        directory(spaceId: spaceId, root: root).appendingPathComponent("\(id).json")
    }

    init(spaceId: String,root: URL = .applicationSupportDirectory,backup: CloudBackup? = .shared) {
        self.spaceId = spaceId
        self.backup = backup
        directory = Self.directory(spaceId: spaceId,root:root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }
            var loaded: [Conversation] = [],failed = 0
            for file in files {
                do { loaded.append(try JSONDecoder.nodusReports.decode(Conversation.self,from:Data(contentsOf:file))) }
                catch { failed += 1 }
            }
            conversations = loaded.sorted { $0.updatedAt > $1.updatedAt }
            issue = failed > 0 ? String(localized:"Some conversations could not be read. Their files are kept on this device."):nil
        } catch { issue = error.localizedDescription }
    }

    /// The title is the question that opened the conversation, trimmed to a line.
    static func title(from question: String) -> String {
        let clean = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(80))
    }

    @discardableResult
    func save(_ conversation: Conversation) throws -> Conversation {
        guard UUID(uuidString:conversation.id) != nil else { throw DesktopBridgeError.malformedResponse }
        var stored = conversation
        stored.updatedAt = Date()
        let file = directory.appendingPathComponent("\(stored.id).json")
        do {
            let data = try JSONEncoder.nodusReports.encode(stored)
            guard data.count <= 20_000_000 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try data.write(to:file,options:[.atomic,.completeFileProtection])
            // Does nothing at all unless the user has switched the iCloud copy on, which is the
            // default and the state most installs stay in.
            backup?.record(.chat,spaceId:spaceId,id:stored.id,document:file,updatedAt:stored.updatedAt)
        } catch { issue = error.localizedDescription;throw error }
        issue = nil
        conversations.removeAll { $0.id == stored.id };conversations.append(stored)
        conversations.sort { $0.updatedAt > $1.updatedAt }
        return stored
    }

    func setArchived(_ archived: Bool, for id: String) throws {
        guard var conversation = conversations.first(where: { $0.id == id }) else { return }
        conversation.isArchived = archived
        try save(conversation)
    }

    func delete(_ id: String) throws {
        guard UUID(uuidString:id) != nil else { throw DesktopBridgeError.malformedResponse }
        try FileManager.default.removeItem(at:directory.appendingPathComponent("\(id).json"))
        // Deleting means deleting, in both places. A conversation that came back from iCloud
        // after the user threw it away would be the worst thing this feature could do.
        backup?.forget(.chat,spaceId:spaceId,id:id)
        reload()
    }

    /// Which conversations a bulk delete is about.
    ///
    /// Named rather than a `Bool`, because the two lists are shown on separate tabs and the
    /// question "delete all" means the tab you are looking at. A flag read the other way round
    /// would empty the archive from the screen that never mentions it.
    enum Scope: Sendable {
        case active, archived, everything

        func includes(_ conversation: Conversation) -> Bool {
            switch self {
            case .active: return !conversation.isArchived
            case .archived: return conversation.isArchived
            case .everything: return true
            }
        }
    }

    func count(_ scope: Scope) -> Int {
        conversations.filter(scope.includes).count
    }

    func deleteAll(_ scope: Scope) throws {
        defer { reload() }
        for conversation in conversations where scope.includes(conversation) {
            guard UUID(uuidString:conversation.id) != nil else { throw DesktopBridgeError.malformedResponse }
            try FileManager.default.removeItem(at:directory.appendingPathComponent("\(conversation.id).json"))
            backup?.forget(.chat,spaceId:spaceId,id:conversation.id)
        }
    }
}
