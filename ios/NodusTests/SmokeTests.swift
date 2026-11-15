import Foundation
import NodusKit
import Testing
@testable import Nodus

@Suite("Bundled presentation server")
@MainActor
struct LocalSurfaceHostTests {
    @Test("the real loopback document loads one byte-exact packaged script and rejects other resources")
    func onlyBundledPresentationAssets() async throws {
        let document = try await LocalSurfaceHost.shared.documentURL()
        let transport = URLSession(configuration: .ephemeral)
        defer { transport.invalidateAndCancel() }
        let (body, response) = try await transport.data(from: document)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let html = try #require(String(data: body, encoding: .utf8))
        #expect(html.components(separatedBy: "<script src=\"./surface.iife.js\"></script>").count == 2)
        #expect(html.contains("connect-src 'none'"))
        #expect(html.contains("script-src 'self' blob:"))
        let script = document.deletingLastPathComponent().appendingPathComponent("surface.iife.js")
        let (javascript, scriptResponse) = try await transport.data(from: script)
        #expect((scriptResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect((scriptResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/javascript; charset=utf-8")
        let packaged = try #require(Bundle.main.url(forResource: "surface.iife", withExtension: "js", subdirectory: "SharedDesktop"))
        let packagedBytes = try Data(contentsOf: packaged)
        #expect(!javascript.isEmpty)
        #expect(javascript == packagedBytes)
        var head = URLRequest(url: script); head.httpMethod = "HEAD"
        let (empty, headResponse) = try await transport.data(for: head)
        #expect(empty.isEmpty)
        #expect((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length") == String(javascript.count))
        for path in ["Info.plist", "operations.json", "surface.iife.js?file=secrets", "%2e%2e/Info.plist"] {
            let denied = try #require(URL(string: path, relativeTo: document))
            let (_, response) = try await transport.data(from: denied)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        }
        var post = URLRequest(url: script); post.httpMethod = "POST"
        let (_, postResponse) = try await transport.data(for: post)
        #expect((postResponse as? HTTPURLResponse)?.statusCode == 404)
    }
}

@Suite("Local surface draft isolation")
@MainActor
struct MobileSurfaceStorageTests {
    @Test("beta preserves a device preference but never exposes it as effective execution")
    func betaLiveExecutionPreservesPreference() throws {
        let connection = AppModel.Connection(origin: "https://beta-mode.test", spaceId: "beta-\(UUID())", spaceName: "Fixture", serverName: "Mac", role: .owner)
        let key = "ai-execution-mode:\(connection.id)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set("autonomous", forKey: key)
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = SpaceSession(connection: connection, client: NodusClient(address: ServerAddress(trusted: connection.origin), token: "fixture", cache: ResponseCache(directory: root)), mirrorDirectory: root)
        #expect(session.aiExecutionMode == .live)
        #expect(UserDefaults.standard.string(forKey: key) == "autonomous")
        session.aiExecutionMode = .autonomous
        #expect(session.aiExecutionMode == .live)
        #expect(UserDefaults.standard.string(forKey: key) == "autonomous")
        #expect(throws: APIError.self) { try BetaAIFeatures.requireAutonomousGeneration() }
        #expect(!BetaAIFeatures.audioGeneration)
    }

