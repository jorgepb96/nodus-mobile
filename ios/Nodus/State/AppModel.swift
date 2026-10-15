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
        var macDeviceId: String? = nil
        var authoringRecoveryNotice: String? = nil

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
    private var closingDesktopGrants = Set<String>()
    private var connectingDesktopGrants = Set<String>()
    private var refreshingDesktopCatalogues = false
    var isClosingDesktopGrant: Bool { !closingDesktopGrants.isEmpty }
    private(set) var desktopRecoveryIssue: String?

    private let keychain = KeychainStore()
    private static let defaultsKey = "nodus.connections.v1"
    private let cacheDirectory: URL
#if DEBUG
    private var acceptanceCapabilitiesFailureDelivered = false
#endif

    private let linkedMacDiscovery = LinkedMacDiscovery()
    private var linkedDiscoveryTasks: [String: Task<Void, Never>] = [:]
    private var linkedDiscoveryAttempts: [String: Date] = [:]
    private var linkedDiscoveryOperationIds: [String: UUID] = [:]

    func stopLinkedMacDiscovery() {
        linkedMacDiscovery.stop()
        linkedDiscoveryTasks.values.forEach { $0.cancel() }; linkedDiscoveryTasks = [:]
        linkedDiscoveryAttempts = [:]; linkedDiscoveryOperationIds = [:]
    }
    private func receiveLinkedMacAdvertisement(_ advertisement: DesktopLinkedMacAdvertisement) {
        guard connectingDesktopGrants.isEmpty else { return }
        let store = DesktopBridgePairingStore()
        for pairing in store.pairings() where !pairing.isExpired {
            let linked = connections.filter { $0.desktopPairingId == pairing.id }
            guard !linked.isEmpty,
                  pairing.macDeviceId == advertisement.macDeviceId || (pairing.macDeviceId == nil && linked.allSatisfy({ connection in
                      guard let vault = connection.vaultId else { return false }
                      return connection.macDeviceId == advertisement.macDeviceId || connection.spaceId == "live:\(advertisement.macDeviceId):\(vault)"
                  })), linkedDiscoveryTasks[pairing.id] == nil,
                  Date().timeIntervalSince(linkedDiscoveryAttempts[pairing.id] ?? .distantPast) >= 20,
                  (try? store.hasPendingWorkspaceRegistration(grantId: pairing.id)) == false,
                  let token = store.credential(for: pairing) else { continue }
            linkedDiscoveryAttempts[pairing.id] = Date()
            let operationId = UUID(); linkedDiscoveryOperationIds[pairing.id] = operationId
            linkedDiscoveryTasks[pairing.id] = Task { [weak self] in
                guard let self else { return }
                defer { if self.linkedDiscoveryOperationIds[pairing.id] == operationId { self.linkedDiscoveryTasks[pairing.id] = nil; self.linkedDiscoveryOperationIds[pairing.id] = nil } }
                let client = DesktopBridgeClient(pairing: pairing, token: token)
                let candidates = advertisement.origins.contains(pairing.origin)
                    ? [pairing.origin] + advertisement.origins.filter { $0 != pairing.origin } : advertisement.origins
                var verifiedPrimary = false
                for origin in candidates {
                    guard !Task.isCancelled, self.connectingDesktopGrants.isEmpty else { return }
                    do {
                        let updated = try await client.verifyDiscoveredOrigin(origin, trustedMacDeviceId: advertisement.macDeviceId, makePrimary: !verifiedPrimary)
                        guard !Task.isCancelled, self.connectingDesktopGrants.isEmpty,
                              (try? store.hasPendingWorkspaceRegistration(grantId: pairing.id)) == false,
                              let credential = store.credential(for: updated) else { return }
                        verifiedPrimary = true
                        // Keep connection/storage/preference identities and mounted editors.
                        // Only the transport address and its corresponding credential alias change.
                        var obsoleteAliases: [(String, String)] = []
                        for index in self.connections.indices where self.connections[index].desktopPairingId == updated.id {
                            let connection = self.connections[index]
                            try self.keychain.set(credential, for: KeychainStore.deviceTokenKey(origin: updated.origin, spaceId: connection.spaceId))
                            if connection.origin != updated.origin { obsoleteAliases.append((connection.origin, connection.spaceId)) }
                            self.connections[index].origin = updated.origin
                            self.connections[index].macDeviceId = advertisement.macDeviceId
                            if self.session?.connection.id == connection.id { self.session?.refreshConnectionMetadata(self.connections[index]) }
                        }
                        self.persist()
                        for (oldOrigin, spaceId) in obsoleteAliases {
                            do { try self.keychain.remove(KeychainStore.deviceTokenKey(origin: oldOrigin, spaceId: spaceId)) }
                            catch { self.desktopRecoveryIssue = error.localizedDescription }
                        }
                    } catch where Task.isCancelled { return }
                    catch { /* An untrusted or unreachable hint leaves the approved origin intact. */ }
                }
                if verifiedPrimary, !Task.isCancelled, let session = self.session, session.connection.desktopPairingId == pairing.id {
                    if session.loadFailure != nil { await session.load() }
                    await session.probeEmbedding(retryUnavailable: true)
                    await session.refreshPublishedContent()
                }
            }
        }
    }

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

