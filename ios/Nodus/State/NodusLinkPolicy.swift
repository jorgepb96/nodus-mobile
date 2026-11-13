import NodusKit

/// First release: the linked computer owns creation and editing. Retained authoring
/// stores and providers are deliberately kept for a later release, never migrated away.
enum NodusLinkPolicy {
    nonisolated static let readOnly = true
    static let routes: Set<NodusRoute> = [.home, .search, .library, .graph, .studyGraph,
        .ideas, .studyIdeas, .authors, .argument, .deepResearch, .studyDeepResearch,
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
            "persistSurfaceStorage", "loadSurfaceStorage", "openExternal"]
        guard domain == "corpus" || readerMethods.contains(method) else { try requireAuthoring(); return }
    }
}
