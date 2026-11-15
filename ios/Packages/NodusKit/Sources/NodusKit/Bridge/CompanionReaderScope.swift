import Foundation

/// Citation reads in a selected reader have no transport fallback. Linked
/// summaries are not promoted to selected dossiers just because a URL names them.
public enum CompanionReaderScope {
    public enum Selection: Sendable {
        case dossier(CollectionDossier)
        case literal(JSONValue)
    }
    public enum ReadError: Error, LocalizedError {
        case notDownloaded
        public var errorDescription: String? { String(localized: "Esta fuente no está incluida en las descargas de este dispositivo. Descárgala con Nodus conectado para consultarla aquí.") }
    }
    /// The publication is an actual local snapshot. Reuse its canonical local
    /// dossiers and relationships; this adapter has no remote transport.
    public static func resolveMirror(path: String, id: String, spaceId: String, mirror: MirrorStore) async throws -> Selection {
        guard !id.isEmpty, id.utf8.count <= 4096,
              Collections[path] != nil || ["notes", "debates"].contains(path) else { throw ReadError.notDownloaded }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed),
              let encodedSpace = spaceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { throw DesktopBridgeError.malformedResponse }
        let local = LocalCorpus(space: .init(id: spaceId, name: spaceId), mirror: mirror, archive: Data())
        let response = try await local.answer(.init(path: "/api/v1/spaces/" + encodedSpace + "/" + path + "/" + encoded))
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data)
        if let descriptor = Collections[path] {
            return .dossier(try CollectionDossier(collection: descriptor, id: id, payload: value, fromDevice: true))
        }
        return .literal(value)
    }
    public static func resolve(path: String, id: String, collections: [CompanionCollectionCopy], ideas: CompanionIdeaCopy? = nil, noteEditor: JSONValue? = nil) throws -> Selection {
        guard !id.isEmpty, id.utf8.count <= 4096 else { throw DesktopBridgeError.malformedResponse }
        if path == "notes" {
            guard let noteEditor, noteEditor.objectValue?["documentTitle"]?.stringValue != nil,
                  noteEditor.objectValue?["contentMarkdown"]?.stringValue != nil,
                  noteEditor.objectValue?["revision"]?.intValue != nil else { throw ReadError.notDownloaded }
            return .literal(noteEditor)
        }
        if path == "debates" {
            guard let value = try ideas?.operation("getEdgeDetail", args: [.string(id)]) else { throw ReadError.notDownloaded }
            return .literal(value)
        }
        if path == "ideas", let ideas, ideas.selectedRows.contains(where: { $0.string("global_id") == id }) {
            let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
            guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed),
                  let response = try ideas.nativeResponse(path: "ideas/" + encoded, query: [], percentEncoded: true),
                  let descriptor = Collections[path] else { throw ReadError.notDownloaded }
            return .dossier(try CollectionDossier(collection: descriptor, id: id,
                payload: JSONDecoder.nodus.decode(JSONValue.self, from: response.data), fromDevice: true))
        }
        guard let copy = collections.first(where: { $0.collection.path == path }),
              copy.selectedRows.contains(where: { $0.string(copy.collection.idField) == id }) else { throw ReadError.notDownloaded }
        return .dossier(try copy.dossier(id: id))
    }
}