#if DEBUG
    /// An explicit lab marker and UUID confine every fixture write; ordinary connections
    /// are hidden only in memory and are never removed or persisted by this fixture.
    func prepareAuthoringRecoveryAcceptance() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["NODUS_ACCEPTANCE_AUTHORING_RECOVERY"], let id = UUID(uuidString: raw) else { throw DesktopBridgeError.permissionDenied }
        let lab = URL.applicationSupportDirectory.appendingPathComponent("AcceptanceLab", isDirectory: true)
        guard (try? String(contentsOf: lab.appendingPathComponent(".nodus-mobile-acceptance-lab"), encoding: .utf8)) == "Nodus Mobile isolated acceptance fixture\n" else { throw DesktopBridgeError.permissionDenied }
        connections = []; session = nil
        let ready = lab.appendingPathComponent("recovery-" + id.uuidString + ".ready")
        if FileManager.default.fileExists(atPath: ready.path) { return }
        let grant = "recovery-ui-" + id.uuidString
        let cache = try PrivateBridgeCache(pairingId: grant)
        let queue = try await CompanionDocumentOutboxes.shared.outbox(pairingId: grant, vaultId: "recovery-ui-vault")
        _ = try await queue.create(input: .object(["title": .string("Borrador aislado de recuperación"), "content": .string("")]))
        try await cache.store(Data("Consulted source must not survive".utf8), vaultId: "recovery-ui-vault", domain: .corpus, recordId: "consulted")
        let pairing = try DesktopBridgePairing(id: grant, origin: "https://recovery.invalid:7443", certificateFingerprint: String(repeating: "a", count: 64), deviceId: "isolated-phone", deviceName: "Isolated fixture", vaultIds: ["recovery-ui-vault"], domains: [.writing, .corpus], pairedAt: Date(), expiresAt: Date().addingTimeInterval(600))
        let suite = "nodus.recovery.ui." + id.uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw DesktopBridgeError.malformedResponse }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DesktopBridgePairingStore(defaults: defaults)
        try store.save(pairing, token: "isolated-fixture-not-a-real-grant")
        try await CompanionDocumentOutboxes.shared.prepareForRevocation(pairingId: grant)
        try await cache.freezeForRevocation(true)
        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: pairing.vaultIds)
        let receipt = try await PrivateBridgeAuthoringRecovery.shared.preserve(snapshot: snapshot, pairing: pairing, macDeviceId: nil)
        try store.revokeLocally(pairing, authoringRecovery: receipt)
        try await PrivateBridgeAuthoringRecovery.shared.completeRevocation(receipt)
        await CompanionDocumentOutboxes.shared.forget(pairingId: grant)
        guard store.credential(for: pairing) == nil else { throw DesktopBridgeError.permissionDenied }
        try Data("complete".utf8).write(to: ready, options: .atomic)
    }
