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
        /// Original rich Desktop turn. Portable edits preserve its attachments,
        /// tool output, citations and selection instead of flattening them.
        var desktopRecord: JSONValue?
        var studyCitations: [JSONValue]?
        var studyEvidence: JSONValue?
        var worldFacts: JSONValue?
        /// Optional for histories written by earlier releases. Each newly
        /// authored turn keeps its own time across reopening and synchronization.
        var createdAt: Date? = nil
        var reasoning:String? = nil
        var liveActivities:[JSONValue]? = nil

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
        var desktop: DesktopSync? = nil
        /// Chosen read-only copies expire; authoring makes the copy durable.
        var downloadedUntil: Date? = nil
        var isLocalRecovery: Bool? = nil
        var databaseIds: [String]? = nil
        var study: CompanionStudyChatOptions? = nil
        var world: CompanionWorldChatOptions? = nil
        var placement: CompanionChatPlacement? = nil
        var pendingLive: PendingLive? = nil

        var preview: String {
            messages.last(where: { $0.role == .assistant })?.text
                ?? messages.first?.text
                ?? ""
        }
    }

    struct PendingLive: Codable,Hashable {
        let pairingId:String
        let request:CompanionLiveChatRequest
        var sequence=0
        var issue:String?
        var activities:[JSONValue]? = nil
        var reasoning:String? = nil
        var concilium:JSONValue? = nil
    }

    struct DesktopSync: Codable, Hashable {
        enum State: String, Codable { case saved, pending, conflict, blocked }
        var kind: CompanionChatKind
        var baseline: CompanionChatDocument?
        var state: State = .pending
        var generation = 0
        var sending: JSONValue?
        var sendingGeneration: Int?
        var remote: CompanionChatDocument?
        var issue: String?
        var deleted = false
    }
    private static var sharedStores: [String:ChatHistoryStore] = [:]
    static func shared(spaceId: String) -> ChatHistoryStore {
        if let store = sharedStores[spaceId] { return store }
        let store = ChatHistoryStore(spaceId:spaceId)
        sharedStores[spaceId] = store
        store.recoverInterruptedReplies()
        return store
    }
    private var linkedKind: CompanionChatKind?
    private var linkGeneration = 0
    private var synchronizing = false

    private(set) var conversations: [Conversation] = []
    private(set) var issue: String?
    private(set) var organisation: CompanionChatOrganisation?
    private let directory: URL
    private let spaceId: String
    private let backup: CloudBackup?

    var active: [Conversation] { conversations.filter { !$0.isArchived && $0.desktop?.deleted != true }.sorted { ($0.placement?.pinned ?? false) == ($1.placement?.pinned ?? false) ? $0.updatedAt > $1.updatedAt:($0.placement?.pinned ?? false) } }
    var archived: [Conversation] { conversations.filter { $0.isArchived && $0.desktop?.deleted != true } }

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
        let metadata = directory.appendingPathComponent("organisation.snapshot")
        if FileManager.default.fileExists(atPath:metadata.path) {
            do { let saved = try JSONDecoder.nodus.decode(CompanionChatOrganisation.self,from:Data(contentsOf:metadata));try saved.validate(kind:saved.kind);organisation = saved }
            catch { issue = error.localizedDescription }
        }
    }

    func reload() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter { $0.pathExtension == "json" }
            var loaded: [Conversation] = [],failed = 0
            for file in files {
                do {
                    let conversation = try JSONDecoder.nodusReports.decode(Conversation.self,from:Data(contentsOf:file))
                    if let expiry = conversation.downloadedUntil,expiry <= Date(),conversation.desktop?.state == .saved {
                        try FileManager.default.removeItem(at:file)
                    } else { loaded.append(conversation) }
                }
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
        guard Self.validId(conversation.id) else { throw DesktopBridgeError.malformedResponse }
        var stored = conversation
        stored.updatedAt = Date()
        stored.downloadedUntil = nil
        if let existing = conversations.first(where:{$0.id == stored.id}) {
            guard existing.pendingLive == nil else { throw Self.liveInProgress }
            guard existing.desktop?.deleted != true else { throw APIError(status:409,code:"chat_deleted_locally",message:"This conversation is waiting to be deleted. Start a new conversation to continue.") }
            stored.isLocalRecovery = existing.isLocalRecovery
            if stored.placement == nil { stored.placement = existing.placement }
            if let current = existing.desktop { stored.desktop = current }
            for index in stored.messages.indices {
                if let original = existing.messages.first(where:{$0.id == stored.messages[index].id}) {
                    if let record = original.desktopRecord { stored.messages[index].desktopRecord = record }
                    if stored.messages[index].createdAt == nil { stored.messages[index].createdAt = original.createdAt }
                }
            }
        }
        if stored.desktop == nil,stored.isLocalRecovery != true,let linkedKind { stored.desktop = DesktopSync(kind:linkedKind,baseline:nil) }
        if var sync = stored.desktop {
            sync.generation += 1
            if sync.state == .saved { sync.state = .pending }
            if sync.state == .blocked { sync.state = .pending;sync.sending = nil;sync.sendingGeneration = nil;sync.issue = nil }
            stored.desktop = sync
        }
        try write(stored)
        return stored
    }
    private func write(_ stored: Conversation) throws {
        let file = directory.appendingPathComponent("\(stored.id).json")
        do {
            let data = try JSONEncoder.nodusReports.encode(stored)
            // The frozen lost-ACK request and original rich baseline can coexist
            // with a draft. Authored data is durable, not an expiring read pack.
            guard data.count <= 64 * 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try data.write(to:file,options:[.atomic,.completeFileProtection])
            // Does nothing at all unless the user has switched the iCloud copy on, which is the
            // default and the state most installs stay in.
            if stored.downloadedUntil == nil,stored.desktop?.deleted != true {
                backup?.record(.chat,spaceId:spaceId,id:stored.id,document:file,updatedAt:stored.updatedAt)
            }
        } catch { issue = error.localizedDescription;throw error }
        issue = nil
        conversations.removeAll { $0.id == stored.id };conversations.append(stored)
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    func setArchived(_ archived: Bool, for id: String) throws {
        guard var conversation = conversations.first(where: { $0.id == id }) else { return }
        conversation.isArchived = archived
        if archived { conversation.placement?.pinned = false }
        try save(conversation)
    }
    func rename(_ id:String,title:String) throws {
        let name = title.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count <= 120,var conversation = conversations.first(where:{$0.id == id}) else { throw DesktopBridgeError.malformedResponse }
        conversation.title = name;try save(conversation)
    }
    func retainOrganisation(_ value:CompanionChatOrganisation) throws {
        try value.validate(kind:linkedKind ?? value.kind)
        try JSONEncoder.nodus.encode(value).write(to:directory.appendingPathComponent("organisation.snapshot"),options:[.atomic,.completeFileProtection])
        organisation = value
    }
    func projectPreferences(_ id:String,session:SpaceSession) async throws -> CompanionChatOrganisation.Project {
        let kind = CompanionChatKind(vaultType:session.vaultType)
        do {
            guard let vault = session.vaultId else { throw DesktopBridgeError.permissionDenied }
            let page = try await ConnectionClient.companionChat(for:session.connection).chatHistoryPage(vaultId:vault,kind:kind)
            guard let metadata = page.organisation else { throw APIError(status:503,code:"chat_organisation_unsupported",message:"Actualiza Nodus en el Mac para compartir las instrucciones de este proyecto.") }
            try metadata.validate(kind:kind);try retainOrganisation(metadata)
        } catch { guard isPrivateBridgeOffline(error),organisation?.kind == kind else { throw error } }
        guard let project = organisation?.projects.first(where:{$0.id == id}) else { throw APIError(status:409,code:"chat_placement_unavailable",message:"El proyecto de esta conversación no está disponible. Revisa su organización en el historial.") }
        return project
    }
    func organize(_ id:String,placement:CompanionChatPlacement,title:String? = nil) throws {
        guard var conversation = conversations.first(where:{$0.id == id}) else { throw DesktopBridgeError.malformedResponse }
        if placement.pinned && conversation.isArchived { throw APIError(status:409,code:"chat_archived_pin",message:"Desarchiva la conversación antes de fijarla.") }
        if placement.pinned,conversation.placement?.pinned != true,active.filter({$0.placement?.pinned == true}).count >= 5 { throw APIError(status:409,code:"chat_pin_limit",message:"Puedes fijar hasta cinco conversaciones. Desfija una antes de añadir otra.") }
        if let organisation {
            guard placement.projectId.map({id in organisation.projects.contains(where:{$0.id == id})}) ?? true,
                  placement.folderId.map({id in organisation.folders.contains(where:{$0.id == id && $0.projectId == placement.projectId})}) ?? true,
                  placement.notebookId.map({id in organisation.notebooks.contains(where:{$0.id == id})}) ?? true,
                  organisation.kind == .research || placement.notebookId == nil || placement.projectId == nil && placement.folderId == nil else { throw APIError(status:409,code:"chat_placement_unavailable",message:"El destino ya no está disponible. Actualiza el historial del Mac.") }
        } else if placement.projectId != nil || placement.folderId != nil || placement.notebookId != nil { throw DesktopBridgeError.malformedResponse }
        if let title {
            let name = title.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !name.isEmpty,name.count <= 120 else { throw DesktopBridgeError.malformedResponse }
            conversation.title = name
        }
        conversation.placement = placement;try save(conversation)
    }

    func delete(_ id: String) throws {
        guard Self.validId(id) else { throw DesktopBridgeError.malformedResponse }
        guard conversations.first(where:{$0.id == id})?.pendingLive == nil else { throw Self.liveInProgress }
        if var conversation = conversations.first(where:{$0.id == id}),var sync = conversation.desktop {
            sync.deleted = true;sync.generation += 1
            if sync.state == .saved { sync.state = .pending }
            conversation.desktop = sync
            try write(conversation)
            backup?.forget(.chat,spaceId:spaceId,id:id)
            return
        }
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
        conversations.filter { $0.desktop?.deleted != true && scope.includes($0) }.count
    }

    func deleteAll(_ scope: Scope) throws {
        defer { reload() }
        let ids = conversations.filter { $0.desktop?.deleted != true && scope.includes($0) }.map(\.id)
        for id in ids {
            try delete(id)
        }
    }
    private static func validId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
    func bind(kind: CompanionChatKind) throws {
        linkedKind = kind
        for var conversation in conversations where conversation.desktop == nil && conversation.isLocalRecovery != true {
            conversation.desktop = DesktopSync(kind:kind,baseline:nil,generation:1)
            try write(conversation)
        }
    }
    private func recoverInterruptedReplies() {
        for var conversation in conversations where conversation.pendingLive == nil && conversation.messages.contains(where:{$0.delivery == .streaming}) {
            for index in conversation.messages.indices where conversation.messages[index].delivery == .streaming {
                conversation.messages[index].delivery = .cancelled
                conversation.messages[index].warning = String(localized:"This reply was interrupted. The received text is kept here.")
            }
            do { try save(conversation) } catch { issue = error.localizedDescription }
        }
    }
    /// Reading a selected Desktop chat is explicit. Only its complete document
    /// becomes a local companion copy; browsing the catalogue downloads no turns.
    func importDesktop(_ document: CompanionChatDocument) throws -> Conversation {
        try document.validate(kind:document.kind,id:document.id)
        guard Self.validId(document.id) else { throw DesktopBridgeError.malformedResponse }
        if let current = conversations.first(where:{$0.id == document.id}),let sync = current.desktop,sync.state != .saved {
            throw APIError(status:409,code:"chat_local_changes",message:"This conversation has mobile changes waiting to synchronize. They have been kept.")
        }
        var conversation = try Self.conversation(document)
        if conversations.first(where:{$0.id == document.id})?.downloadedUntil != nil || !conversations.contains(where:{$0.id == document.id}) {
            conversation.downloadedUntil = Date().addingTimeInterval(14 * 24 * 3600)
        }
        let existingBytes = try conversations.filter { $0.id != conversation.id && $0.downloadedUntil != nil }.reduce(0) { try $0 + JSONEncoder.nodusReports.encode($1).count }
        if conversation.downloadedUntil != nil,try existingBytes + JSONEncoder.nodusReports.encode(conversation).count > 50 * 1024 * 1024 {
            throw APIError(status:413,code:"chat_download_budget",message:"Conversation downloads have reached 50 MB. Remove a downloaded copy before adding another; your authored conversations are kept.")
        }
        try write(conversation)
        return conversation
    }
    func removeDownloaded(_ id: String) throws {
        guard let conversation = conversations.first(where:{$0.id == id}),conversation.downloadedUntil != nil,conversation.desktop?.state == .saved else { throw DesktopBridgeError.malformedResponse }
        try FileManager.default.removeItem(at:directory.appendingPathComponent("\(id).json"))
        backup?.forget(.chat,spaceId:spaceId,id:id);conversations.removeAll{$0.id == id}
    }
    func retainTemporaryDownload(_ id:String,until:Date) throws {
        guard var conversation=conversations.first(where:{$0.id == id}),until>Date() else { throw DesktopBridgeError.malformedResponse }
        // Authored conversations are already durable. Extending a chosen copy
        // does not turn it into a device edit or enqueue an unnecessary Mac save.
        guard let existing=conversation.downloadedUntil else { return }
        conversation.downloadedUntil=max(existing,until);try write(conversation)
        if let index=conversations.firstIndex(where:{$0.id == id}) { conversations[index]=conversation }
    }
    private static func conversation(_ document: CompanionChatDocument) throws -> Conversation {
        let object = document.data.objectValue!
        let preserved = document.companion?.objectValue?["messages"]?.arrayValue ?? []
        let records = object["messages"]!.arrayValue!
        let messages = try records.enumerated().map { index,record -> Message in
            let raw = record.objectValue!
            var native: Message?
            if index < preserved.count {
                let candidate = try? JSONDecoder.nodusReports.decode(Message.self,from:JSONEncoder.nodusReports.encode(preserved[index]))
                // Desktop may have edited or replaced the answer since the last
                // mobile save. Its old citation/warning cannot annotate new prose.
                if candidate?.text == raw["content"]?.stringValue,candidate?.role.rawValue == raw["role"]?.stringValue { native = candidate }
            }
            let id = native?.id ?? raw["id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
            return Message(id:id,role:raw["role"] == .string("assistant") ? .assistant:.user,text:raw["content"]!.stringValue!,citations:native?.citations ?? [],wasSemantic:native?.wasSemantic,warning:native?.warning,delivery:native?.delivery,desktopRecord:record,studyCitations:document.kind == .study ? raw["citations"]?.arrayValue ?? native?.studyCitations:nil,studyEvidence:native?.studyEvidence,worldFacts:native?.worldFacts,createdAt:raw["createdAt"]?.stringValue.flatMap(Self.messageDate) ?? native?.createdAt,reasoning:native?.reasoning,liveActivities:native?.liveActivities)
        }
        func date(_ key: String,_ alternate: String) -> Date {
            let raw = object[key]?.stringValue ?? object[alternate]?.stringValue ?? ""
            let fractional = ISO8601DateFormatter();fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
            return fractional.date(from:raw) ?? ISO8601DateFormatter().date(from:raw) ?? Date()
        }
        return Conversation(id:document.id,title:object["title"]!.stringValue!,messages:messages,createdAt:date("createdAt","created_at"),updatedAt:date("updatedAt","updated_at"),isArchived:object["archived"] == .bool(true),desktop:DesktopSync(kind:document.kind,baseline:document,state:.saved),databaseIds:object["databaseIds"]?.arrayValue?.compactMap(\.stringValue),study:document.kind == .study ? try CompanionStudyChatOptions.desktop(document.data):nil,world:document.kind == .world ? try CompanionWorldChatOptions.desktop(document.data):nil,placement:CompanionChatPlacement.desktop(document.data))
    }
    private static func messageDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter();fractional.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return fractional.date(from:raw) ?? ISO8601DateFormatter().date(from:raw)
    }
    private func request(_ conversation: Conversation,sync: DesktopSync) throws -> JSONValue {
        var fields: [String:JSONValue] = ["version":.int(1),"id":.string(UUID().uuidString),"conversationId":.string(conversation.id),"expectedRevision":sync.baseline.map { .string($0.revision) } ?? .null,"action":.string(sync.deleted ? "delete":"save")]
        if !sync.deleted {
            let messages = conversation.messages.map { message -> JSONValue in
                var raw = message.desktopRecord?.objectValue ?? [:]
                if raw["id"] == nil && (message.desktopRecord == nil || [.research,.study].contains(sync.kind)) { raw["id"] = .string(message.id.uuidString) }
                raw["role"] = .string(message.role.rawValue);raw["content"] = .string(message.text)
                if raw["createdAt"] == nil,let createdAt = message.createdAt {
                    let formatter = ISO8601DateFormatter();formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
                    raw["createdAt"] = .string(formatter.string(from:createdAt))
                }
                // Legacy Study messages require a date. Retain their recorded
                // conversation time; never replace it with the time of a retry.
                if sync.kind == .study && raw["createdAt"] == nil { raw["createdAt"] = .string(ISO8601DateFormatter().string(from:conversation.createdAt)) }
                if message.delivery == .failed { raw["error"] = .bool(true) }
                if sync.kind == .study && message.delivery == .cancelled { raw["interrupted"] = .bool(true) }
                if sync.kind == .study,message.desktopRecord == nil,let citations = message.studyCitations,!citations.isEmpty { raw["citations"] = .array(citations) }
                return .object(raw)
            }
            fields["draft"] = .object(["title":.string(conversation.title),"archived":.bool(conversation.isArchived),"messages":.array(messages)])
            if let placement = conversation.placement { var draft = fields["draft"]!.objectValue!;draft["placement"] = placement.value;fields["draft"] = .object(draft) }
            if sync.kind == .database,let ids = conversation.databaseIds {
                var draft = fields["draft"]!.objectValue!;draft["databaseIds"] = .array(ids.map(JSONValue.string));fields["draft"] = .object(draft)
            }
            if sync.kind == .study {
                var draft = fields["draft"]!.objectValue!
                if let options = conversation.study { draft["study"] = try options.value }
                var proofs: [String:JSONValue] = [:]
                for message in conversation.messages where message.desktopRecord == nil {
                    if let evidence = message.studyEvidence,let citations = message.studyCitations,!citations.isEmpty {
                        let ids = Set(citations.compactMap { $0.objectValue?["id"]?.stringValue })
                        proofs[message.id.uuidString] = .object((evidence.objectValue ?? [:]).filter { ids.contains($0.key) })
                    }
                }
                if !proofs.isEmpty { draft["studyEvidence"] = .object(proofs) }
                fields["draft"] = .object(draft)
            }
            if sync.kind == .world,let options = conversation.world {
                var draft = fields["draft"]!.objectValue!;draft["world"] = try options.value;fields["draft"] = .object(draft)
            }
            var native = conversation.messages
            for index in native.indices { native[index].desktopRecord = nil }
            fields["companion"] = .object(["messages":try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodusReports.encode(native))])
        }
        let request = JSONValue.object(fields)
        guard try JSONEncoder.nodus.encode(request).count <= 20 * 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        return request
    }
    private static var liveInProgress:APIError {
        APIError(status:409,code:"chat_live_pending",message:"Esta conversación tiene una respuesta pendiente del Mac. Puedes recuperarla o detenerla antes de cambiarla.")
    }
    /// One atomic own-file write freezes the question and creates its local
    /// reply placeholder. Ordinary history synchronization cannot send the
    /// placeholder while the Mac writes the acknowledged answer.
    func beginLive(_ proposed:Conversation,pairingId:String,generation:JSONValue,answerId:UUID) throws -> CompanionLiveChatRequest {
        guard !synchronizing,Self.validId(proposed.id),let kind=linkedKind else { throw Self.liveInProgress }
        var conversation=proposed
        let existing=conversations.first(where:{$0.id == proposed.id})
        guard existing?.pendingLive == nil,existing?.desktop?.deleted != true,
              existing?.desktop?.sending == nil,existing?.isLocalRecovery != true else { throw Self.liveInProgress }
        var sync=existing?.desktop ?? DesktopSync(kind:kind,baseline:nil)
        guard sync.kind == kind,[.saved,.pending].contains(sync.state) else { throw Self.liveInProgress }
        conversation.desktop=sync;conversation.placement=existing?.placement ?? proposed.placement
        conversation.updatedAt=Date();conversation.downloadedUntil=nil
        let id=UUID().uuidString
        var edit=try request(conversation,sync:sync).objectValue!
        edit["id"] = .string(id)
        let frozen=try CompanionLiveChatRequest(requestId:id,kind:kind,answerId:answerId.uuidString,edit:.object(edit),generation:generation)
        conversation.messages.append(Message(id:answerId,role:.assistant,text:"",citations:[],delivery:.streaming,createdAt:Date()))
        conversation.pendingLive=PendingLive(pairingId:pairingId,request:frozen)
        sync.state = .pending;sync.generation += 1;sync.issue=nil;conversation.desktop=sync
        try write(conversation);return frozen
    }
    func applyLiveEvents(id:String,requestId:String,events:[DesktopBridgeJob.Event]) throws {
        guard var conversation=conversations.first(where:{$0.id == id}),var pending=conversation.pendingLive,pending.request.requestId == requestId,
              let index=conversation.messages.firstIndex(where:{$0.id == UUID(uuidString:pending.request.answerId)}) else { return }
        var changed=false
        for event in events.sorted(by:{$0.sequence < $1.sequence}) where event.sequence > pending.sequence {
            pending.sequence=event.sequence;changed=true
            guard event.args.first == .string(requestId) else { continue }
            switch event.channel {
            case "mobile:chat:delta": if let text=event.args.dropFirst().first?.stringValue { conversation.messages[index].text += text }
            case "mobile:chat:replace": if let text=event.args.dropFirst().first?.stringValue { conversation.messages[index].text=text }
            case "mobile:chat:reasoning": if let text=event.args.dropFirst().first?.stringValue { pending.reasoning=(pending.reasoning ?? "")+text }
            case "mobile:chat:concilium": if let value=event.args.dropFirst().first,value.objectValue != nil { pending.concilium=value }
            case "mobile:chat:activity":
                if let value=event.args.dropFirst().first,let identity=value.objectValue?["id"]?.stringValue {
                    var activities=pending.activities ?? []
                    if let position=activities.firstIndex(where:{$0.objectValue?["id"] == .string(identity)}) { activities[position]=value } else { activities.append(value) }
                    if activities.count>120,let position=activities.firstIndex(where:{$0.objectValue?["status"] != .string("active")}) { activities.remove(at:position) }
                    pending.activities=activities
                }
            case "mobile:chat:checkpoint":
                if let raw=event.args.dropFirst().first?.objectValue?["delivery"]?.stringValue,let delivery=Message.Delivery(rawValue:raw) { conversation.messages[index].delivery=delivery }
            default: break
            }
        }
        guard changed else { return };conversation.pendingLive=pending;conversation.updatedAt=Date();try write(conversation)
    }
    func liveIssue(id:String,requestId:String,issue:String) throws {
        guard var conversation=conversations.first(where:{$0.id == id}),conversation.pendingLive?.request.requestId == requestId else { return }
        conversation.pendingLive?.issue=issue;try write(conversation)
    }
    func cancelUnsubmittedLive(id:String,request:CompanionLiveChatRequest) throws {
        guard var conversation=conversations.first(where:{$0.id == id}),conversation.pendingLive?.request == request else { return }
        conversation.messages.removeAll { $0.id == UUID(uuidString:request.answerId) && $0.text.isEmpty }
        conversation.pendingLive=nil;conversation.desktop?.state = .pending;conversation.desktop?.issue=nil
        try write(conversation)
    }
    func finishLive(_ value:JSONValue,request:CompanionLiveChatRequest) throws {
        let result=try CompanionLiveChatResult.decode(value,request:request)
        guard let original=conversations.first(where:{$0.id == request.conversationId}),original.pendingLive?.request == request else { return }
        var conversation=try Self.conversation(result.document)
        conversation.downloadedUntil=nil
        if let index=conversation.messages.firstIndex(where:{$0.id == UUID(uuidString:request.answerId)}) {
            conversation.messages[index].delivery=result.interrupted ? .cancelled:.completed
            conversation.messages[index].reasoning=original.pendingLive?.reasoning
            conversation.messages[index].liveActivities=Self.settleActivities(original.pendingLive?.activities,cancelled:result.interrupted)
            if result.interrupted { conversation.messages[index].warning="La generación se detuvo. El texto recibido se ha guardado." }
        }
        try write(conversation)
    }
    /// A cancelled/failed job has no successful result envelope. Recover the
    /// real Mac checkpoint if it still belongs to this frozen question. A CAS
    /// conflict keeps the mobile draft and exposes the remote for explicit choice.
    func finishInterruptedLive(id:String,request:CompanionLiveChatRequest,remote:CompanionChatDocument?,state:String,issue:String?) throws {
        guard var local=conversations.first(where:{$0.id == id}),local.pendingLive?.request == request else { return }
        for index in local.messages.indices where local.messages[index].id == UUID(uuidString:request.answerId) {
            local.messages[index].reasoning=local.pendingLive?.reasoning;local.messages[index].liveActivities=Self.settleActivities(local.pendingLive?.activities,cancelled:state == "cancelled")
        }
        if let remote {
            try remote.validate(kind:request.kind,id:id)
            if issue?.contains("chat_revision_conflict") == true {
                local.pendingLive=nil;local.desktop?.state = .conflict;local.desktop?.remote=remote;local.desktop?.issue=issue
                for index in local.messages.indices where local.messages[index].id == UUID(uuidString:request.answerId) { local.messages[index].delivery = .failed;local.messages[index].warning="El historial cambió en otro dispositivo. Se conserva esta respuesta para revisar el conflicto." }
                try write(local);return
            }
            let frozenQuestion=request.edit.objectValue?["draft"]?.objectValue?["messages"]?.arrayValue?.last
            let records=remote.data.objectValue?["messages"]?.arrayValue ?? []
            let questionPresent=records.contains(where:{$0.objectValue?["id"] == frozenQuestion?.objectValue?["id"] && $0.objectValue?["content"] == frozenQuestion?.objectValue?["content"]})
            if questionPresent {
                var recovered=try Self.conversation(remote);recovered.downloadedUntil=nil
                if let index=recovered.messages.firstIndex(where:{$0.id == UUID(uuidString:request.answerId)}) {
                    recovered.messages[index].delivery=state == "cancelled" ? .cancelled:.failed
                    recovered.messages[index].reasoning=local.pendingLive?.reasoning;recovered.messages[index].liveActivities=Self.settleActivities(local.pendingLive?.activities,cancelled:state == "cancelled")
                    recovered.messages[index].warning=issue ?? "Respuesta interrumpida. El texto recibido se conserva."
                } else if let partial=local.messages.first(where:{$0.id == UUID(uuidString:request.answerId)}),!partial.text.isEmpty {
                    var partial=partial;partial.delivery = .failed;partial.warning=issue;recovered.messages.append(partial)
                    recovered.desktop?.state = .pending;recovered.desktop?.generation += 1
                } else if !recovered.messages.isEmpty {
                    recovered.messages[recovered.messages.count-1].warning=issue ?? "La respuesta no pudo completarse. La pregunta se ha guardado."
                }
                try write(recovered);return
            }
            if state == "cancelled",remote.revision == local.desktop?.baseline?.revision { try cancelUnsubmittedLive(id:id,request:request);return }
            local.desktop?.state = .conflict;local.desktop?.remote=remote
        } else {
            if state == "cancelled",local.desktop?.baseline == nil { try cancelUnsubmittedLive(id:id,request:request);return }
            local.desktop?.state = .blocked
        }
        local.pendingLive=nil;local.desktop?.issue=issue
        for index in local.messages.indices where local.messages[index].id == UUID(uuidString:request.answerId) {
            local.messages[index].delivery=state == "cancelled" ? .cancelled:.failed;local.messages[index].warning=issue
        }
        try write(local)
    }
    private static func settleActivities(_ events:[JSONValue]?,cancelled:Bool) -> [JSONValue]? {
        events?.map { value in
            guard var raw=value.objectValue,raw["status"] == .string("active") else { return value }
            raw["status"] = .string(cancelled ? "cancelled":"failed");raw["finishedAt"] = .double(Date().timeIntervalSince1970*1000);return .object(raw)
        }
    }
    /// Serializes pending own work with revision checks and frozen request IDs.
    /// Edits arriving while a send awaits keep their newer generation. Read packs
    /// and metadata browsing never manufacture a saved acknowledgement.
    func synchronize(send: (CompanionChatKind,JSONValue) async throws -> JSONValue) async {
        guard !synchronizing else { return };synchronizing = true;defer { synchronizing = false }
        let linkIdentity = linkGeneration
        let ids = conversations.filter { $0.desktop?.state == .pending }.map(\.id)
        for id in ids {
            guard var conversation = conversations.first(where:{$0.id == id}),var sync = conversation.desktop,
                  conversation.pendingLive == nil,!conversation.messages.contains(where:{$0.delivery == .streaming}) else { continue }
            do {
                if sync.sending == nil {
                    if sync.deleted && sync.baseline == nil {
                        try FileManager.default.removeItem(at:directory.appendingPathComponent("\(id).json"));conversations.removeAll{$0.id == id};continue
                    }
                    sync.sending = try request(conversation,sync:sync);sync.sendingGeneration = sync.generation
                    conversation.desktop = sync;try write(conversation)
                }
                let request = sync.sending!,generation = sync.sendingGeneration!
                let response = try await send(sync.kind,request)
                guard linkIdentity == linkGeneration else { throw DesktopBridgeError.permissionDenied }
                guard response.objectValue?["id"] == request.objectValue?["id"],var latest = conversations.first(where:{$0.id == id}),var current = latest.desktop,current.sending == request else { throw DesktopBridgeError.malformedResponse }
                if response.objectValue?["deleted"] == .bool(true) {
                    guard request.objectValue?["action"] == .string("delete") else { throw DesktopBridgeError.malformedResponse }
                    try FileManager.default.removeItem(at:directory.appendingPathComponent("\(id).json"));conversations.removeAll{$0.id == id}
                } else {
                    guard let value = response.objectValue?["snapshot"] else { throw DesktopBridgeError.malformedResponse }
                    let document = try JSONDecoder.nodus.decode(CompanionChatDocument.self,from:JSONEncoder.nodus.encode(value))
                    try document.validate(kind:sync.kind,id:id)
                    current.baseline = document;current.sending = nil;current.sendingGeneration = nil;current.issue = nil;current.remote = nil
                    current.state = current.generation == generation ? .saved:.pending
                    if current.state == .saved { latest.placement = CompanionChatPlacement.desktop(document.data) }
                    let rawMessages = document.data.objectValue?["messages"]?.arrayValue ?? []
                    for index in latest.messages.indices {
                        let message = latest.messages[index]
                        let matching = rawMessages.first { value in
                            value.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) == message.id
                        } ?? (index < rawMessages.count ? rawMessages[index]:nil)
                        if let matching,matching.objectValue?["role"] == .string(message.role.rawValue),matching.objectValue?["content"] == .string(message.text) { latest.messages[index].desktopRecord = matching }
                    }
                    latest.desktop = current;try write(latest)
                }
            } catch {
                guard var latest = conversations.first(where:{$0.id == id}),var current = latest.desktop else { continue }
                if let api = error as? APIError,api.code == "chat_revision_conflict" {
                    current.state = .conflict
                    if let raw = api.details["remote"] { current.remote = try? JSONDecoder.nodus.decode(CompanionChatDocument.self,from:JSONEncoder.nodus.encode(raw)) }
                } else if let bridge = error as? DesktopBridgeError,bridge != .malformedResponse {
                    current.state = .blocked
                } else if let api = error as? APIError,api.status < 500 && !api.isRateLimited {
                    current.state = .blocked
                }
                current.issue = error.localizedDescription;latest.desktop = current
                do { try write(latest) } catch { issue = error.localizedDescription }
                if current.state == .pending { break }
            }
        }
    }
    /// Both choices preserve a local copy of the displaced draft. The Mac
    /// choice uses its exact rich document; the mobile choice explicitly rebases.
    func resolveConflict(id: String,keepMobile: Bool) throws {
        guard var conversation = conversations.first(where:{$0.id == id}),var sync = conversation.desktop,sync.state == .conflict else { throw DesktopBridgeError.malformedResponse }
        if let remote = sync.remote { try remote.validate(kind:sync.kind,id:id) }
        if !keepMobile,let remote = sync.remote {
            var recovered = conversation
            recovered.id = UUID().uuidString;recovered.desktop = nil;recovered.isLocalRecovery = true;recovered.downloadedUntil = nil
            recovered.title += " · " + String(localized:"Recovered copy")
            try write(recovered)
            try write(Self.conversation(remote));return
        }
        guard keepMobile else { throw DesktopBridgeError.malformedResponse }
        if let remote = sync.remote {
            var recovered = try Self.conversation(remote)
            recovered.id = UUID().uuidString;recovered.desktop = nil;recovered.isLocalRecovery = true
            recovered.title += " · " + String(localized:"Recovered copy")
            try write(recovered)
            let messages = remote.data.objectValue?["messages"]?.arrayValue ?? []
            for index in conversation.messages.indices {
                let message=conversation.messages[index]
                let rawId = message.desktopRecord?.objectValue?["id"]
                let raw = rawId.flatMap { identity in messages.first { $0.objectValue?["id"] == identity } } ?? messages.first { $0.objectValue?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) == message.id }
                if let raw { conversation.messages[index].desktopRecord = raw }
            }
        }
        sync.baseline = sync.remote;sync.remote = nil;sync.sending = nil;sync.sendingGeneration = nil;sync.state = .pending;sync.issue = nil;sync.generation += 1
        conversation.desktop = sync;try write(conversation)
    }
    func retrySynchronization(id: String) throws {
        guard var conversation = conversations.first(where:{$0.id == id}),var sync = conversation.desktop,sync.state == .blocked else { throw DesktopBridgeError.malformedResponse }
        sync.state = .pending;sync.issue = nil;conversation.desktop = sync;try write(conversation)
    }
    func revokeLink() throws {
        linkedKind = nil;linkGeneration += 1
        let metadata = directory.appendingPathComponent("organisation.snapshot")
        if FileManager.default.fileExists(atPath:metadata.path) { try FileManager.default.removeItem(at:metadata) };organisation = nil
        for var conversation in conversations {
            if conversation.downloadedUntil != nil {
                try FileManager.default.removeItem(at:directory.appendingPathComponent("\(conversation.id).json"))
                conversations.removeAll{$0.id == conversation.id}
            } else if var sync = conversation.desktop {
                sync.state = .blocked;sync.issue = DesktopBridgeError.permissionDenied.localizedDescription
                conversation.desktop = sync;try write(conversation)
            }
        }
    }
}
