import Foundation
import NodusAI
import Observation

/// Reports generated on this device, kept.
///
/// A Deep Research run is one model call per section and costs real money. Letting the result
/// vanish when the screen is dismissed — which is what happened before this existed — means
/// paying for it twice. They live in Application Support rather than Caches for the same
/// reason the mirror does: the system may empty Caches whenever it likes.
///
/// The local copy is always written first. Deep Research then offers it to the vault through
/// the authorised outbox when this account may write; a reader keeps the same durable local
/// copy and gets an explicit explanation instead of losing an expensive result.
@Observable
@MainActor
final class LocalReportStore {
    struct Saved: Codable, Identifiable, Hashable {
        let id: String
        /// `var` so `replace` can repair the prose without rebuilding the record around it —
        /// see the comment there for what a rebuild costs.
        var report: DeepResearchReport
        let mode: DeepResearchMode
        let createdAt: Date
        let modelLabel: String
        /// The illustration's filename, once one has been drawn. Optional so a report saved
        /// before illustrations existed still decodes.
        var imageFile: String?

        // Everything below is optional because it is younger than the stored format, and
        // `reload()` decodes inside a `compactMap`: a required field this app added later
        // would throw `keyNotFound` on every report already on disk and quietly drop the lot
        // from the list. The same reasoning, and the same shape, as `Connection.addedAt`
        // (`AppModel.swift:24`).

        /// When this report was put on the wire. Its presence is what "sent" means.
        var sentAt: Date?
        /// The outbox row it travelled as, so the tray and the report can name each other.
        var outboxId: String?
        /// The id minted for the `writing_saved_drafts` row in the vault.
        ///
        /// Kept so a second send is an upsert on the same row rather than a second copy of the
        /// report in the owner's Deep Research list — the desktop merges on the primary key.
        var vaultRowId: String?
        /// The model as a reference rather than a label.
        ///
        /// `modelLabel` is for reading; `ReportDraft.row` needs the provider too. Without this
        /// a report reopened from the library cannot be turned into a sendable row at all.
        var modelRef: ModelRef?
        /// Kept from the request, independently of later interface language changes.
        /// Nil for older records whose generation language was never recorded.
        var outputLanguage: String?
        /// The last time anything about this record changed, which is what decides an argument
        /// between two devices. `createdAt` cannot: attaching an illustration or marking a
        /// report sent changes the record without changing when it was written.
        var updatedAt: Date?

        var title: String { report.objective }
        var wasSent: Bool { sentAt != nil }
        /// Written before `updatedAt` existed, so it falls back to the only date it has.
        var lastChangedAt: Date { updatedAt ?? createdAt }
    }

    private(set) var reports: [Saved] = []
    private let directory: URL

    /// One store per space, shared by everything that reads or writes reports.
    ///
    /// Two instances over the same folder are two lists that disagree until both are reloaded,
    /// and the run that saves a report is no longer the screen that shows it — so "the report
    /// finished" has to reach the library without anybody asking the filesystem again.
    private static var stores: [String: LocalReportStore] = [:]

    static func shared(for spaceId: String) -> LocalReportStore {
        if let existing = stores[spaceId] { return existing }
        let store = LocalReportStore(spaceId: spaceId)
        stores[spaceId] = store
        return store
    }

