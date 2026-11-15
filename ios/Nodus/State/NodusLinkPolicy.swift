import NodusKit

/// First release: the linked computer owns content creation and editing. Personal report
/// highlights, comments and reading bookmarks use a separate, narrowly scoped permission.
/// Retained authoring stores and providers stay disabled for a later release.
enum NodusLinkPolicy {
    nonisolated static let readOnly = true
    nonisolated static func supports(_ type: VaultType?) -> Bool { type == .academic }
    static let routes: Set<NodusRoute> = [.home, .search, .library, .graph,
        .ideas, .authors, .argument, .deepResearch,
        .dictionary, .podcast, .settings]
    nonisolated static let message = "Nodus Link permite consultar y escuchar. Crea y edita los contenidos desde Nodus en tu ordenador."
    nonisolated static func requireAuthoring() throws {
        if readOnly { throw APIError(status: 409, code: "nodus_link_read_only", message: message) }
    }
    nonisolated static func requireSurfaceMethod(_ method: String, domain: String?) throws {
        guard readOnly else { return }
        // These calls only manage the local reader, not the canonical workspace.
        let readerMethods: Set<String> = ["surfaceVaultContext", "surfaceFullscreen", "surfaceOfflineCopy",
            "snapshot", "dictionarySnapshotTables", "sourceConsultationTables", "mobileSettings",
            "mobileArgumentMaps", "getPageDocument", "getPageAsset", "getSyncedBlockSource",
            "getDatabaseContainer", "queryDatabaseContainerRows", "openSavedAudioClip",
            "persistSurfaceStorage", "loadSurfaceStorage", "openExternal", "navigate"]
        guard domain == "corpus" || readerMethods.contains(method) else { try requireAuthoring(); return }
    }
    static func requireReaderNavigation(_ kind: String, record: String) throws {
        guard readOnly else { return }
        let readers: Set<String> = ["citation", "idea", "author", "work", "deepResearchReport",
            "legacyResearchReports", "pageAsset", "embeddedResource", "databaseRow", "page",
            "studyMaterial", "studyDocument", "closeStudyDocument"]
        if kind == "section", let route = NodusRoute(rawValue: record), routes.contains(route) { return }
        guard readers.contains(kind) else { try requireAuthoring(); return }
    }
}
