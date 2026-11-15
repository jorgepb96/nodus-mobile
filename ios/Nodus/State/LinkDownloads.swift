import Foundation
import NodusKit
import NodusUI
import Observation
import SwiftUI

extension LinkDownloadSection {
    init?(route: NodusRoute) { self.init(rawValue: route.rawValue) }
    var title: LocalizedStringKey {
        switch self {
        case .ideas: "Ideas"
        case .authors: "Authors"
        case .dictionary: "Dictionary"
        case .deepResearch: "Deep Research"
        case .graph: "Graph"
        case .argument: "Argument map"
        case .library: "Library"
        case .podcast: "Podcasts"
        }
    }
}

/// Explicit local ownership, separate from the opportunistic consulted cache. Saving is an
/// atomic encrypted read-pack replacement; removing calls only local cache APIs, never a
/// Desktop mutation. The private cache enforces its per-download and per-Mac byte limits.
@Observable @MainActor
final class LinkDownloads {
    struct Copy {
        let revision: String
        let pack: PrivateBridgeCache.ReadPack
    }
    enum Status: Equatable {
        case live, downloaded, updates, offline, offlineDownloaded, checking, downloading
        var symbol: String {
            switch self {
            case .live: "dot.radiowaves.left.and.right"
            case .downloaded, .offlineDownloaded: "arrow.down.circle.fill"
            case .updates: "arrow.down"
            case .offline: "wifi.slash"
            case .checking: "clock"
            case .downloading: "arrow.down"
            }
        }
        var color: Color {
            switch self {
            case .live, .downloaded: .nodusSuccess
            case .updates: .nodusCaution
            default: .secondary
            }
        }
        var label: LocalizedStringKey {
            switch self {
            case .live: "Live · not downloaded"
            case .downloaded: "Downloaded · up to date"
            case .updates: "Changes available · tap to download"
            case .offline: "Offline · not downloaded"
            case .offlineDownloaded: "Offline · downloaded copy available"
            case .checking: "Checking downloaded copy"
            case .downloading: "Downloading"
            }
        }
    }
    private weak var session: SpaceSession?
    private(set) var copies: [LinkDownloadSection: Copy] = [:]
    private(set) var episodeCopies: [String: PrivateBridgeCache.ReadPack] = [:]
    private(set) var remoteRevisions: [LinkDownloadSection: String] = [:]
    private(set) var remoteAudioHashes: [String: String] = [:]
    private(set) var busy = Set<String>()
    private(set) var online = false
    @ObservationIgnored private var isChecking = false
    var issue: String?
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(session: SpaceSession) { self.session = session }
    private var reachable: Bool { online && session?.loadFailure == nil }
    func status(_ section: LinkDownloadSection) -> Status {
        if busy.contains(section.rawValue) { return .downloading }
        guard let copy = copies[section] else { return reachable ? .live : .offline }
        guard reachable else { return .offlineDownloaded }
        guard let revision = remoteRevisions[section] else { return .checking }
        return revision == copy.revision ? .downloaded : .updates
    }
    func episodeStatus(_ id: String) -> Status {
        if busy.contains("episode:" + id) { return .downloading }
        guard let copy = episodeCopies[id] else { return reachable ? .live : .offline }
        guard reachable else { return .offlineDownloaded }
        guard let hash = remoteAudioHashes[id] else { return .checking }
        return hash == copy.primaryFile?.sha256 ? .downloaded : .updates
    }
    private func context() throws -> (session: SpaceSession, vault: String, bridge: DesktopBridgeClient, cache: PrivateBridgeCache) {
        guard let session else { throw CancellationError() }
        let (vault, pairing, token) = try privateBridgeConnection(session, domain: .corpus)
        return (session, vault, DesktopBridgeClient(pairing: pairing, token: token), try PrivateBridgeCache(pairingId: pairing.id))
    }