    @Test("a recovered Mac reprobes unavailable embeddings with the same or a changed origin", arguments: [false, true])
    func embeddingRecoversAfterOriginChange(changesOrigin: Bool) async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var connection = AppModel.Connection(origin: "https://embedding-recovery.test", spaceId: "live:embedding-mac:embedding-\(UUID())",
            spaceName: "Fixture", serverName: "Mac", role: .owner, vaultId: "isolated", desktopPairingId: "isolated-grant")
        defer { UserDefaults.standard.removeObject(forKey: "ai-execution-mode:\(connection.id)") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EmbeddingRecoveryProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let client = NodusClient(address: ServerAddress(trusted: connection.origin), token: "isolated", session: transport,
            cache: ResponseCache(directory: root))
        let session = SpaceSession(connection: connection, client: client, mirrorDirectory: root)
        await session.probeEmbedding()
        guard case .unavailable = session.embedding else { Issue.record("Expected the initial real transport failure"); return }
        // Merely reopening the settings must not invent a successful identity.
        await session.probeEmbedding()
        guard case .unavailable = session.embedding else { Issue.record("Default probing must retain the real failure"); return }
        if changesOrigin { connection.origin = "https://verified-new-origin.test" }
        session.refreshConnectionMetadata(connection)
        await session.probeEmbedding(retryUnavailable: true)
        // Origin refresh schedules its own probe. A newer probe deliberately supersedes
        // this awaited call, so wait for its actual terminal response, not just one caller.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while case .unknown = session.embedding, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.embedding == .published(EmbeddingIdentity(provider: "fixture", model: "recovered", dim: 384)))
        #expect(session.aiExecutionMode == .live)
    }
    @Test("an unchanged Mac revision flushes authorized work without a downloaded mirror")
    func reconnectWithoutPublicationChange() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connection = AppModel.Connection(origin: "https://companion.test", spaceId: "isolated-reconnect-\(UUID().uuidString)",
            spaceName: "Fixture", serverName: "Mac", role: .owner, vaultId: "fixture-vault", desktopPairingId: "fixture-grant")
        defer { UserDefaults.standard.removeObject(forKey: "ai-execution-mode:\(connection.id)") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanionReconnectProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let client = NodusClient(address: ServerAddress(trusted: connection.origin), token: "fixture-token", session: transport, cache: ResponseCache(directory: root.appendingPathComponent("http")))
        let session = SpaceSession(connection: connection, client: client, mirrorDirectory: root)
        await session.refreshPublishedContent() // No revision and no pending work.
        #expect(session.publishedRevision == nil)
        #expect(session.mirror == nil)
        let queue = try await MutationOutbox.open(spaceId: connection.storageId, directory: root)
        let authorized = Mutation(clientId: "phone", kind: .upsert, table: .notes, key: ["authorized"], schemaVersion: 1)
        let unsent = Mutation(clientId: "phone", kind: .upsert, table: .notes, key: ["unsent"], schemaVersion: 1)
        try await queue.enqueue(authorized, title: "Authorized save")
        try await queue.enqueue(unsent, title: "Unconfirmed draft")
        _ = try await queue.authorise(ids: [authorized.id])
        await session.refreshPublishedContent() // The same successful HEAD must trigger delivery.
        let items = try await queue.items()
        #expect(items.first(where: { $0.id == authorized.id })?.state == .delivered)
        #expect(items.first(where: { $0.id == unsent.id })?.state == .pending)
        #expect(try await queue.authorisedCount() == 0)
        #expect(session.aiExecutionMode == .live)
    }
    @Test("a stored live connection uses the Bridge and rejects generic authenticated Server routes before transport")
    func backgroundLiveClientUsesBridge() async throws {
        let pairing = try DesktopBridgePairing(id: "fixture-pair", origin: "https://mac.invalid", certificateFingerprint: String(repeating: "a", count: 64),
            deviceId: "mac-id", deviceName: "Mac ficticio", vaultIds: ["vault-id"], domains: [.corpus, .writing], pairedAt: .now, expiresAt: nil)
        let connection = AppModel.Connection(origin: pairing.origin, spaceId: "live:mac-id:vault-id", spaceName: "Vault", serverName: "Mac",
            role: .owner, vaultId: "vault-id", desktopPairingId: pairing.id)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = try #require(ConnectionClient.make(for: connection, token: "fixture-token", pairings: [pairing], cacheDirectory: directory))
        await #expect(throws: DesktopBridgeError.permissionDenied) { _ = try await client.me() }
        #expect(ConnectionClient.make(for: connection, token: "fixture-token", pairings: [], cacheDirectory: directory) == nil)
        var invalid = connection; invalid.vaultId = "another-vault"
        #expect(ConnectionClient.make(for: invalid, token: "fixture-token", pairings: [pairing], cacheDirectory: directory) == nil)
        invalid = connection; invalid.vaultId = nil
        #expect(ConnectionClient.make(for: invalid, token: "fixture-token", pairings: [pairing], cacheDirectory: directory) == nil)
        let expired = try DesktopBridgePairing(id: pairing.id, origin: pairing.origin, certificateFingerprint: pairing.certificateFingerprint,
            deviceId: pairing.deviceId, deviceName: pairing.deviceName, vaultIds: pairing.vaultIds, domains: pairing.domains, pairedAt: .distantPast, expiresAt: .distantPast)
        #expect(ConnectionClient.make(for: connection, token: "fixture-token", pairings: [expired], cacheDirectory: directory) == nil)
    }
    @Test("captured private connections follow their canonical grant after origin aliases are retired")
    func capturedConnectionAfterDiscovery() throws {
        let id = UUID().uuidString, suite = "nodus.discovery-native." + id
        let defaults = try #require(UserDefaults(suiteName: suite)), keychain = KeychainStore(service: suite)
        let store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain)
        defer { defaults.removePersistentDomain(forName: suite); try? keychain.remove(KeychainStore.desktopBridgeKey(pairingId: id)) }
        let pairing = try DesktopBridgePairing(id: id, origin: "https://new-lan.test:7443", certificateFingerprint: String(repeating: "a", count: 64),
            deviceId: "phone", deviceName: "Phone", vaultIds: ["vault"], domains: [.corpus,.writing], pairedAt: .now, expiresAt: nil)
        try store.save(pairing, token: "current-isolated-grant")
        let captured = AppModel.Connection(origin: "https://old-lan.test:7443", spaceId: "live:mac:vault", spaceName: "Vault", serverName: "Mac", role: .writer,
            vaultId: "vault", desktopPairingId: pairing.id, macDeviceId: "mac")
        #expect(keychain.value(for: KeychainStore.deviceTokenKey(origin: captured.origin, spaceId: captured.spaceId)) == nil)
        #expect(ConnectionClient.credential(for: captured, store: store, keychain: keychain) == "current-isolated-grant")
        var moved = captured; moved.origin = pairing.origin
        #expect(captured.id == moved.id && captured.storageId == moved.storageId)
        var unauthorized = captured; unauthorized.vaultId = "another-vault"
        #expect(ConnectionClient.credential(for: unauthorized, store: store, keychain: keychain) == nil)
        _ = store.markAuthorizationRevoked(pairingId: id)
        #expect(ConnectionClient.credential(for: captured, store: store, keychain: keychain) == nil)
    }
    @Test("an evidence quote resolves to the paragraph rendered by the document reader")
    func evidenceDocumentAnchor() {
        let prose = CorpusProse("# Documento\n\nPrimer párrafo.\n\n## Evidencia\n\nLa definición A 222 pertenece a este\ncorpus de pruebas ficticio.", accent: .blue)
        #expect(prose.anchor(containing: "La definición A 222 pertenece a este corpus de pruebas ficticio.") == PageSearchAnchor(path: [3]))
        #expect(prose.anchor(containing: "primer PÁRRAFO", path: [7]) == PageSearchAnchor(path: [7, 1]))
        #expect(prose.anchor(containing: "cita ausente") == nil)
        #expect(prose.anchor(containing: "  \n ") == nil)
    }
    @Test("published-space identities isolate origins and spaces without borrowing a Mac vault id")
    func localIdentities() throws {
        let first = try MobileSurfaceStorageScope(connectionId: "https://one.example|space-a", pairingId: nil, vaultId: "vault-a")
        let same = try MobileSurfaceStorageScope(connectionId: "https://one.example|space-a", pairingId: nil, vaultId: nil)
        let otherOrigin = try MobileSurfaceStorageScope(connectionId: "https://two.example|space-a", pairingId: nil, vaultId: "vault-a")
        let otherSpace = try MobileSurfaceStorageScope(connectionId: "https://one.example|space-b", pairingId: nil, vaultId: "vault-a")
        #expect(first == same)
        #expect(first != otherOrigin)
        #expect(first != otherSpace)
        #expect(first.recordVaultId != "vault-a")
        let paired = try MobileSurfaceStorageScope(connectionId: "live:space-a", pairingId: "pairing-a", vaultId: "vault-a")
        #expect(paired.cacheId == "pairing-a")
        #expect(paired.recordVaultId == "vault-a")
        #expect(throws: DesktopBridgeError.permissionDenied) {
            try MobileSurfaceStorageScope(connectionId: "live:space-a", pairingId: "pairing-a", vaultId: nil)
        }
    }

    @Test("shared surfaces use the selected vault identity, rather than the Mac or published-space identity")
    func surfaceVaultIdentity() {
        let connection = AppModel.Connection(origin: "https://mac.example", spaceId: "live:mac-a:space-a", spaceName: "Espacio",
            serverName: "Mac", role: .reader, vaultType: .academic, vaultName: "Principal", vaultId: "vault-a", desktopPairingId: "grant-a")
        let context = MobileSurfaceVaultContext.descriptor(connection: connection, vault: nil)
        #expect(context.id == "vault-a")
        #expect(context.name == "Principal")
        #expect(context.type == .academic)
        let loaded = MobileSurfaceVaultContext.descriptor(connection: connection, vault: VaultDescriptor(id: "vault-b", name: "Estudio", type: .estudio))
        #expect(loaded.id == "vault-a")
        #expect(loaded.name == "Principal")
        #expect(loaded.type == .academic)
        let matching = MobileSurfaceVaultContext.descriptor(connection: connection, vault: VaultDescriptor(id: "vault-a", name: "Principal actualizado", type: .academic))
        #expect(matching.name == "Principal actualizado")
    }

    @Test("a publication without a vault identity retains that absence in shared surfaces")
    func surfacePublicationIdentity() {
        let connection = AppModel.Connection(origin: "https://server.example", spaceId: "published-space", spaceName: "Espacio",
            serverName: "Server", role: .reader, vaultType: .academic)
        let context = MobileSurfaceVaultContext.descriptor(connection: connection, vault: nil)
        #expect(context.id == nil)
        #expect(context.name == nil)
        #expect(context.type == .academic)
    }

    @Test("local drafts survive reopening encrypted storage and remain absent from other spaces")
    func encryptedRecovery() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let keychain = KeychainStore(service: "nodus.acceptance.surface.\(UUID().uuidString)")
        let first = try MobileSurfaceStorageScope(connectionId: "https://one.example|space-a", pairingId: nil, vaultId: nil)
        let other = try MobileSurfaceStorageScope(connectionId: "https://one.example|space-b", pairingId: nil, vaultId: nil)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: first.cacheId))
            try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: other.cacheId))
        }
        let payload = Data("A local structured draft with a citation and formula".utf8)
        let cache = try PrivateBridgeCache(pairingId: first.cacheId, directory: directory, keychain: keychain)
        try await cache.store(payload, vaultId: first.recordVaultId, domain: .writing, recordId: "surface-storage:v1")
        let reopened = try PrivateBridgeCache(pairingId: first.cacheId, directory: directory, keychain: keychain)
        #expect(try await reopened.data(vaultId: first.recordVaultId, domain: .writing, recordId: "surface-storage:v1") == payload)
        let otherCache = try PrivateBridgeCache(pairingId: other.cacheId, directory: directory, keychain: keychain)
        #expect(try await otherCache.data(vaultId: other.recordVaultId, domain: .writing, recordId: "surface-storage:v1") == nil)
        let folder = directory.appendingPathComponent("bridge-\(first.cacheId)")
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            #expect(try Data(contentsOf: file).range(of: payload) == nil)
        }
    }
}

