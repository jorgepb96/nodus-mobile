import CryptoKit
import Foundation
import ZIPFoundation

public actor PublishedLibraryStore {
    private static let maximumPackageBytes = 128 * 1024 * 1024
    private static let maximumExpandedBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumOriginalBytes: UInt64 = 96 * 1024 * 1024
    private static let maximumEntryCount = 2_048
    private static let allowedFigureExtensions = Set(["png", "jpg", "jpeg", "webp", "gif", "svg"])
    private static let allowedOriginalExtensions = Set([
        "pdf", "epub", "md", "markdown", "txt", "csv", "tsv", "xml", "jats", "html", "htm",
        "png", "jpg", "jpeg", "webp", "gif", "bmp", "svg", "tif", "tiff",
        "docx", "odt", "rtf", "pptx", "odp", "xlsx", "ods",
    ])

    public enum StoreError: LocalizedError, Equatable {
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

    public struct PreparedContent: Sendable, Hashable {
        public let markdown: String?
        public let original: URL?
        public let package: URL
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

    public init(spaceId: String, storageId: String? = nil, root: URL = .applicationSupportDirectory) {
        self.spaceId = spaceId
        self.root = root.appendingPathComponent("spaces", isDirectory: true)
            .appendingPathComponent(storageId ?? spaceId, isDirectory: true)
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
        try? PrivateBridgeProtectedFile.write(data, to: root.appendingPathComponent("catalog.json"), protection: .completeFileProtectionUnlessOpen)
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
    public func originalURL(_ id: String) -> URL? {
        let folder = directory(id).appendingPathComponent("original", isDirectory: true)
        guard let values = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return nil }
        return values.first { Self.allowedOriginalExtensions.contains($0.pathExtension.lowercased()) }
    }
    public func figures(_ id: String) -> [URL] {
        let assets = directory(id).appendingPathComponent("assets", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { Self.allowedFigureExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }

    @discardableResult
    public func download(_ document: PublishedLibraryDocument, using client: NodusClient) async throws -> String {
        guard document.cleanAvailable else { throw StoreError.unavailable }
        let content = try await prepare(document, using: client)
        guard let markdown = content.markdown else { throw StoreError.missingMarkdown }
        return markdown
    }

    public func prepare(_ document: PublishedLibraryDocument, using client: NodusClient) async throws -> PreparedContent {
        // Live catalogues defer ZIP construction until a document is opened. Resolve
        // its current signed-in descriptor before validating the content hash.
        let document = document.packageHash == nil
            ? try await client.publishedLibraryDocument(document.id, in: spaceId)
            : document
        guard document.cleanAvailable || document.originalAvailable, let hash = document.packageHash else { throw StoreError.unavailable }
        if isDownloaded(document.id, packageHash: hash), let package = packageURL(document.id) {
            return PreparedContent(
                markdown: try? markdown(document.id),
                original: originalURL(document.id),
                package: package
            )
        }
        let bytes = try await client.publishedLibraryPackage(document.id, in: spaceId)
        guard bytes.count <= Self.maximumPackageBytes, Self.sha256(bytes) == hash else { throw StoreError.corruptPackage }
        return try installPackage(document, package: bytes)
    }

    /// Validate and atomically install one server package. Kept separate from the network call
    /// so the exact ZIP boundary is exercised by the package tests as well as by the UI.
    func install(_ document: PublishedLibraryDocument, package bytes: Data) throws -> String {
        guard let markdown = try installPackage(document, package: bytes).markdown else { throw StoreError.missingMarkdown }
        return markdown
    }

    private func installPackage(_ document: PublishedLibraryDocument, package bytes: Data) throws -> PreparedContent {
        guard (document.cleanAvailable || document.originalAvailable), let hash = document.packageHash,
              bytes.count <= Self.maximumPackageBytes, Self.sha256(bytes) == hash else {
            throw StoreError.corruptPackage
        }

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
        var originalEntries = 0
        for entry in archive {
            entryCount += 1
            expandedBytes += UInt64(entry.uncompressedSize)
            guard entryCount <= Self.maximumEntryCount, expandedBytes <= Self.maximumExpandedBytes else {
                throw StoreError.unsafeArchive
            }
            let relative = entry.path.replacingOccurrences(of: "\\", with: "/")
            let components = relative.split(separator: "/")
            // A colon is an ordinary filename character on iOS and is accepted by the server.
            // Containment and traversal checks, rather than a Windows-only filename rule, keep extraction safe.
            guard !relative.hasPrefix("/"), !components.contains("..") else {
                throw StoreError.unsafeArchive
            }
            if entry.type == .file {
                let isManifest = relative == "manifest.json"
                let isMarkdown = relative == "document.md"
                let isFigure = relative.hasPrefix("assets/")
                    && Self.allowedFigureExtensions.contains(URL(fileURLWithPath: relative).pathExtension.lowercased())
                let originalComponents = relative.split(separator: "/")
                let isOriginal = originalComponents.count == 2 && originalComponents.first == "original"
                    && Self.allowedOriginalExtensions.contains(URL(fileURLWithPath: relative).pathExtension.lowercased())
                if isOriginal, UInt64(entry.uncompressedSize) > Self.maximumOriginalBytes { throw StoreError.unsafeArchive }
                if isOriginal { originalEntries += 1 }
                guard originalEntries <= 1, isManifest || isMarkdown || isFigure || isOriginal else { throw StoreError.unsafeArchive }
            } else if entry.type != .directory {
                throw StoreError.unsafeArchive
            }
            let target = extracted.appendingPathComponent(relative)
            let resolvedRoot = extracted.standardizedFileURL.path
            guard target.standardizedFileURL.path.hasPrefix(resolvedRoot + "/") else { throw StoreError.unsafeArchive }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
        }
        let extractedMarkdown = extracted.appendingPathComponent("document.md")
        let hasMarkdown = manager.fileExists(atPath: extractedMarkdown.path)
        let markdown: String?
        if hasMarkdown {
            guard let value = try? String(contentsOf: extractedMarkdown, encoding: .utf8) else { throw StoreError.corruptPackage }
            markdown = value
        } else {
            markdown = nil
        }
        struct PackageManifest: Decodable {
            struct Original: Decodable { let path: String }
            let format: String
            let formatVersion: Int
            let documentId: String
            let cleanMarkdown: Bool?
            let original: Original?
        }
        let manifestURL = extracted.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PackageManifest.self, from: manifestData),
              manifest.format == "nodus.library-document-package", [1, 2].contains(manifest.formatVersion),
              manifest.documentId == document.id else {
            throw StoreError.corruptPackage
        }
        let extractedOriginal = extracted.appendingPathComponent("original", isDirectory: true)
        let original = (try? manager.contentsOfDirectory(at: extractedOriginal, includingPropertiesForKeys: nil))?.first
        guard hasMarkdown || original != nil else { throw StoreError.corruptPackage }
        if let original, original.pathExtension.lowercased() == "pdf" {
            guard let bytes = try? Data(contentsOf: original, options: .mappedIfSafe), bytes.starts(with: Data("%PDF-".utf8)) else {
                throw StoreError.corruptPackage
            }
        }
        if manifest.formatVersion >= 2 {
            guard manifest.cleanMarkdown == hasMarkdown,
                  (manifest.original != nil) == (original != nil),
                  !document.cleanAvailable || hasMarkdown,
                  !document.originalAvailable || original != nil else { throw StoreError.corruptPackage }
            if let original, manifest.original?.path != "original/\(original.lastPathComponent)" { throw StoreError.corruptPackage }
        }

        let destination = directory(document.id)
        let replacement = root.appendingPathComponent(".replacement-\(UUID().uuidString)", isDirectory: true)
        try manager.moveItem(at: extracted, to: replacement)
        try bytes.write(to: replacement.appendingPathComponent("package.zip"), options: .atomic)
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: replacement, to: destination)
        downloads[document.id] = Download(id: document.id, packageHash: hash, downloadedAt: Date(), bytes: bytes.count)
        persist()
        guard let package = packageURL(document.id) else { throw StoreError.corruptPackage }
        return PreparedContent(markdown: markdown, original: originalURL(document.id), package: package)
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
                try? PrivateBridgeProtectedFile.write(empty, to: index, protection: .completeFileProtectionUnlessOpen)
            }
        }
    }

    private func directory(_ id: String) -> URL { root.appendingPathComponent(Self.sha256(Data(id.utf8)), isDirectory: true) }
    private func markdownURL(_ id: String) -> URL { directory(id).appendingPathComponent("document.md") }
    private func persist() {
        guard let data = try? JSONEncoder.nodus.encode(downloads) else { return }
        try? PrivateBridgeProtectedFile.write(data, to: root.appendingPathComponent("downloads.json"), protection: .completeFileProtectionUnlessOpen)
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