#endif

    // MARK: - Opening

    func connectDesktop(pairing proposedPairing: DesktopBridgePairing, token: String, expectedMacId: String? = nil) async throws {
#if DEBUG
        // Interrupt only the post-pairing capability stage in UI acceptance.
        // The real Mac POST and durable credential storage have already run.
        if ProcessInfo.processInfo.environment["NODUS_ACCEPTANCE_FAIL_PAIRING_CAPABILITIES_ONCE"] == "1",
           !acceptanceCapabilitiesFailureDelivered {
            acceptanceCapabilitiesFailureDelivered = true
            throw URLError(.networkConnectionLost)
        }
#endif
        guard connectingDesktopGrants.insert(proposedPairing.id).inserted else { throw DesktopBridgeError.permissionDenied }
        defer { connectingDesktopGrants.remove(proposedPairing.id) }
        var pairing = proposedPairing
        let capabilities = try await DesktopBridgeClient(pairing: pairing, token: token).liveCapabilities()
        guard capabilities.protocolVersion == 2 else { throw DesktopBridgeError.malformedResponse }
        if let expectedMacId, capabilities.deviceId != expectedMacId { throw DesktopBridgeError.permissionDenied }
        pairing = try pairing.refreshedWorkspace(capabilities, trustedMacDeviceId: capabilities.deviceId)
        guard !capabilities.vaults.isEmpty || pairing.wholeWorkspace == true else { throw DesktopBridgeError.permissionDenied }
        // Retire previous grants only after the new pinned handshake proves the same Mac.
        let pairingStore = DesktopBridgePairingStore()
        var retired = Set<String>()
        for linked in connections where linked.desktopPairingId != nil && linked.desktopPairingId != pairing.id {
            guard let oldId = linked.desktopPairingId, !retired.contains(oldId),
                  let old = pairingStore.pairings().first(where: { $0.id == oldId }),
                  old.certificateFingerprint == pairing.certificateFingerprint,
                  let vault = linked.vaultId,
                  linked.macDeviceId == capabilities.deviceId || (linked.macDeviceId == nil && linked.spaceId == "live:\(capabilities.deviceId):\(vault)") else { continue }
            // The freshly approved address reaches the same pinned installation, even
            // when its previous LAN address no longer exists.
            if let oldToken = pairingStore.credential(for: old) {
                let reachable = try DesktopBridgePairing(id: old.id, origin: pairing.origin,
                    certificateFingerprint: old.certificateFingerprint, deviceId: old.deviceId,
                    deviceName: old.deviceName, vaultIds: old.vaultIds, domains: old.domains,
                    pairedAt: old.pairedAt, expiresAt: old.expiresAt,
                    alternateOrigins: pairing.alternateOrigins ?? [], wholeWorkspace: old.wholeWorkspace, macDeviceId: old.macDeviceId, retainedAuthoringVaultIds: old.retainedAuthoringVaultIds)
                try pairingStore.save(reachable, token: oldToken)
            }
            for index in connections.indices where connections[index].desktopPairingId == oldId {
                guard let oldVault = connections[index].vaultId,
                      connections[index].spaceId == "live:\(capabilities.deviceId):\(oldVault)" else { throw DesktopBridgeError.permissionDenied }
                connections[index].macDeviceId = capabilities.deviceId
            }
            try await revokeDesktop(connections.first { $0.id == linked.id } ?? linked)
            retired.insert(oldId)
        }
        var recoveryNotice: String?
        do {
            let cache = try PrivateBridgeCache(pairingId: pairing.id)
            try await cache.freezeForRevocation(false)
            let restored = try await PrivateBridgeAuthoringRecovery.shared.adopt(pairing: pairing, macDeviceId: capabilities.deviceId, cache: cache)
            if restored > 0 { recoveryNotice = "Tu trabajo local se ha recuperado. Revisa los cambios y resultados antes de enviarlos al Mac." }
        } catch {
            // Keep the resumable pairing and originals until recovery completes.
            throw error
        }
        try DesktopBridgePairingStore().save(pairing, token: token)
        try registerDesktopVaults(pairing: pairing, token: token, capabilities: capabilities, recoveryNotice: recoveryNotice, finishingPairing: true)
    }

    private func registerDesktopVaults(pairing: DesktopBridgePairing, token: String, capabilities: DesktopLiveCapabilities, recoveryNotice: String? = nil, finishingPairing: Bool = false) throws {
        if !finishingPairing, try DesktopBridgePairingStore().hasPendingWorkspaceRegistration(grantId: pairing.id) { throw DesktopBridgeError.permissionDenied }
        for vault in capabilities.vaults {
            let spaceId = "live:\(capabilities.deviceId):\(vault.id)"
            let previous = connections.first { $0.desktopPairingId != nil && $0.spaceId == spaceId }
            try keychain.set(token, for: KeychainStore.deviceTokenKey(origin: pairing.origin, spaceId: spaceId))
            let connection = Connection(origin: pairing.origin, spaceId: spaceId, spaceName: vault.name,
                serverName: capabilities.deviceName, role: pairing.domains.contains(.writing) ? .writer : .reader, vaultType: vault.type, vaultName: vault.name,
                lastOpenedAt: previous?.lastOpenedAt, addedAt: previous?.addedAt ?? Date(), vaultId: vault.id, desktopPairingId: pairing.id,
                macDeviceId: capabilities.deviceId, authoringRecoveryNotice: recoveryNotice ?? previous?.authoringRecoveryNotice)
            connections.removeAll { $0.id == connection.id || ($0.desktopPairingId != nil && $0.spaceId == spaceId) }
            connections.append(connection)
            if session?.connection.id == connection.id { session?.refreshConnectionMetadata(connection) }
        }
        persist()
        if finishingPairing { try DesktopBridgePairingStore().completePendingPairing(grantId: pairing.id) }

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
        if connection.desktopPairingId != nil { return ConnectionClient.credential(for: connection) != nil }
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
        guard let token = ConnectionClient.credential(for: connection) else {
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
        if let pairingId = connection.desktopPairingId {
            if DesktopBridgePairingStore().isAuthorizationRevoked(pairingId: pairingId) { await handleDesktopAuthorizationRevocation(pairingId: pairingId) }
            return
        }
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

    /// General reader/table edits live outside the structured editor queues.
    /// Include their exact SQLite payloads and receipts in the encrypted work export.
    private func preserveMutationOutboxes(pairingId: String, vaultIds: Set<String>, cache: PrivateBridgeCache) async throws {
        for connection in connections where connection.desktopPairingId == pairingId {
            guard let vault = connection.vaultId, vaultIds.contains(vault),
                  MutationOutbox.exists(spaceId: connection.storageId, directory: ConnectionClient.spacesDirectory) else { continue }
            let queue = try await MutationOutbox.open(spaceId: connection.storageId, directory: ConnectionClient.spacesDirectory)
            if let data = try await queue.authoringRecoveryData(vaultId: vault) {
                try await cache.store(data, vaultId: vault, domain: .writing, recordId: "companion-mutation-outbox-v1")
            }
        }
    }

    /// Revocation applies to the whole device grant, including every linked vault.
    func revokeDesktop(_ connection: Connection, knownRemoteRevocation: Bool = false) async throws {
        let store = DesktopBridgePairingStore()
        guard let pairing = store.pairings(includeRevoked: knownRemoteRevocation).first(where: { $0.id == connection.desktopPairingId }),
              !knownRemoteRevocation || store.isAuthorizationRevoked(pairingId: pairing.id),
              knownRemoteRevocation || store.credential(for: pairing) != nil else { throw DesktopBridgeError.permissionDenied }
        if !knownRemoteRevocation {
            guard closingDesktopGrants.insert(pairing.id).inserted else { throw PrivateBridgeAuthoringRecovery.RecoveryError.activeGeneration }
        }
        defer { if !knownRemoteRevocation { closingDesktopGrants.remove(pairing.id) } }
        let token = store.credential(for: pairing) ?? ""
        let bridge = DesktopBridgeClient(pairing: pairing, token: token)
        let identities = Set(connections.filter { $0.desktopPairingId == pairing.id }.compactMap(\.macDeviceId))
        guard identities.count <= 1 else { throw DesktopBridgeError.permissionDenied }
        var macIdentity = identities.first
        if !knownRemoteRevocation, macIdentity == nil, let capabilities = try? await bridge.liveCapabilities() {
            let linked = connections.filter { $0.desktopPairingId == pairing.id }
            guard linked.allSatisfy({ connection in
                guard let vault = connection.vaultId else { return false }
                return connection.spaceId == "live:\(capabilities.deviceId):\(vault)"
            }) else { throw DesktopBridgeError.permissionDenied }
            macIdentity = capabilities.deviceId
        }
        if knownRemoteRevocation { try await PrivateBridgeCache.waitForAuthoringToFinish(pairingId: pairing.id) }
        let cache = try PrivateBridgeCache(pairingId: pairing.id)
        var receipt: PrivateBridgeAuthoringRecovery.Receipt?
        var revokedOnMac = knownRemoteRevocation
        do {
            try cache.beginClosingForRevocation()
            try await cache.waitForAuthoringToFinish()
            try await CompanionDocumentOutboxes.shared.prepareForRevocation(pairingId: pairing.id)
            let authoringScope = pairing.vaultIds.union(pairing.retainedAuthoringVaultIds ?? [])
            try await preserveMutationOutboxes(pairingId: pairing.id, vaultIds: authoringScope, cache: cache)
            try await cache.freezeForRevocation(true)
            let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: authoringScope)
            if !snapshot.fingerprints.isEmpty {
                let archivePairing = try pairing.authoringArchiveScope(authoringScope)
                receipt = try await PrivateBridgeAuthoringRecovery.shared.preserve(snapshot: snapshot, pairing: archivePairing, macDeviceId: macIdentity ?? pairing.macDeviceId)
            }
            for linked in connections.filter({ $0.desktopPairingId == pairing.id }) {
                if MutationOutbox.exists(spaceId: linked.storageId, directory: ConnectionClient.spacesDirectory) {
                    let outbox = try MutationOutbox(spaceId: linked.storageId, directory: ConnectionClient.spacesDirectory)
                    try await outbox.suspendAuthorisedForRelink()
                }
            }
            do { if !knownRemoteRevocation, !pairing.isExpired { try await bridge.revoke() } }
            catch DesktopBridgeError.credentialRevoked { /* Authenticated Bridge rejected this exact stored credential. */ }
            revokedOnMac = true
            try store.revokeLocally(pairing, authoringRecovery: receipt)
            if let receipt { try await PrivateBridgeAuthoringRecovery.shared.completeRevocation(receipt) }
        } catch {
            if store.isAuthorizationRevoked(pairingId: pairing.id) { revokedOnMac = true }
            if knownRemoteRevocation || revokedOnMac { try? await cache.purgeReadingCopies() }
            if !revokedOnMac {
                try? await cache.freezeForRevocation(false)
                // Sealed instances stay retired; future editors reopen the durable state.
                await CompanionDocumentOutboxes.shared.forget(pairingId: pairing.id)
                if let receipt { try? await PrivateBridgeAuthoringRecovery.shared.discard(receipt) }
            }
            throw error
        }
        await DesktopJobLedgers.shared.forget(pairingId: pairing.id)
        await CompanionDocumentOutboxes.shared.forget(pairingId: pairing.id)
        await CompanionPageDocumentStores.shared.forget(pairingId: pairing.id)
        await CompanionImmersionProgressOutboxes.shared.forget(pairingId: pairing.id)
        await CompanionDatabaseReadingOutboxes.shared.forget(pairingId:pairing.id)
        var cleanupIssue: (any Error)?
        for linked in connections.filter({ $0.desktopPairingId == pairing.id }) {
            do { try ChatHistoryStore.shared(spaceId:linked.storageId).revokeLink() } catch { cleanupIssue = error }
            for origin in Set([linked.origin, pairing.origin] + (pairing.alternateOrigins ?? [])) {
                do { try keychain.remove(KeychainStore.deviceTokenKey(origin: origin, spaceId: linked.spaceId)) }
                catch { cleanupIssue = error }
            }
            forget(linked)
        }
        if let cleanupIssue { throw cleanupIssue }
    }

    func handleDesktopAuthorizationRevocation(pairingId: String) async {
        guard DesktopBridgePairingStore().isAuthorizationRevoked(pairingId: pairingId),
              closingDesktopGrants.insert(pairingId).inserted else { return }
        defer { closingDesktopGrants.remove(pairingId) }
        let linked = connections.filter { $0.desktopPairingId == pairingId }
        let pairing = DesktopBridgePairingStore().pairings(includeRevoked: true).first { $0.id == pairingId }
        let connection = linked.first ?? pairing.map { grant in
            Connection(origin: grant.origin, spaceId: "live-revoked:" + grant.id, spaceName: "Nodus", serverName: grant.deviceName,
                role: .reader, addedAt: grant.pairedAt, desktopPairingId: grant.id, macDeviceId: grant.macDeviceId)
        }
        guard let connection else { return }
        do { try await revokeDesktop(connection, knownRemoteRevocation: true); desktopRecoveryIssue = nil }
        catch {
            // After a known remote close, authorization stays blocked even if the
            // encrypted archive cannot yet be finalized. Original work/key remain.
            desktopRecoveryIssue = error.localizedDescription
            if let cache = try? PrivateBridgeCache(pairingId: pairingId) {
                try? await cache.purgeReadingCopies()
            }
            session = nil
            for item in linked { forget(item) }
        }
    }

    func refreshDesktopWorkspaceCatalogues() async {
        guard !refreshingDesktopCatalogues, connectingDesktopGrants.isEmpty else { return }
        refreshingDesktopCatalogues = true
        defer { refreshingDesktopCatalogues = false }
        let store = DesktopBridgePairingStore()
        let linkedIds = Set(connections.compactMap(\.desktopPairingId))
        let hasLinkedGrant = store.pairings().contains { pairing in
            linkedIds.contains(pairing.id) && !pairing.isExpired && store.credential(for: pairing) != nil
                && (try? store.hasPendingWorkspaceRegistration(grantId: pairing.id)) == false
        }
        if hasLinkedGrant {
            linkedMacDiscovery.start { [weak self] in self?.receiveLinkedMacAdvertisement($0) }
            for advertisement in linkedMacDiscovery.advertisements { receiveLinkedMacAdvertisement(advertisement) }
        } else { stopLinkedMacDiscovery() }
        for pending in store.pairings(includeRevoked: true) where store.isAuthorizationRevoked(pairingId: pending.id) {
            await handleDesktopAuthorizationRevocation(pairingId: pending.id)
        }
        for pairing in store.pairings() where pairing.wholeWorkspace == true {
            guard let token = store.credential(for: pairing) else { continue }
            do {
                guard try !store.hasPendingWorkspaceRegistration(grantId: pairing.id) else { continue }
                let capabilities = try await DesktopBridgeClient(pairing: pairing, token: token).liveCapabilities()
                guard connectingDesktopGrants.isEmpty, try !store.hasPendingWorkspaceRegistration(grantId: pairing.id) else { continue }
                let linked = connections.filter { $0.desktopPairingId == pairing.id }
                let identities = Set(linked.compactMap(\.macDeviceId))
                guard identities.count <= 1 else { throw DesktopBridgeError.permissionDenied }
                let trustedMac = pairing.macDeviceId ?? identities.first ?? (linked.allSatisfy({ connection in
                    guard let vault = connection.vaultId else { return false }
                    return connection.spaceId == "live:\(capabilities.deviceId):\(vault)"
                }) && !linked.isEmpty ? capabilities.deviceId : nil)
                guard let trustedMac else { throw DesktopBridgeError.permissionDenied }
                // Re-read current grant under the renewal lock; never restore the token
                // captured before awaiting the authenticated capability response.
                var refreshed = try store.updateWorkspaceMetadata(capabilities, expectedPairing: pairing, trustedMacDeviceId: trustedMac)
                let removed = (refreshed.retainedAuthoringVaultIds ?? []).subtracting(refreshed.vaultIds)
                if !removed.isEmpty {
                    let cache = try PrivateBridgeCache(pairingId: pairing.id)
                    try cache.beginClosingForRevocation()
                    do {
                        try await cache.waitForAuthoringToFinish()
                        try await CompanionDocumentOutboxes.shared.prepareForRevocation(pairingId: pairing.id, vaultIds: removed)
                        try await preserveMutationOutboxes(pairingId: pairing.id, vaultIds: removed, cache: cache)
                        try await cache.freezeForRevocation(true)
                        let authoringScope = refreshed.vaultIds.union(removed)
                        let snapshot = try await cache.authoringRecoverySnapshot(vaultIds: authoringScope)
                        let retired = snapshot.records.filter { $0.vaultId.map(removed.contains) ?? false }
                        if !retired.isEmpty {
                            let archivePairing = try refreshed.authoringArchiveScope(authoringScope)
                            let selected = snapshot.selectingVaults(removed)
                            let receipt = try await PrivateBridgeAuthoringRecovery.shared.preserve(snapshot: selected, pairing: archivePairing, macDeviceId: trustedMac, forceReview: true)
                            try await cache.retireArchivedVaultRecords(retired, receipt: receipt)
                            try await PrivateBridgeAuthoringRecovery.shared.completeRevocation(receipt)
                        }
                        try await cache.purgeReadingCopies(vaultIds: removed)
                        refreshed = try store.completeAuthoringRetirement(pairingId: pairing.id, retiredVaultIds: removed)
                        try await cache.freezeForRevocation(false)
                        await CompanionDocumentOutboxes.shared.forget(pairingId: pairing.id, vaultIds: removed)
                        await DesktopJobLedgers.shared.forget(pairingId: pairing.id, vaultIds: removed)
                    } catch {
                        if !store.isAuthorizationRevoked(pairingId: pairing.id) { try? await cache.freezeForRevocation(false) }
                        await CompanionDocumentOutboxes.shared.forget(pairingId: pairing.id, vaultIds: removed)
                        throw error
                    }
                }
                for old in linked where !refreshed.vaultIds.contains(old.vaultId ?? "") {
                    try ChatHistoryStore.shared(spaceId: old.storageId).revokeLink(); forget(old)
                }
                let currentCache = try PrivateBridgeCache(pairingId: pairing.id)
                try await currentCache.reopenAuthorizedVaultScopes(refreshed.vaultIds)
                _ = try await PrivateBridgeAuthoringRecovery.shared.adopt(pairing: refreshed, macDeviceId: trustedMac, cache: currentCache)
                guard let currentToken = store.credential(for: refreshed) else { throw DesktopBridgeError.locked }
                guard connectingDesktopGrants.isEmpty else { continue }
                try registerDesktopVaults(pairing: refreshed, token: currentToken, capabilities: capabilities)
                if let session, session.connection.desktopPairingId == pairing.id,
                   !refreshed.vaultIds.contains(session.vaultId ?? "") { self.session = nil }
            } catch DesktopBridgeError.credentialRevoked {
                await handleDesktopAuthorizationRevocation(pairingId: pairing.id)
            } catch {
                desktopRecoveryIssue = error.localizedDescription
                if let current = store.pairings().first(where: { $0.id == pairing.id }) {
                    for old in connections.filter({ $0.desktopPairingId == pairing.id && !current.vaultIds.contains($0.vaultId ?? "") }) { forget(old) }
                }
            }
        }
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