    func reload() async {
        do {
            let context = try context(), packs = try await context.cache.readPacks(vaultId: context.vault)
            var found: [LinkDownloadSection: Copy] = [:], audio: [String: PrivateBridgeCache.ReadPack] = [:]
            for section in LinkDownloadSection.allCases {
                let id = try section.packId(vaultId: context.vault)
                guard let pack = packs.first(where: { $0.id == id }),
                      let data = try await context.cache.downloadedData(vaultId: context.vault, domain: .corpus, recordId: section.recordId).first,
                      let revision = try JSONDecoder.nodus.decode(JSONValue.self, from: data).objectValue?["revision"]?.stringValue else { continue }
                found[section] = Copy(revision: revision, pack: pack)
            }
            for pack in packs where pack.primaryFile?.kind == .podcastAudio {
                if let id = pack.primaryFile?.id, audio[id] == nil { audio[id] = pack }
            }
            copies = found; episodeCopies = audio
        } catch where error.isCancellation { }
        catch { issue = error.localizedDescription }
    }

    func checkForChanges() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        await reload()
        guard let context = try? context() else { return }
        // A cached overview is readable offline, but cannot prove a live connection.
        // Probe an authenticated HEAD before painting any unselected section green.
        do {
            _ = try await context.bridge.corpus(vaultId: context.vault, path: "snapshot", method: "HEAD", timeout: 4)
            online = true
        } catch where error.isCancellation { return }
        catch { online = false; return }
        var verified = false, unavailable = false
        for section in LinkDownloadSection.allCases where copies[section] != nil {
            if Task.isCancelled { return }
            do {
                let response = try await context.bridge.corpus(vaultId: context.vault, path: "downloads/sections/" + section.rawValue, method: "HEAD", timeout: 8)
                if let revision = response.headers.first(where: { $0.key.lowercased() == "x-nodus-revision" })?.value {
                    remoteRevisions[section] = revision; verified = true
                }
            } catch where error.isCancellation { return }
            catch { remoteRevisions[section] = nil; unavailable = unavailable || isPrivateBridgeOffline(error) }
        }
        for id in episodeCopies.keys {
            if Task.isCancelled { return }
            do {
                let descriptor = try await context.bridge.fileDescriptor(vaultId: context.vault, kind: .podcastAudio, id: id)
                remoteAudioHashes[id] = descriptor.sha256; verified = true
            } catch where error.isCancellation { return }
            catch { remoteAudioHashes[id] = nil; unavailable = unavailable || isPrivateBridgeOffline(error) }
        }
        if unavailable { online = false }
        else if verified || context.session.loadFailure == nil { online = true }
    }

    func download(_ section: LinkDownloadSection) {
        start(section.rawValue) { [weak self] in
            guard let self else { return }
            let context = try self.context()
            let response = try await context.bridge.corpus(vaultId: context.vault, path: "downloads/sections/" + section.rawValue)
            guard response.data.count <= PrivateBridgeCache.maximumSelectedCopyBytes - 64 * 1024,
                  var envelope = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data).objectValue,
                  envelope["version"] == .int(1), envelope["section"] == .string(section.rawValue),
                  envelope["snapshot"]?.objectValue?["vault"]?.objectValue?["id"] == .string(context.vault),
                  let revision = envelope["revision"]?.stringValue else { throw DesktopBridgeError.malformedResponse }
            envelope["settings"] = try await context.bridge.operation(vaultId: context.vault, method: "getSettings", args: [])
            let current = try await context.bridge.corpus(vaultId: context.vault, path: "downloads/sections/" + section.rawValue, method: "HEAD")
            guard current.headers.first(where: { $0.key.lowercased() == "x-nodus-revision" })?.value == revision else {
                throw APIError(status: 409, code: "section_changed", message: String(localized: "The section changed during download. Try again; your previous copy is preserved."))
            }
            try Task.checkCancellation()
            try await context.cache.saveReadPack(id: section.packId(vaultId: context.vault), vaultId: context.vault,
                title: String(localized: "Section download") + " · " + section.rawValue,
                expiresAt: Date().addingTimeInterval(30 * 86_400),
                records: [.init(domain: .corpus, recordId: section.recordId, data: JSONEncoder.nodus.encode(JSONValue.object(envelope)))])
            self.remoteRevisions[section] = revision; self.online = true
            await LinkSectionCopies.shared.invalidate()
            context.session.didChangeCompanionDownloads()
            await self.reload()
        }
    }

    func remove(_ section: LinkDownloadSection) async {
        await cancel(section.rawValue)
        do {
            let context = try context()
            try await context.cache.removeReadPack(id: section.packId(vaultId: context.vault), vaultId: context.vault)
            copies[section] = nil; remoteRevisions[section] = nil
            await LinkSectionCopies.shared.invalidate()
            context.session.didChangeCompanionDownloads()
        } catch where error.isCancellation { }
        catch { issue = error.localizedDescription }
    }

    func downloadEpisode(_ id: String, title: String) {
        start("episode:" + id) { [weak self] in
            guard let self else { return }
            let context = try self.context()
            let descriptor = try await context.bridge.fileDescriptor(vaultId: context.vault, kind: .podcastAudio, id: id)
            guard descriptor.byteSize <= PrivateBridgeCache.maximumSelectedCopyBytes - 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.perDownloadLimit }
            let detail = try await context.bridge.operation(vaultId: context.vault, method: "podcastEpisode", args: [.string(id)])
            guard detail.objectValue?["id"] == .string(id) else { throw DesktopBridgeError.malformedResponse }
            let bytes = try await context.bridge.fileData(vaultId: context.vault, descriptor: descriptor)
            let key = "file:\(descriptor.kind.rawValue):\(id)"
            var records: [PrivateBridgeCache.ReadPackRecord] = [
                .init(domain: descriptor.kind.domain, recordId: key, data: try JSONEncoder.nodus.encode(descriptor)),
                .init(domain: descriptor.kind.domain, recordId: key + ":" + descriptor.sha256, data: bytes),
                .init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("podcastEpisode", [.string(id)]), data: try JSONEncoder.nodus.encode(detail))]
            let image = try await context.bridge.operation(vaultId: context.vault, method: "podcastImageData", args: [.string(id), .int(0), .string("image")])
            for variant in ["image", "thumbnail"] {
                records.append(.init(domain: .corpus, recordId: try CompanionDocumentOutbox.operationKey("podcastImageData", [.string(id), .int(0), .string(variant)]), data: try JSONEncoder.nodus.encode(image)))
            }
            let current = try await context.bridge.fileDescriptor(vaultId: context.vault, kind: .podcastAudio, id: id)
            guard current.sha256 == descriptor.sha256 else { throw DesktopBridgeError.malformedResponse }
            try Task.checkCancellation()
            let packId = try PrivateBridgeCache.readPackSelectionId(vaultId: context.vault, recordIds: ["link:podcast:" + id])
            try await context.cache.saveReadPack(id: packId, vaultId: context.vault, title: title,
                expiresAt: Date().addingTimeInterval(30 * 86_400), records: records, primaryFile: descriptor)
            self.remoteAudioHashes[id] = descriptor.sha256; self.online = true
            await self.reload(); context.session.didChangeCompanionDownloads()
        }
    }

    func removeEpisode(_ id: String) async {
        await cancel("episode:" + id)
        do {
            let context = try context()
            if context.session.podcastPlayback.target?.id == id { context.session.podcastPlayback.stop() }
            for pack in try await context.cache.readPacks(vaultId: context.vault) where pack.primaryFile?.kind == .podcastAudio && pack.primaryFile?.id == id {
                if let file = pack.primaryFile {
                    let key = "file:\(file.kind.rawValue):\(id)"
                    try await context.cache.remove(vaultId: context.vault, domain: file.kind.domain, recordId: key)
                    try await context.cache.remove(vaultId: context.vault, domain: file.kind.domain, recordId: key + ":" + file.sha256)
                }
                try await context.cache.removeReadPack(id: pack.id, vaultId: context.vault)
            }
            episodeCopies[id] = nil; remoteAudioHashes[id] = nil
            await LinkSectionCopies.shared.invalidate(); context.session.didChangeCompanionDownloads()
        } catch where error.isCancellation { }
        catch { issue = error.localizedDescription }
    }

    func cancel(_ key: String) async {
        let task = tasks[key]; task?.cancel(); await task?.value
    }
    private func start(_ key: String, work: @escaping @MainActor () async throws -> Void) {
        guard tasks[key] == nil else { return }
        busy.insert(key); issue = nil
        tasks[key] = Task {
            defer { busy.remove(key); tasks[key] = nil }
            do { try await work() }
            catch where error.isCancellation { }
            catch { issue = error.localizedDescription; if isPrivateBridgeOffline(error) { online = false } }
        }
    }
}
