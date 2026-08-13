import CryptoKit
import Foundation
import ZIPFoundation

public actor PublishedLibraryStore {
    private static let maximumPackageBytes = 128 * 1024 * 1024
    private static let maximumExpandedBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumEntryCount = 2_048
    private static let allowedFigureExtensions = Set(["png", "jpg", "jpeg", "webp", "gif", "svg"])

    public enum StoreError: LocalizedError {
        case unavailable, corruptPackage, unsafeArchive, missingMarkdown

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "This document has no Clean Markdown package."
            case .corruptPackage: return "The downloaded document did not match its published fingerprint."
            case .unsafeArchive: return "The document package contains an unsafe path."
            case .missingMarkdown: return "The document package does not contain Clean Markdown."
            }
        }
    }

    public struct Download: Sendable, Hashable, Codable, Identifiable {
        public let id: String
        public let packageHash: String
        public let downloadedAt: Date
        public let bytes: Int
    }

    private let spaceId: String
    private let root: URL
    private var downloads: [String: Download] = [:]

    public struct Catalog: Sendable, Codable {
        public let collections: [PublishedLibraryCollection]
        public let documents: [PublishedLibraryDocument]
        public let savedAt: Date

        public init(collections: [PublishedLibraryCollection], documents: [PublishedLibraryDocument], savedAt: Date = Date()) {
            self.collections = collections; self.documents = documents; self.savedAt = savedAt
        }
    }

    public init(spaceId: String, root: URL = .applicationSupportDirectory) {
        self.spaceId = spaceId
        self.root = root.appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(spaceId, isDirectory: true)
            .appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: self.root.appendingPathComponent("downloads.json")),
           let values = try? JSONDecoder.nodus.decode([String: Download].self, from: data) {
            downloads = values
        }
    }

    public func allDownloads() -> [Download] { downloads.values.sorted { $0.downloadedAt > $1.downloadedAt } }
    public func catalog() -> Catalog? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("catalog.json")) else { return nil }
        return try? JSONDecoder.nodus.decode(Catalog.self, from: data)
    }
    public func saveCatalog(collections: [PublishedLibraryCollection], documents: [PublishedLibraryDocument]) {
        guard let data = try? JSONEncoder.nodus.encode(Catalog(collections: collections, documents: documents)) else { return }
        try? data.write(to: root.appendingPathComponent("catalog.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    public func isDownloaded(_ id: String, packageHash: String? = nil) -> Bool {
        guard let value = downloads[id], FileManager.default.fileExists(atPath: markdownURL(id).path) else { return false }
        return packageHash == nil || value.packageHash == packageHash
    }
    public func markdown(_ id: String) throws -> String {
        try String(contentsOf: markdownURL(id), encoding: .utf8)
    }
    public func documentDirectory(_ id: String) -> URL { directory(id) }
    public func packageURL(_ id: String) -> URL? {
        let value = directory(id).appendingPathComponent("package.zip")
        return FileManager.default.fileExists(atPath: value.path) ? value : nil
    }
    public func figures(_ id: String) -> [URL] {
        let assets = directory(id).appendingPathComponent("assets", isDirectory: true)
        let allowed = Set(["png", "jpg", "jpeg", "webp", "gif", "svg"])
        guard let enumerator = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { allowed.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    @discardableResult
    public func download(_ document: PublishedLibraryDocument, using client: NodusClient) async throws -> String {
        guard document.cleanAvailable, let hash = document.packageHash else { throw StoreError.unavailable }
        if isDownloaded(document.id, packageHash: hash) { return try markdown(document.id) }
        let bytes = try await client.publishedLibraryPackage(document.id, in: spaceId)
        guard bytes.count <= Self.maximumPackageBytes, Self.sha256(bytes) == hash else { throw StoreError.corruptPackage }

        let manager = FileManager.default
        let temporaryRoot = manager.temporaryDirectory.appendingPathComponent("nodus-library-\(UUID().uuidString)", isDirectory: true)
        let zipURL = temporaryRoot.appendingPathComponent("document.zip")
        let extracted = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        try bytes.write(to: zipURL, options: .atomic)
        defer { try? manager.removeItem(at: temporaryRoot) }
        let archive: Archive
        do { archive = try Archive(url: zipURL, accessMode: .read) }
        catch { throw StoreError.corruptPackage }
        var expandedBytes: UInt64 = 0
        var entryCount = 0
        for entry in archive {
            entryCount += 1
            expandedBytes += UInt64(entry.uncompressedSize)
            guard entryCount <= Self.maximumEntryCount, expandedBytes <= Self.maximumExpandedBytes else {
                throw StoreError.unsafeArchive
            }
            let relative = entry.path.replacingOccurrences(of: "\\", with: "/")
            let components = relative.split(separator: "/")
            guard !relative.hasPrefix("/"), !relative.contains(":"), !components.contains("..") else {
                throw StoreError.unsafeArchive
            }
            if entry.type == .file {
                let isManifest = relative == "manifest.json"
                let isMarkdown = relative == "document.md"
                let isFigure = relative.hasPrefix("assets/")
                    && Self.allowedFigureExtensions.contains(URL(fileURLWithPath: relative).pathExtension.lowercased())
                guard isManifest || isMarkdown || isFigure else { throw StoreError.unsafeArchive }
            } else if entry.type != .directory {
                throw StoreError.unsafeArchive
            }
            let target = extracted.appendingPathComponent(relative)
            let resolvedRoot = extracted.standardizedFileURL.path
            guard target.standardizedFileURL.path.hasPrefix(resolvedRoot + "/") else { throw StoreError.unsafeArchive }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }
        guard manager.fileExists(atPath: extracted.appendingPathComponent("document.md").path) else { throw StoreError.missingMarkdown }

        let destination = directory(document.id)
        let replacement = root.appendingPathComponent(".replacement-\(UUID().uuidString)", isDirectory: true)
        try manager.moveItem(at: extracted, to: replacement)
        try bytes.write(to: replacement.appendingPathComponent("package.zip"), options: .atomic)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: replacement, to: destination)
        downloads[document.id] = Download(id: document.id, packageHash: hash, downloadedAt: Date(), bytes: bytes.count)
        persist()
        return try markdown(document.id)
    }

    public func remove(_ ids: Set<String>) {
        for id in ids { try? FileManager.default.removeItem(at: directory(id)); downloads.removeValue(forKey: id) }
        persist()
    }

    public func removeAll() { remove(Set(downloads.keys)) }

    public static func removeAllSpaces(root: URL = .applicationSupportDirectory) throws {
        let spaces = root.appendingPathComponent("spaces", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(at: spaces, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            let library = folder.appendingPathComponent("library", isDirectory: true)
            let index = library.appendingPathComponent("downloads.json")
            guard let data = try? Data(contentsOf: index),
                  let downloads = try? JSONDecoder.nodus.decode([String: Download].self, from: data) else { continue }
            for id in downloads.keys {
                try? FileManager.default.removeItem(at: library.appendingPathComponent(Self.sha256(Data(id.utf8)), isDirectory: true))
            }
            if let empty = try? JSONEncoder.nodus.encode([String: Download]()) {
                try? empty.write(to: index, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
        }
    }

    private func directory(_ id: String) -> URL { root.appendingPathComponent(Self.sha256(Data(id.utf8)), isDirectory: true) }
    private func markdownURL(_ id: String) -> URL { directory(id).appendingPathComponent("document.md") }
    private func persist() {
        guard let data = try? JSONEncoder.nodus.encode(downloads) else { return }
        try? data.write(to: root.appendingPathComponent("downloads.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