private nonisolated final class CompanionReconnectProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "companion.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body: Data
            if request.httpMethod == "HEAD" { body = Data() }
            else {
                guard request.httpMethod == "POST", request.url?.path.hasSuffix("/mutations") == true else { throw URLError(.unsupportedURL) }
                let bytes: Data
                if let data = request.httpBody { bytes = data }
                else if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                    bytes = data
                } else { throw URLError(.badServerResponse) }
                let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                let mutations = try #require(object?["mutations"] as? [[String: Any]])
                #expect(mutations.count == 1)
                #expect(mutations.first?["key"] as? [String] == ["authorized"])
                let ids = mutations.compactMap { $0["id"] as? String }
                body = try JSONSerialization.data(withJSONObject: ["accepted": ids, "duplicate": [], "rejected": [], "applied": ids])
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

/// The app target's own tests. The interesting assertions live in the packages, where they
/// run without a simulator; this bundle exists to prove the app links what it claims to.
@Suite("App wiring")
struct AppWiringTests {
    @Test("NodusKit is linked into the app and its contract table is intact")
    func linksNodusKit() {
        #expect(Collections.all.count == 49)
        #expect(Collections["deep-research"] == nil, "deep-research is a special resource, not a collection")
        #expect(SpecialResource.deepResearch.listKey == "reports")
    }

