import Foundation

/// Registered originals from the private Mac. This catalogue carries opaque
/// identities, never a local filename as an address or a filesystem path.
public struct CompanionDossierResources: Sendable {
    public struct File: Sendable, Identifiable {
        public let kind: DesktopBridgeFileKind
        public let fileId: String
        public let title: String
        public let available: Bool
        public let mime: String?
        public var id: String { kind.rawValue + ":" + fileId }
    }
    public static let fileCollections = Set(["works", "study-materials", "archive-items", "databases", "pages"])
    public let files: [File]
    public let reader: JSONValue?
    public let value: JSONValue

    public init(value: JSONValue, collection: String, id: String) throws {
        guard Self.fileCollections.contains(collection), !id.isEmpty,
              let object = value.objectValue, object["version"] == .int(1),
              object["collection"] == .string(collection), object["id"] == .string(id),
              let entries = object["files"]?.arrayValue, entries.count <= 20_000 else { throw DesktopBridgeError.malformedResponse }
        let allowed: Set<DesktopBridgeFileKind>
        switch collection {
        case "works": allowed = [.libraryOriginal, .libraryAttachment]
        case "study-materials": allowed = [.studyMaterial, .studyMaterialVersion]
        case "archive-items": allowed = [.archiveItem, .archiveFile]
        case "databases": allowed = [.databaseAttachment]
        case "pages": allowed = [.pageAsset]
        default: throw DesktopBridgeError.permissionDenied
        }
        var seen = Set<String>(), files: [File] = []
        for entry in entries {
            guard let row = entry.objectValue, let kind = row["kind"]?.stringValue.flatMap(DesktopBridgeFileKind.init(rawValue:)), allowed.contains(kind),
                  let fileId = row["id"]?.stringValue, !fileId.isEmpty, fileId.utf8.count <= 4096,
                  let title = row["title"]?.stringValue, !title.isEmpty, title.utf8.count <= 16_384,
                  let available = row["available"]?.boolValue else { throw DesktopBridgeError.malformedResponse }
            if [.libraryOriginal, .studyMaterial, .archiveItem].contains(kind), fileId != id { throw DesktopBridgeError.malformedResponse }
            if kind == .libraryAttachment {
                guard let pair = try? JSONDecoder.nodus.decode([String].self, from: Data(fileId.utf8)), pair.count == 2, pair[0] == id, !pair[1].isEmpty else { throw DesktopBridgeError.malformedResponse }
            }
            if kind == .pageAsset, fileId.count != 64 || !fileId.allSatisfy(\.isHexDigit) { throw DesktopBridgeError.malformedResponse }
            let file = File(kind: kind, fileId: fileId, title: title, available: available, mime: row["mime"]?.stringValue)
            guard seen.insert(file.id).inserted else { throw DesktopBridgeError.malformedResponse }
            files.append(file)
        }
        if let reader = object["reader"], reader != .null {
            guard collection == "works", reader.objectValue?["workId"] == .string(id),
                  reader.objectValue?["attachments"]?.arrayValue != nil else { throw DesktopBridgeError.malformedResponse }
        }
        self.files = files; self.reader = object["reader"]; self.value = value
    }

    public static func arguments(collection: String, id: String) -> [JSONValue] {
        [.object(["collection": .string(collection), "id": .string(id)])]
    }

    /// Explicit embedded references plus the gallery and portrait owned by the
    /// selected dossier. Linked neighbours do not download their own galleries.
    public static func imageSources(collection: String, id: String, detail: JSONValue) throws -> [String] {
        var sources = Set(try CompanionCorpusImage.sourceURLs(in: detail))
        func source(_ host: String, _ identity: String) throws -> String {
            var url = URLComponents(); url.scheme = "nodus-image"; url.host = host; url.path = "/" + identity
            guard let result = url.url?.absoluteString, CompanionCorpusImage.validSource(result) else { throw DesktopBridgeError.malformedResponse }
            return result
        }
        for image in detail.objectValue?["images"]?.arrayValue ?? [] {
            guard let imageId = image.objectValue?["image_id"]?.stringValue, !imageId.isEmpty else { throw DesktopBridgeError.malformedResponse }
            sources.insert(try source("world", imageId))
        }
        if collection == "persons", let portrait = detail.objectValue?["portrait"], portrait != .null { sources.insert(try source("portrait", id)) }
        if collection == "world-maps", let imageId = detail.objectValue?["map"]?.objectValue?["image_id"]?.stringValue, !imageId.isEmpty {
            sources.insert(try source("map", imageId))
        }
        return sources.sorted()
    }
}
