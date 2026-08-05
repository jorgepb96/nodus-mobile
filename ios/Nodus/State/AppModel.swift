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
    struct Connection: Codable, Identifiable, Hashable {
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

        var id: String { "\(origin)|\(spaceId)" }
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
    var isConnecting = false

    private let keychain = KeychainStore()
    private static let defaultsKey = "nodus.connections.v1"
    private let cacheDirectory: URL

    init() {
        cacheDirectory = URL.cachesDirectory.appendingPathComponent("nodus-http", isDirectory: true)
        connections = Self.loadConnections(key: Self.defaultsKey)
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
        storedConnections().filter { !$0.isDemo }
    }

    var hasAnyConnection: Bool { !connections.isEmpty }

    var mostRecent: Connection? {
        connections.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    // MARK: - Connecting

    /// Step one: reach a server and ask what it supports, before asking the user for anything.
    func probe(_ input: String) async throws -> (ServerAddress, ServerCapabilities) {
        let address = try ServerAddress(validating: input)
        // `nodusProbe`, not the default session: the default waits for connectivity, and while
        // it waits it ignores request timeouts — so an address with nothing behind it left the
        // screen saying "looking for the server" indefinitely instead of saying there was
        // nothing there.
        let client = NodusClient(
            address: address,
            session: .nodusProbe,
            cache: ResponseCache(directory: cacheDirectory)
        )
        let capabilities = try await client.capabilities(timeout: 12)
        guard capabilities.supportsAnyKnownSnapshotVersion else {
            throw TransportError.malformedResponse(
                expected: "a snapshot format this app reads (\(SnapshotFormat.supportedVersions.sorted()))"
            )
        }
        return (address, capabilities)
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
        let updated = { var copy = connection; copy.lastOpenedAt = Date(); return copy }()
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[index] = updated
            persist()
        }
        session = SpaceSession(
            connection: updated,
            token: token,
            cacheDirectory: cacheDirectory,
            onUnauthorized: { [weak self, updated] in await self?.handleRevocation(of: updated) }
        )
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
