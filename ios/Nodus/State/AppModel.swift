import NodusKit
import Observation
import SwiftUI

/// Everything the app knows across servers and spaces.
///
/// Connections live in `UserDefaults`; the tokens they need live in the Keychain and are only
/// ever read back into a client, never into a view. That split is the same one the desktop
/// makes — the settings object carries `providerKeys: Record<AiProvider, boolean>` and not the
/// keys themselves.
@Observable
@MainActor
final class AppModel {
    /// A space this device has a token for.
    struct Connection: Codable, Identifiable, Hashable, Sendable {
        var origin: String
        var spaceId: String
        var spaceName: String
        var serverName: String
        var role: SpaceRole
        var vaultType: VaultType?
        var vaultName: String?
        var lastOpenedAt: Date?
        /// When this device first took a credential for the space.
        ///
        /// Optional because it is younger than the stored format: a connection made before it
        /// existed decodes with nil, and the picker falls back to its place in the stored list,
        /// which is the order they were added in.
        var addedAt: Date?
        var vaultId: String?
        var desktopPairingId: String?

        nonisolated var id: String {
            if desktopPairingId != nil, spaceId.hasPrefix("live:") { return spaceId }
            return "\(origin)|\(spaceId)"
        }
        nonisolated var storageId: String { SpaceStorageIdentity(connectionID: id).key }
        var accent: Color { Color(hex: vaultType?.accentHex ?? VaultType.academic.accentHex) }

        /// The example vault in the bundle rather than a space on a server.
        ///
        /// Read from the origin rather than from a stored flag. A new `Bool` property would
        /// have to be optional to keep decoding the connections already on people's phones —
        /// synthesised `Decodable` throws on a missing key rather than taking a default, and
        /// one throw loses the *whole* array — and an optional flag is a third state nobody
        /// wants. The origin is already stored, already unique, and already the thing that
        /// decides where a request goes.
        var isDemo: Bool { origin == DemoSpace.origin }
    }

    private(set) var connections: [Connection] = []
    private(set) var session: SpaceSession?
    private(set) var isOpeningLocalCorpus = false
    var isConnecting = false

    private let keychain = KeychainStore()
    private static let defaultsKey = "nodus.connections.v1"
    private let cacheDirectory: URL
#if DEBUG
    private var acceptanceCapabilitiesFailureDelivered = false
#endif

    init() {
        cacheDirectory = URL.cachesDirectory.appendingPathComponent("nodus-http", isDirectory: true)
        connections = Self.loadConnections(key: Self.defaultsKey)
        // Earlier live connections used the network address as identity. Preserve the
        // explicitly selected execution mode when upgrading to Mac + vault identity.
        for connection in connections where connection.desktopPairingId != nil {
            let key = "ai-execution-mode:\(connection.id)"
            let legacy = "ai-execution-mode:\(connection.origin)|\(connection.spaceId)"
            if UserDefaults.standard.string(forKey: key) == nil, let mode = UserDefaults.standard.string(forKey: legacy) {
                UserDefaults.standard.set(mode, forKey: key)
            }
        }
    }

    /// The connections on disk, without an `AppModel` to ask.
    ///
    /// The background tasks run in a process that may have no window and therefore no model,
    /// and they still need to know which spaces this device holds a token for.
    static func storedConnections() -> [Connection] {
        loadConnections(key: defaultsKey)
    }

    /// The connections a background task may act on.
    ///
    /// The example vault is not one of them, and not merely as an optimisation: it has no
    /// server, so every job that could pick it up — flushing a queue, refreshing a stale
    /// mirror — would wake the device to discover there is nobody to talk to, and would report
    /// failure for a space that is perfectly healthy and permanently current.
    static func syncableConnections() -> [Connection] {
        storedConnections().filter { !$0.isDemo && $0.desktopPairingId != nil }
    }

    var hasAnyConnection: Bool { !connections.isEmpty }