    /// - Parameter root: where the `spaces` folder lives. Application Support everywhere except
    ///   in tests, which need a directory they can throw away rather than the test host's own.
    ///   Deliberately not routed through `shared(for:)`, which is a cache keyed on space alone
    ///   and would hand a second test the first one's directory.
    init(spaceId: String, root: URL = .applicationSupportDirectory) {
        self.spaceId = spaceId
        directory = Self.directory(spaceId: spaceId, root: root)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    private let spaceId: String

    /// Where one space's reports sit.
    ///
    /// `nonisolated static` for the same reason `ChatHistoryStore` has one: the iCloud copy has
    /// to find these files with no store to ask, for spaces that are not open.
    nonisolated static func directory(spaceId: String, root: URL = .applicationSupportDirectory) -> URL {
        root
            .appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
    }

    nonisolated static func fileURL(spaceId: String, id: String, root: URL = .applicationSupportDirectory) -> URL {
        directory(spaceId: spaceId, root: root).appendingPathComponent("\(id).json")
    }

    /// Every live store, told to read the folder again.
    ///
    /// Called after a fetch from iCloud has written files underneath them. A store that kept
    /// showing its own list would leave a report that had just arrived from the iPad invisible
    /// until the app was killed.
    static func reloadAll() {
        for store in stores.values { store.reload() }
    }

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        reports = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder.nodusReports.decode(Saved.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(
        _ report: DeepResearchReport,
        mode: DeepResearchMode,
        model: ModelRef,
        language: String? = nil,
        id: String = UUID().uuidString
    ) -> Saved {
        let saved = Saved(
            id: id,
            report: report,
            mode: mode,
            createdAt: Date(),
            modelLabel: model.model,
            modelRef: model,
            outputLanguage: language
        )
        write(saved)
        reload()
        return saved
    }

    /// Record that this report has left the device, and as what.
    ///
    /// Written back to the file rather than only to the array: `ResearchLibraryView` calls
    /// `reload()` every time it appears, so an in-memory flag would last exactly until the
    /// user navigated away from the report they had just sent.
    @discardableResult
    func markSent(_ id: String, outboxId: String, vaultRowId: String, at when: Date = Date()) -> Saved? {
        guard var saved = reports.first(where: { $0.id == id }) else { return nil }
        saved.sentAt = when
        saved.outboxId = outboxId
        saved.vaultRowId = vaultRowId
        write(saved)
        reload()
        return saved
    }

    /// Put the illustration beside the report and remember its name.
    ///
    /// The bytes are a file rather than a field in the JSON: a base64 picture inside a document
    /// that is decoded every time the library opens would make a list of twenty reports cost
    /// twenty megabytes of parsing to draw.
    @discardableResult
    func attach(_ image: GeneratedImage, to id: String) -> Saved? {
        guard var saved = reports.first(where: { $0.id == id }) else { return nil }
        let name = "\(id).\(image.fileExtension)"
        do {
            try image.data.write(
                to: directory.appendingPathComponent(name),
                options: [.atomic, .completeFileProtectionUnlessOpen]
            )
        } catch {
            return nil
        }
        saved.imageFile = name
        write(saved)
        reload()
        return saved
    }

    func imageURL(for saved: Saved) -> URL? {
        guard let name = saved.imageFile else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func removeImage(from id: String) {
        guard var saved = reports.first(where: { $0.id == id }), let name = saved.imageFile else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        saved.imageFile = nil
        write(saved)
        reload()
    }

    func delete(_ id: String) {
        if let saved = reports.first(where: { $0.id == id }), let name = saved.imageFile {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        // The copy in iCloud goes with it. A report that reappeared after being thrown away
        // would make the library untrustworthy, which is worse than not having a copy at all.
        CloudBackup.shared.forget(.report, spaceId: spaceId, id: id)
        reload()
    }

    /// Replace a report in place, keeping everything the record knows that the report does not.
    ///
    /// Used when a report written before the citations were resolved is opened and its sources
    /// are named from the corpus: the repair belongs on disk, not in one screen's memory.
    ///
    /// Mutated rather than rebuilt from a handful of fields. A fresh `Saved` has to be given
    /// every property by name, so each one added later is one that repairing a report silently
    /// drops — and two of them, `sentAt` and `vaultRowId`, are how this device knows the report
    /// has already gone to the vault and under which id. Losing them turns the next send into a
    /// second copy of the report in somebody's corpus.
    func replace(_ id: String, with report: DeepResearchReport) {
        guard var saved = reports.first(where: { $0.id == id }), saved.report != report else { return }
        saved.report = report
        write(saved)
        reload()
    }

    /// The one place a report reaches the disk, which is why it is also the one place it reaches
    /// iCloud. Stamping `updatedAt` here rather than at each caller means attaching an
    /// illustration, marking a report sent and repairing its citations all count as changes —
    /// which they are, as far as another device is concerned.
    private func write(_ saved: Saved) {
        var stamped = saved
        stamped.updatedAt = Date()
        guard let data = try? JSONEncoder.nodusReports.encode(stamped) else { return }
        let file = directory.appendingPathComponent("\(stamped.id).json")
        try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        CloudBackup.shared.record(
            .report,
            spaceId: spaceId,
            id: stamped.id,
            document: file,
            illustration: stamped.imageFile.map { directory.appendingPathComponent($0) },
            illustrationName: stamped.imageFile,
            updatedAt: stamped.updatedAt ?? Date()
        )
    }
}

// Built per call rather than shared. A `JSONDecoder` is not `Sendable`, and a stored one would
// have to be pinned to an actor — which the Deep Research checkpoint cannot honour, because it
// is written from whichever thread finished a section. Constructing one costs nothing next to
// the file read it accompanies.
extension JSONDecoder {
    nonisolated static var nodusReports: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    nonisolated static var nodusReports: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
