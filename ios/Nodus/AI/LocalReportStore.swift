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
        /// The illustration's filename, once one has been drawn. Optional so a report saved
        /// before illustrations existed still decodes.
        var imageFile: String?

        var title: String { report.objective }
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

    init(spaceId: String) {
        directory = URL.applicationSupportDirectory
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
    func save(_ report: DeepResearchReport, mode: DeepResearchMode, model: String) -> Saved {
        let saved = Saved(
            id: UUID().uuidString,
            report: report,
            mode: mode,
            createdAt: Date(),
            modelLabel: model
        )
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

    func delete(_ id: String) {
        if let saved = reports.first(where: { $0.id == id }), let name = saved.imageFile {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
        reload()
    }

    /// Replace a report in place, keeping its id, its date and its illustration.
    ///
    /// Used when a report written before the citations were resolved is opened and its sources
    /// are named from the corpus: the repair belongs on disk, not in one screen's memory.
    func replace(_ id: String, with report: DeepResearchReport) {
        guard var saved = reports.first(where: { $0.id == id }), saved.report != report else { return }
        saved = Saved(
            id: saved.id,
            report: report,
            mode: saved.mode,
            createdAt: saved.createdAt,
            modelLabel: saved.modelLabel,
            imageFile: saved.imageFile
        )
        write(saved)
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