    var mostRecent: Connection? {
        connections.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    // MARK: - Connecting

    /// Step one: reach a server and ask what it supports, before asking the user for anything.
    ///
    /// Everything it can throw is a `ConnectionFailure`, because the address field is where a
    /// person meets every one of these for the first time and "could not connect to server" is
    /// no help at any of them.
    func probe(_ input: String) async throws -> (ServerAddress, ServerCapabilities) {
        let address: ServerAddress
        do {
            address = try ServerAddress(validating: input)
        } catch {
            throw ConnectionFailure.badAddress(input)
        }

        // A session of its own, so the certificate can be looked at. The default session waits
        // for connectivity, and while it waits it ignores request timeouts — so an address with
        // nothing behind it left the screen saying "looking for the server" indefinitely
        // instead of saying there was nothing there.
        let inspector = CertificateInspector()
        let session = URLSession.nodusProbe(observing: inspector)
        defer { session.finishTasksAndInvalidate() }
        let client = NodusClient(
            address: address,
            session: session,
            cache: ResponseCache(directory: cacheDirectory)
        )

        do {
            // Four seconds, not the session's twelve. A sleeping computer answers nothing at
            // all, and the only way to say so promptly is to stop waiting promptly; a server
            // that is actually there answers this in well under a second on any network the
            // app can reach it over.
            let capabilities = try await client.capabilities(timeout: 4)
            // It answered, so it is a Nodus Server. The one thing left that makes an address
            // unusable is a release this build cannot read, and only the capabilities can say.
            let gap = ConnectionFailure.gap(between: capabilities, appVersion: NodusVersion.current)
            guard !gap.blocks else { throw ConnectionFailure.versionGap(gap) }
            return (address, capabilities)
        } catch let failure as ConnectionFailure {
            throw failure
        } catch {
            // The network is measured only now, on the way out. Asking first would put a
            // monitor in front of every successful connection to answer a question that only
            // matters when something has already gone wrong — and half a second is the whole
            // of what is left of the five in which a sleeping computer has to be named.
            let network = await NetworkReachability.current(within: 0.5)
            let host = ConnectionFailure.host(of: address.origin)
            throw ConnectionFailure.classify(
                error: error,
                origin: address.origin,
                network: network,
                knock: .unauthenticated,
                appVersion: NodusVersion.current,
                fingerprint: inspector.evidence(for: host)?.fingerprint
            ) ?? .unclassified(host: host, detail: error.localizedDescription)
        }
    }

    /// Run the checks against one of this device's connections.
    ///
    /// It lives here and not in the diagnostics view because the token does. Connections are in
    /// `UserDefaults` and their tokens are in the Keychain, and a token is only ever read back
    /// into a client — never into a view. The view receives a report, which is built so that it
    /// cannot carry one.
    func diagnose(_ connection: Connection) async -> ConnectionReport {
        await ConnectionDiagnostics.run(
            address: ServerAddress(trusted: connection.origin),
            token: keychain.value(for: KeychainStore.deviceTokenKey(
                origin: connection.origin,
                spaceId: connection.spaceId
            )),
            cacheDirectory: cacheDirectory
        )
    }

    func signIn(to address: ServerAddress, email: String, password: String) async throws -> LoginTicket {
        let client = NodusClient(address: address, cache: ResponseCache(directory: cacheDirectory))
        return try await client.login(email: email, password: password)
    }

    /// Step two: take a token for one space and remember it.
    @discardableResult
    func connect(to address: ServerAddress, ticket: LoginTicket, space: SpaceSummary) async throws -> Connection {
        let client = NodusClient(address: address, cache: ResponseCache(directory: cacheDirectory))
        let credential = try await client.createDeviceToken(
            ticket: ticket.ticket,
            spaceId: space.id,
            deviceName: Self.deviceName
        )
        try keychain.set(
            credential.token,
            for: KeychainStore.deviceTokenKey(origin: address.origin, spaceId: space.id)
        )

        var connection = Connection(
            origin: address.origin,
            spaceId: space.id,
            spaceName: credential.spaceName,
            serverName: ticket.server.name,
            role: credential.role,
            vaultType: credential.vault?.type ?? space.vault?.type,
            vaultName: credential.vault?.name ?? space.vault?.name,
            lastOpenedAt: Date(),
            // Re-authenticating an existing connection is not adding it again: the date the
            // list sorts by is the first time this device held a credential for the space.
            addedAt: connections.first { $0.id == "\(address.origin)|\(space.id)" }?.addedAt ?? Date()
        )
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        connection.lastOpenedAt = Date()
        persist()
        return connection
    }

    /// Pairing-code path, for servers that hand out codes instead of accounts.
    @discardableResult
    func pair(to address: ServerAddress, code: String) async throws -> Connection {
        let client = NodusClient(address: address, cache: ResponseCache(directory: cacheDirectory))
        let result = try await client.pair(code: code, deviceName: Self.deviceName)
        try keychain.set(
            result.accessToken,
            for: KeychainStore.deviceTokenKey(origin: address.origin, spaceId: result.space.id)
        )
        // A pairing code says nothing about the role or the vault; `/me` does.
        let connected = NodusClient(address: address, token: result.accessToken, cache: ResponseCache(directory: cacheDirectory))
        let me = try await connected.me()
        let summary = me.spaces.first { $0.id == result.space.id }

        let connection = Connection(
            origin: address.origin,
            spaceId: result.space.id,
            spaceName: result.space.name,
            serverName: result.server.name,
            role: summary?.role ?? .reader,
            vaultType: summary?.vault?.type,
            vaultName: summary?.vault?.name,
            lastOpenedAt: Date(),
            addedAt: connections.first { $0.id == "\(address.origin)|\(result.space.id)" }?.addedAt ?? Date()
        )
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        persist()
        return connection
    }

    // MARK: - Opening

    func connectDesktop(pairing: DesktopBridgePairing, token: String, expectedMacId: String? = nil) async throws {
#if DEBUG
        // Interrupt only the post-pairing capability stage in UI acceptance.
        // The real Mac POST and durable credential storage have already run.
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_FAIL_PAIRING_CAPABILITIES_ONCE"] == "1",
           !acceptanceCapabilitiesFailureDelivered {
            acceptanceCapabilitiesFailureDelivered = true
            throw URLError(.networkConnectionLost)
        }
#endif
        let capabilities = try await DesktopBridgeClient(pairing: pairing, token: token).liveCapabilities()
        guard capabilities.protocolVersion == 2 else { throw DesktopBridgeError.malformedResponse }
        if let expectedMacId, capabilities.deviceId != expectedMacId { throw DesktopBridgeError.permissionDenied }
        guard !capabilities.vaults.isEmpty,
              Set(capabilities.vaults.map(\.id)).isSubset(of: pairing.vaultIds) else { throw DesktopBridgeError.permissionDenied }
        try DesktopBridgePairingStore().save(pairing, token: token)
        for vault in capabilities.vaults {
            let spaceId = "live:\(capabilities.deviceId):\(vault.id)"
            let previous = connections.first { $0.desktopPairingId != nil && $0.spaceId == spaceId }
            try keychain.set(token, for: KeychainStore.deviceTokenKey(origin: pairing.origin, spaceId: spaceId))
            let connection = Connection(origin: pairing.origin, spaceId: spaceId, spaceName: vault.name,
                serverName: capabilities.deviceName, role: pairing.domains.contains(.writing) ? .writer : .reader, vaultType: vault.type, vaultName: vault.name,
                lastOpenedAt: previous?.lastOpenedAt, addedAt: previous?.addedAt ?? Date(), vaultId: vault.id, desktopPairingId: pairing.id)
            connections.removeAll { $0.id == connection.id || ($0.desktopPairingId != nil && $0.spaceId == spaceId) }
            connections.append(connection)
        }
        persist()
        try DesktopBridgePairingStore().completePendingPairing(grantId: pairing.id)
    }

    /// Enter the linked workspace immediately, preserving the last vault on renewal.
    @discardableResult
    func openLinkedDesktopWorkspace(pairingId: String) -> Bool {
        let linked = connections.filter { $0.desktopPairingId == pairingId }
        let recent = linked.filter { $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
        guard let connection = recent ?? linked.first(where: { $0.vaultId == "default" }) ?? linked.first else { return false }
        return open(connection)
    }

    /// Whether this device still holds a credential for a connection.
    ///
    /// The picker asks before it draws, because a connection with no token is not a space you
    /// can open — and a card that looks identical to the ones that work, and does nothing when
    /// tapped, is indistinguishable from a broken app.
    func hasCredential(for connection: Connection) -> Bool {
        // The example vault needs none and can never lose one. Asking the Keychain would answer
        // no, and the picker would draw the one card that always works as the one card that is
        // broken.
        if connection.isDemo { return true }
        return keychain.contains(KeychainStore.deviceTokenKey(origin: connection.origin, spaceId: connection.spaceId))
    }

    /// Why the example vault could not be opened, when it could not be.
    ///
    /// It is the one space whose failure is a fault in the build rather than in the network or
    /// in a credential, so it is said on the picker instead of being swallowed.
    private(set) var demoFailure: String?

    func clearDemoFailure() { demoFailure = nil }

    /// Opens the example vault, importing its snapshot the first time.
    ///
    /// Separate from `open` because it is genuinely asynchronous — a snapshot is read from the
    /// bundle and imported into a mirror — while opening a server space is a Keychain read and
    /// a constructor. Folding the two together would make every card on the picker wait on a
    /// task for the benefit of one of them.
    @discardableResult
    func openDemo() async -> Bool {
        isOpeningLocalCorpus = true
        defer { isOpeningLocalCorpus = false }
        do {
            let prepared = try await DemoSpace.prepare()
            var connection = prepared.connection
            connection.lastOpenedAt = Date()
            // Remembered like any other space, so leaving it lands on a picker that can go back
            // in rather than on the empty state it came from.
            connection.addedAt = connections.first { $0.id == connection.id }?.addedAt ?? Date()
            connections.removeAll { $0.id == connection.id }
            connections.append(connection)
            persist()

            needsSignIn = nil
            demoFailure = nil
            session = SpaceSession(demo: connection, corpus: prepared.corpus, cacheDirectory: cacheDirectory)
            return true
        } catch {
            demoFailure = error.localizedDescription
            return false
        }
    }

#if DEBUG
    func reportAcceptanceFailure(_ error: Error) { demoFailure = error.localizedDescription }
    /// Acceptance imports use the production snapshot decoder and local client.
    /// Only a marked folder inside this app's sandbox is eligible; Release has no loader.
    func openAcceptanceSnapshot(_ filename: String) async throws {
        isOpeningLocalCorpus = true
        defer { isOpeningLocalCorpus = false }
        let permitted: [String: VaultType] = ["study-snapshot.json": .estudio,
            "teaching-snapshot.json": .docencia, "dictionary-snapshot.json": .academic,
            "research-damaged-snapshot.json": .academic, "research-repaired-snapshot.json": .academic]
        guard let expectedType = permitted[filename] else {
            throw DesktopBridgeError.permissionDenied
        }
        let folder = URL.applicationSupportDirectory.appendingPathComponent("AcceptanceLab", isDirectory: true)
        let marker = folder.appendingPathComponent(".nodus-mobile-acceptance-lab")
        guard (try? String(contentsOf: marker, encoding: .utf8)) == "Nodus Mobile isolated acceptance fixture\n" else {
            throw DesktopBridgeError.permissionDenied
        }
        let (archive, snapshot) = try await Task.detached(priority: .userInitiated) {
            let archive = try Data(contentsOf: folder.appendingPathComponent(filename))
            return (archive, try SnapshotDownload.read(archive))
        }.value
        guard let vaultType = snapshot.vault?.type, vaultType == expectedType else {
            throw DesktopBridgeError.malformedResponse
        }
        let spaceId = "nodus-acceptance-\(vaultType.rawValue)"
        let directory = folder.appendingPathComponent("mirrors", isDirectory: true)
        let mirror = try await MirrorStore.open(spaceId: spaceId, directory: directory)
        let revision = snapshot.revision ?? ""
        if try await !mirror.isCurrent(with: revision) {
            try await mirror.replace(with: snapshot, revision: revision)
        }
        let name = "Aceptación · \(vaultType.rawValue)"
        let connection = Connection(origin: DemoSpace.origin, spaceId: spaceId, spaceName: name,
            serverName: "Laboratorio local", role: .reader, vaultType: vaultType, vaultName: name)
        let images = folder.appendingPathComponent("published-images", isDirectory: true)
        if FileManager.default.fileExists(atPath: images.path) {
            let assets = PublishedAssetStore()
            for hash in Set(snapshot.assetRefs.flatMap { [$0.hash, $0.thumbHash].compactMap { $0 } }) {
                let bytes = try await Task.detached { try Data(contentsOf: images.appendingPathComponent(hash)) }.value
                try await assets.write(bytes, hash: hash, origin: connection.origin, spaceId: spaceId)
            }
        }
        let corpus = LocalCorpus(space: .init(id: spaceId, name: name), mirror: mirror, archive: archive)
        needsSignIn = nil
        demoFailure = nil
        session = SpaceSession(demo: connection, corpus: corpus, cacheDirectory: cacheDirectory)
    }
#endif

    /// Opens a space, or reports that it cannot be opened.
    ///
    /// The return value is the whole point. This used to return silently when the token was
    /// gone — revoked, expired, or wiped with the app's data — leaving a card on the picker
    /// that did nothing at all when tapped, forever, with nothing on screen to say why. The
    /// comment that stood here said the connection was kept "so the user can sign in again";
    /// there was no way to sign in again, and nothing ever suggested there was one.
    @discardableResult
    func open(_ connection: Connection) -> Bool {
        guard let token = keychain.value(for: KeychainStore.deviceTokenKey(
            origin: connection.origin,
            spaceId: connection.spaceId
        )) else {
            session = nil
            needsSignIn = connection
            return false
        }
        needsSignIn = nil
        lastFailure = nil
        let updated = { var copy = connection; copy.lastOpenedAt = Date(); return copy }()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = updated
            persist()
        }
        guard let opened = SpaceSession(
            connection: updated,
            token: token,
            cacheDirectory: cacheDirectory,
            onUnauthorized: { [weak self, updated] in await self?.handleRevocation(of: updated) },
            onFailure: { [weak self, updated] failure in self?.report(failure, on: updated) }
        ) else {
            session = nil
            needsSignIn = updated
            return false
        }
        session = opened
        return true
    }

    func closeSession() { session = nil }

    /// The connection whose credential is gone, set the moment that is discovered.
    ///
    /// It reaches the picker as a sentence and a way out. A revocation used to close the
    /// session and drop the user back on the list with no explanation at all, which reads as
    /// the app having lost its place rather than the server having said no.
    private(set) var needsSignIn: Connection?

    func clearSignInNotice() { needsSignIn = nil }

    /// The last time reaching a server went wrong, and which space it was.
    ///
    /// The picker is where somebody lands after a space fails to open, and until now it said
    /// nothing at all about why — the shell knew, and the shell was the screen they had just
    /// left. A revoked credential has had its own notice here for a while; a sleeping computer
    /// deserves the same one, next to it.
    private(set) var lastFailure: (connection: Connection, failure: ConnectionFailure)?

    func report(_ failure: ConnectionFailure, on connection: Connection) {
        // A credential the server has stopped accepting already has a notice of its own, raised
        // from the 401 handler. Two notices about one fact is one notice too many.
        if case .credentialRejected = failure { return }
        lastFailure = (connection, failure)
    }

    func clearFailureNotice() { lastFailure = nil }

    /// A 401 means this token no longer opens this space. Drop the secret but keep the
    /// connection: the user's next move is to sign in again, not to retype a server address.
    private func handleRevocation(of connection: Connection) async {
        try? keychain.remove(KeychainStore.deviceTokenKey(origin: connection.origin, spaceId: connection.spaceId))
        session = nil
        needsSignIn = connection
    }

    func forget(_ connection: Connection) {
        try? keychain.remove(KeychainStore.deviceTokenKey(origin: connection.origin, spaceId: connection.spaceId))
        // The example vault's whole corpus is a mirror this app wrote, and forgetting a space
        // whose database is still on disk is not forgetting it. A server space keeps its mirror
        // on purpose — the credential can be taken again and the download is expensive — but
        // this one is rebuilt from the bundle in a fraction of a second.
        if connection.isDemo { DemoSpace.removeStoredData() }
        connections.removeAll { $0.id == connection.id }
        if session?.connection.id == connection.id { session = nil }
        persist()
    }

    /// Rotate the credential without changing the grant or its local storage identity.
    func renewDesktop(_ connection: Connection) async throws {
        let store = DesktopBridgePairingStore()
        guard let pairing = store.pairings().first(where: { $0.id == connection.desktopPairingId }),
              let token = store.credential(for: pairing) else { throw DesktopBridgeError.permissionDenied }
        let renewed = try await DesktopBridgeClient(pairing: pairing, token: token).renew()
        for linked in connections.filter({ $0.desktopPairingId == pairing.id }) {
            try keychain.set(renewed, for: KeychainStore.deviceTokenKey(origin: linked.origin, spaceId: linked.spaceId))
        }
        // Grant and connection IDs stay fixed: drafts, downloads, jobs and the active
        // session continue under their existing storage identity.
    }

    /// Revocation applies to the whole device grant, including every linked vault.
    func revokeDesktop(_ connection: Connection) async throws {
        let store = DesktopBridgePairingStore()
        guard let pairing = store.pairings().first(where: { $0.id == connection.desktopPairingId }),
              let token = store.credential(for: pairing) else { throw DesktopBridgeError.permissionDenied }
        try await DesktopBridgeClient(pairing: pairing, token: token).revoke()
        try store.revokeLocally(pairing)
        await DesktopJobLedgers.shared.forget(pairingId: pairing.id)
        await CompanionDocumentOutboxes.shared.forget(pairingId: pairing.id)
        await CompanionImmersionProgressOutboxes.shared.forget(pairingId: pairing.id)
        for linked in connections.filter({ $0.desktopPairingId == pairing.id }) { forget(linked) }
    }

    // MARK: - Persistence

    private func persist() {
        guard let data = try? JSONEncoder().encode(connections) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func loadConnections(key: String) -> [Connection] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode([Connection].self, from: data)
        else { return [] }
        // The demo's name and server are catalogue strings, and what was stored is whatever
        // language the phone was in when it was first opened. Everything else on the list was
        // named by a server and stays as it was named.
        return decoded.map { $0.isDemo ? DemoSpace.refreshed($0) : $0 }
    }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        "Nodus"
        #endif
    }
}