    @Test("every desktop route is classified exactly once")
    func desktopRoutesAreClassified() {
        #expect(Set(NodusNavigationContract.items.map(\.route)) == Set(NodusRoute.allCases))
        #expect(NodusNavigationContract.items.count == NodusRoute.allCases.count)
    }

    @Test("only academic vaults expose Link readers without authoring or tools")
    func navigationHasUniversalRoutes() {
        for vaultType in VaultType.allCases {
            let visible = NodusNavigationContract.visibleItems(for: vaultType)
            if vaultType != .academic { #expect(visible.isEmpty); continue }
            #expect(visible.first?.route == .home)
            #expect(visible.last?.route == .settings)
            #expect(visible.allSatisfy { $0.support.isVisible })
            #expect([.library, .dictionary, .podcast].allSatisfy { route in
                visible.contains { $0.route == route }
            })
        }
    }

    @Test("academic sidebar includes the shared graph, dictionary, chat and announced tools")
    func academicSidebarMatchesMobile() {
        let visible = NodusNavigationContract.visibleItems(for: .academic).map(\.route)
        #expect(visible == [
            .home, .library,
            .search, .graph, .ideas, .authors, .argument,
            .deepResearch, .dictionary, .podcast,
            .settings,
        ])
        #expect(NodusNavigationContract.groupedItems(for: .academic).map(\.0) == [.explore, .analyze])
        #expect(NodusNavigationContract.items.first(where: { $0.route == .deepResearch })?.systemImage == "telescope")
    }

    @Test("dedicated vault sidebars use Desktop closed allow-lists")
    func dedicatedSidebarAllowlists() {
        let expected: [VaultType: Set<NodusRoute>] = [
            .prosopography: [.prosopSearch, .prosopPopulation, .prosopPersons, .prosopSources, .prosopAnalysis, .prosopNetworks, .notes, .browser, .radar, .toolkit],
            .primarySources: [.search, .archive, .persons, .timeline, .map, .relations, .notes, .browser, .radar, .toolkit],
            .estudio: [.studyCourses, .studySchedule, .studyCalendar, .studySearch, .studyLibrary, .studyRecordings, .studyChat, .studyIdeas, .studyGraph, .studyQuestions, .studyReview, .studyDeepResearch, .browser, .radar, .toolkit],
            .docencia: [.studyCourses, .teachingGroups, .studySchedule, .studyCalendar, .studyLibrary, .studyRecordings, .studyChat, .studyIdeas, .studyGraph, .studyDeepResearch, .studyQuestions, .teachingRubrics, .teachingExams, .teachingGrades, .teachingUnits, .browser, .radar, .toolkit],
            .databases: [.pages, .databases, .dbSearch, .dbAnalysis, .dbChat, .dbDeepResearch, .notes, .browser, .radar, .toolkit],
            .testimonios: [.search, .testimonyInterviews, .testimonyParticipants, .testimonyContrasts, .notes, .browser, .radar, .toolkit],
            .worldbuilding: [.encyclopedia, .characters, .places, .factions, .cultures, .timeline, .map, .relations, .tree, .dynasties, .worldChat, .rules, .conflicts, .arcs, .continuity, .questions, .notes, .scenes, .manuscript, .browser, .radar, .toolkit],
        ]
        let pinned: Set<NodusRoute> = [.home, .library, .settings, .dictionary, .compass, .studyFocus]
        for (vaultType, routes) in expected {
            #expect(NodusNavigationContract.sidebarAllowedRoutes(for: vaultType) == routes.union(pinned))
        }
    }

    @Test("every visible data-driven route has a concrete replica source")
    func visibleRoutesHaveSources() {
        for item in NodusNavigationContract.items where item.support.isVisible {
            switch item.support {
            case .collection(let path):
                #expect(Collections[path] != nil, "\(item.route.rawValue) points at an unknown collection: \(path)")
            case .mirror(let table, let field, let values):
                #expect(!table.isEmpty)
                #expect(field != nil || values.isEmpty)
                #expect(field == nil || !values.isEmpty)
            case .native:
                break
            default:
                Issue.record("a hidden support kind was marked visible")
            }
        }

        let studyIdeas = NodusNavigationContract.items.first { $0.route == .studyIdeas }
        #expect(studyIdeas?.support == .collection(path: "ideas"))
    }

    @Test("Worldbuilding exposes its complete current Desktop workspace")
    func worldbuildingContract() {
        let visible = Set(NodusNavigationContract.items.filter { $0.vaultTypes.contains(.worldbuilding) }.map(\.route))
        #expect(visible.isSuperset(of: [
            .encyclopedia, .characters, .places, .factions, .cultures, .dynasties,
            .rules, .conflicts, .arcs, .continuity, .questions, .worldChat,
            .scenes, .manuscript, .notes,
        ]))
        #expect(!NodusNavigationContract.visibleItems(for: .academic).contains {
            [.hypothesis, .reading, .writing, .projects].contains($0.route)
        })
    }

    @Test("one breakpoint model drives iPhone, split view and iPad")
    func adaptiveSidebarBreakpoints() {
        let phone = SidebarPresentation(availableWidth: 430, isUserCollapsed: false)
        #expect(!phone.isPersistent)
        #expect(phone.residentRouteSize(in: CGSize(width: 430, height: 932)) == CGSize(width: 430, height: 888))

        let phoneLandscape = SidebarPresentation(availableWidth: 956, isUserCollapsed: false, isPhone: true)
        #expect(!phoneLandscape.isPersistent)
        #expect(phoneLandscape.residentRouteSize(in: CGSize(width: 956, height: 440)) == CGSize(width: 956, height: 396))

        let split = SidebarPresentation(availableWidth: 640, isUserCollapsed: false)
        #expect(split.isPersistent)
        #expect(split.isCollapsed)
        #expect(split.sidebarWidth == 64)
        #expect(split.residentRouteSize(in: CGSize(width: 640, height: 900)) == CGSize(width: 280, height: 856))

        let ipad = SidebarPresentation(availableWidth: 1_024, isUserCollapsed: false)
        #expect(ipad.isPersistent)
        #expect(!ipad.isCollapsed)
        #expect(ipad.sidebarWidth == 176)
        #expect(ipad.residentRouteSize(in: CGSize(width: 1_024, height: 1_366)) == CGSize(width: 664, height: 1_322))

        let resized = SidebarPresentation(availableWidth: 1_024, isUserCollapsed: false, expandedWidth: 284)
        #expect(resized.sidebarWidth == 284)
        #expect(SidebarPresentation(availableWidth: 1_024, isUserCollapsed: false, expandedWidth: 500).sidebarWidth == 360)

        let userCollapsed = SidebarPresentation(availableWidth: 1_024, isUserCollapsed: true)
        #expect(userCollapsed.isCollapsed)
    }

    @Test("Library falls back to the space's published works on older servers")
    func libraryRouteFollowsServerCapabilities() {
        #expect(LibraryRouteSource.resolve(isDemo: false, supportsAccountSync: false) == .publishedWorks)
        #expect(LibraryRouteSource.resolve(isDemo: false, supportsAccountSync: true) == .account)
        #expect(LibraryRouteSource.resolve(isDemo: true, supportsAccountSync: false) == .account)
    }

    @Test("every known vault type can draw its Home sections before counts arrive")
    @MainActor
    func homeSectionsDoNotWaitForTheOverview() {
        for vaultType in VaultType.allCases {
            let sections = SpaceSession.anticipatedSections(for: vaultType)

            #expect(!sections.isEmpty, "\(vaultType.rawValue) would open onto an empty Home board")
            #expect(sections.allSatisfy { !$0.families.isDisjoint(with: vaultType.families) })
            #expect(!sections.contains { ["passages", "study-calendar", "study-goals"].contains($0.path) })
        }
    }

    /// The primary key of every study and teaching table is `id`.
    ///
    /// The table used to declare `subject_id`, `card_id`, `exam_id` and six more — columns
    /// none of those tables has (`electron/db/migrations.ts:1573` onwards). `idField` is what
    /// decides whether a detail can be enriched and whether a row listed inside another
    /// dossier is a link, so every study and teaching row was un-openable and no exam could
    /// ever have loaded its questions.
    @Test("study and teaching collections are keyed on the column their table really has")
    func studyCollectionsUseId() {
        let studyAndTeaching = Collections.all.filter {
            $0.table.hasPrefix("study_") || $0.table.hasPrefix("teaching_")
        }
        #expect(studyAndTeaching.count == 14)
        for collection in studyAndTeaching {
            #expect(collection.idField == "id", "\(collection.path) is keyed on \(collection.idField)")
        }
    }

    /// Two closed vocabularies the agenda and the goals translate, and the rule for everything
    /// else: say nothing rather than print a raw column value beside translated text.
    ///
    /// A block's `type` is a free string in the schema (`shared/studyPlanner.ts:3`), which is
    /// why it is not in this list and not on the screen — whatever the planner wrote, in
    /// whatever language, would have gone straight onto a Spanish page.
    @Test("only the closed vocabularies are put into words")
    func studyVocabularies() {
        #expect(AgendaView.eventLabel("exam") != nil)
        #expect(AgendaView.eventLabel("assignment") != nil)
        #expect(AgendaView.eventLabel("class") != nil)
        #expect(AgendaView.eventLabel("session") != nil)
        #expect(AgendaView.eventLabel("whatever-the-planner-wrote") == nil)
        #expect(AgendaView.eventLabel(nil) == nil)

        #expect(GoalsView.periodLabel("daily") != nil)
        #expect(GoalsView.periodLabel("weekly") != nil)
        #expect(GoalsView.periodLabel("monthly") != nil)
        #expect(GoalsView.periodLabel("fortnightly") == nil)
    }

    /// The two enriched handlers whose response key is not the path with its `s` dropped.
    @Test("an enriched detail is read under the key the server actually answers with")
    func enrichedDetailKeys() {
        #expect(Collections["teaching-exams"]?.detailKey == "exam")
        #expect(Collections["study-plans"]?.detailKey == "plan")
        #expect(Collections["study-docs"]?.detailKey == "study-doc")
        #expect(Collections["ideas"]?.detailKey == "idea")
    }

    /// Info.plist and the code have to agree, and nothing else checks that they do.
    ///
    /// An identifier the bundle permits but nobody registers is a capability the app claims and
    /// does not have — which is exactly what these three were for a year. An identifier
    /// registered but not permitted is worse: `BGTaskScheduler` traps at launch, on a device,
    /// and never in the simulator where it would have been noticed.
    @Test("every permitted background identifier is one the app actually claims")
    func backgroundIdentifiersMatchTheBundle() {
        let permitted = Set(BackgroundWork.permittedIdentifiers)
        #expect(!permitted.isEmpty, "the test bundle must be reading the app's own Info.plist")
        #expect(Set(BackgroundWork.identifiers) == permitted)
    }

    /// A processing task needs the background mode that permits it. Declaring the identifiers
    /// without the mode gives a scheduler that accepts submissions and never runs them.
    @Test("the background modes cover the tasks the app submits")
    func backgroundModesAreDeclared() {
        let modes = Set(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [])
        #expect(modes.contains("processing"))
    }
}

/// Each isolated URLSession gets a transport failure followed by an actual semantic refusal
/// carrying the server's canonical identity. No Keychain or real workspace is involved.
private nonisolated final class EmbeddingRecoveryProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failedSpaces: Set<String> = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "embedding-recovery.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        let first = Self.failedSpaces.insert(path).inserted
        Self.lock.unlock()
        guard !first else { client?.urlProtocol(self, didFailWithError: URLError(.secureConnectionFailed)); return }
        guard request.httpMethod == "POST", path.hasSuffix("/search/semantic") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let body = Data(#"{"indexed":false,"reason":"provider_mismatch","expected":{"provider":"fixture","model":"recovered","dim":384}}"#.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
