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
/// They stay on the device. Sending one to the server would need `write` access and would put
/// it in the ledger as a draft, which is a different act with a different consequence; that is
/// offered explicitly rather than done silently.
@Observable
@MainActor
final class LocalReportStore {
    struct Saved: Codable, Identifiable, Hashable {
        let id: String
        let report: DeepResearchReport
        let mode: DeepResearchMode
        let createdAt: Date
        let modelLabel: String

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

        var title: String { report.objective }
        var wasSent: Bool { sentAt != nil }
    }

    private(set) var reports: [Saved] = []
    private let directory: URL

    /// - Parameter root: where the `spaces` folder lives. Application Support everywhere except
    ///   in tests, which need a directory they can throw away rather than the test host's own.
    init(spaceId: String, root: URL = .applicationSupportDirectory) {
        directory = root
            .appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
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
    func save(_ report: DeepResearchReport, mode: DeepResearchMode, model: ModelRef) -> Saved {
        let saved = Saved(
            id: UUID().uuidString,
            report: report,
            mode: mode,
            createdAt: Date(),
            modelLabel: model.model,
            modelRef: model
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

    func delete(_ id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        reload()
    }

    private func write(_ saved: Saved) {
        guard let data = try? JSONEncoder.nodusReports.encode(saved) else { return }
        try? data.write(
            to: directory.appendingPathComponent("\(saved.id).json"),
            options: [.atomic, .completeFileProtectionUnlessOpen]
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
