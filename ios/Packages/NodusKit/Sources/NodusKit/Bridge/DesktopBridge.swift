import CryptoKit
import Foundation
import Security

public enum DesktopBridgeDomain: String, Sendable, Hashable, Codable, CaseIterable {
    case corpus
    case writing
    case researchGeneration = "research-generation"
    case testimonies
    case teachingRoster = "teaching-roster"
    case teachingGrades = "teaching-grades"
    case studyRecordings = "study-recordings"
    case primarySourceFiles = "primary-source-files"
    case prosopographyPrivate = "prosopography-private"
}

public struct DesktopBridgePairing: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let origin: String
    /// Addresses authenticated by the original QR/code. Optional for existing links.
    public let wholeWorkspace: Bool?
    public let macDeviceId: String?
    /// Former authorized scopes retained only to locate and archive authored work.
    public let retainedAuthoringVaultIds: Set<String>?
    public let alternateOrigins: [String]?
    /// SHA-256 of the exact leaf certificate accepted during explicit pairing.
    public let certificateFingerprint: String
    public let deviceId: String
    public let deviceName: String
    public let vaultIds: Set<String>
    public let domains: Set<DesktopBridgeDomain>
    public let pairedAt: Date
    public let expiresAt: Date?

    public init(
        id: String,
        origin: String,
        certificateFingerprint: String,
        deviceId: String,
        deviceName: String,
        vaultIds: Set<String>,
        domains: Set<DesktopBridgeDomain>,
        pairedAt: Date,
        expiresAt: Date?,
        alternateOrigins: [String] = [],
        wholeWorkspace: Bool? = nil,
        macDeviceId: String? = nil,
        retainedAuthoringVaultIds: Set<String>? = nil
    ) throws {
        try Self.validateOrigin(origin)
        for alternative in alternateOrigins { try Self.validateOrigin(alternative) }
        let fingerprint = Self.normalizedFingerprint(certificateFingerprint)
        guard fingerprint.count == 64, fingerprint.allSatisfy(\.isHexDigit) else {
            throw DesktopBridgeError.invalidFingerprint
        }
        self.id = id
        self.wholeWorkspace = wholeWorkspace
        self.macDeviceId = macDeviceId
        self.retainedAuthoringVaultIds = retainedAuthoringVaultIds
        let normalizedOrigin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.origin = normalizedOrigin
        var seen: Set<String> = [normalizedOrigin]
        self.alternateOrigins = alternateOrigins.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { seen.insert($0).inserted }
        self.certificateFingerprint = fingerprint.lowercased()
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.vaultIds = vaultIds
        self.domains = domains
        self.pairedAt = pairedAt
        self.expiresAt = expiresAt
    }

    static func validateOrigin(_ origin: String) throws {
        guard
            let components = URLComponents(string: origin),
            components.scheme == "https",
            components.host != nil,
            components.user == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else { throw DesktopBridgeError.invalidOrigin }
    }

    public var isExpired: Bool { expiresAt.map { $0 <= Date() } ?? false }

    static func normalizedFingerprint(_ value: String) -> String {
        value.filter(\.isHexDigit)
    }
}

public struct DesktopBridgeCapabilitiesDocument: Sendable, Hashable, Decodable {
    public let protocolVersion: Int
    public let deviceId: String
    public let deviceName: String
    public let vaultIds: [String]
    public let domains: [DesktopBridgeDomain]
}

public struct DesktopBridgeRecordPage: Sendable, Hashable, Decodable {
    public let rows: [[String: JSONValue]]
    public let cursor: Int
    public let hasMore: Bool
}

public enum DesktopBridgeError: Error, Sendable, Equatable {
    case invalidOrigin
    case invalidFingerprint
    case permissionDenied
    case expired
    case certificateMismatch
    case malformedResponse
    case locked
    case credentialRevoked
}

extension DesktopBridgeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidOrigin: "The Desktop Bridge needs a direct HTTPS origin."
        case .invalidFingerprint: "The Desktop Bridge certificate fingerprint is invalid."
        case .permissionDenied: "This pairing does not grant access to that vault and private domain."
        case .expired: "The Desktop Bridge pairing has expired."
        case .certificateMismatch: "The Mac presented a different certificate. Pair it again before sending private data."
        case .malformedResponse: "The Desktop Bridge returned a response this app cannot read."
        case .credentialRevoked: "El Mac ha cerrado este enlace. Tu trabajo local se conservará antes de eliminar las copias consultadas."
        case .locked: "Private Bridge data is unavailable while this device is locked."
        }
    }
}

/// Direct private transport. It accepts only the leaf certificate fingerprint approved at
/// pairing and blocks redirects, so a DNS or captive-portal change cannot move a private
/// request to another host.
public actor DesktopBridgeClient {
    private let trustAnchor: DesktopBridgePairing
    private(set) var pairing: DesktopBridgePairing
    private var directOrigin: String
    private let session: URLSession
    private var token: String
    private let relay: DesktopRelayConfiguration?
    private let store: DesktopBridgePairingStore
    private var requiresStoredCredential: Bool

    /// Stored authorization is authoritative, but cannot replace the explicitly linked Mac.
    func refreshPairing() throws {
        guard !store.isAuthorizationRevoked(pairingId: trustAnchor.id) else { throw DesktopBridgeError.credentialRevoked }
        if let current = store.pairings().first(where: { $0.id == trustAnchor.id }) {
            requiresStoredCredential = true
            guard current.deviceId == trustAnchor.deviceId,
                  // Persisted ISO dates retain milliseconds, unlike a freshly created Date.
                  abs(current.pairedAt.timeIntervalSince(trustAnchor.pairedAt)) < 0.001,
                  current.certificateFingerprint == trustAnchor.certificateFingerprint,
                  current.wholeWorkspace != true || trustAnchor.wholeWorkspace == true,
                  trustAnchor.macDeviceId == nil || current.macDeviceId == trustAnchor.macDeviceId else {
                throw DesktopBridgeError.permissionDenied
            }
            let approvedOrigins = [current.origin] + (current.alternateOrigins ?? [])
            for origin in approvedOrigins { try DesktopBridgePairing.validateOrigin(origin) }
            if !approvedOrigins.contains(directOrigin) { directOrigin = current.origin }
            pairing = current
        } else if requiresStoredCredential {
            throw DesktopBridgeError.permissionDenied
        }
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        if let currentToken = store.credential(for: pairing) { token = currentToken }
        else if requiresStoredCredential { throw DesktopBridgeError.locked }
    }

    func validateCompanionScope(vaultId: String, domains: Set<DesktopBridgeDomain>) throws {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), domains.isSubset(of: pairing.domains) else { throw DesktopBridgeError.permissionDenied }
        if requiresStoredCredential {
            guard store.pairings().contains(where: { $0.id == pairing.id }) else { throw DesktopBridgeError.permissionDenied }
            guard store.credential(for: pairing) != nil else { throw DesktopBridgeError.locked }
        }
    }

    public init(pairing: DesktopBridgePairing, token: String, keychain: KeychainStore = KeychainStore()) {
        self.trustAnchor = pairing
        self.pairing = pairing
        self.directOrigin = pairing.origin
        self.token = token
        let store = DesktopBridgePairingStore(keychain: keychain)
        self.store = store
        self.requiresStoredCredential = store.pairings().contains { $0.id == pairing.id }
        self.relay = nil // Companion beta connects directly over LAN or VPN.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        let delegate = DesktopBridgeSessionDelegate(fingerprint: pairing.certificateFingerprint)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    init(pairing: DesktopBridgePairing, token: String, store: DesktopBridgePairingStore, session: URLSession) {
        self.trustAnchor = pairing; self.pairing = pairing; self.directOrigin = pairing.origin; self.token = token
        self.store = store; self.requiresStoredCredential = store.pairings().contains { $0.id == pairing.id }
        self.relay = store.relay(for: pairing); self.session = session
    }

    /// Completes an offer shown by Desktop. The fingerprint travels out-of-band with the code
    /// and pins the very first request; pairing is never a "trust on first use" connection.
    public static func pair(
        origin: String,
        certificateFingerprint: String,
        code: String,
        deviceId: String,
        deviceName: String,
        relay: DesktopRelayConfiguration? = nil,
        alternateOrigins: [String] = [],
        renewal: (pairing: DesktopBridgePairing, token: String, nextToken: String)? = nil
    ) async throws -> (pairing: DesktopBridgePairing, token: String) {
        let provisional = try DesktopBridgePairing(
            id: "pending",
            origin: origin,
            certificateFingerprint: certificateFingerprint,
            deviceId: deviceId,
            deviceName: deviceName,
            vaultIds: [],
            domains: [],
            pairedAt: Date(),
            expiresAt: nil,
            alternateOrigins: alternateOrigins
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = DesktopBridgeSessionDelegate(fingerprint: provisional.certificateFingerprint)
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: provisional.origin + "/bridge/v1/pair") else {
            throw DesktopBridgeError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let renewal { request.setValue("Bearer \(renewal.token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder.nodus.encode(PairingRequest(
            code: code,
            deviceId: deviceId,
            deviceName: deviceName,
            nextToken: renewal?.nextToken
        ))
        do {
            let (data, response) = try await Self.perform(request, session: session, relay: relay, alternateOrigins: alternateOrigins)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
                throw DesktopBridgeError.permissionDenied
            }
            let envelope = try JSONDecoder.nodus.decode(PairingEnvelope.self, from: data)
            if let renewal {
                guard envelope.token == renewal.nextToken, envelope.pairing.id == renewal.pairing.id,
                      envelope.pairing.deviceId == renewal.pairing.deviceId,
                      envelope.pairing.wholeWorkspace == renewal.pairing.wholeWorkspace,
                      renewal.pairing.wholeWorkspace == true || Set(envelope.pairing.vaultIds) == renewal.pairing.vaultIds,
                      Set(envelope.pairing.domains) == renewal.pairing.domains else { throw DesktopBridgeError.malformedResponse }
            }
            if let configuration = envelope.relay {
                try DesktopBridgePairingStore().saveRelay(configuration, pairingId: envelope.pairing.id)
            }
            return (
                try DesktopBridgePairing(
                    id: envelope.pairing.id,
                    origin: response.url.flatMap(Self.origin(of:)) ?? provisional.origin,
                    certificateFingerprint: provisional.certificateFingerprint,
                    deviceId: envelope.pairing.deviceId,
                    deviceName: envelope.pairing.deviceName,
                    vaultIds: Set(envelope.pairing.vaultIds),
                    domains: Set(envelope.pairing.domains),
                    pairedAt: envelope.pairing.createdAt,
                    expiresAt: envelope.pairing.expiresAt,
                    alternateOrigins: [provisional.origin] + alternateOrigins, wholeWorkspace: envelope.pairing.wholeWorkspace, macDeviceId: renewal?.pairing.macDeviceId, retainedAuthoringVaultIds: renewal?.pairing.retainedAuthoringVaultIds
                ),
                envelope.token
            )
        } catch let error as URLError where error.code == .serverCertificateUntrusted || error.code == .secureConnectionFailed {
            throw DesktopBridgeError.certificateMismatch
        } catch is DecodingError {
            throw DesktopBridgeError.malformedResponse
        }
    }

    public static func pair(offer: DesktopPairingOffer, deviceId: String, deviceName: String) async throws -> (pairing: DesktopBridgePairing, token: String) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: configuration,
            delegate: DesktopBridgeSessionDelegate(fingerprint: offer.certificateFingerprint), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            return try await pair(offer: offer, deviceId: deviceId, deviceName: deviceName,
                store: DesktopBridgePairingStore(), session: session)
        } catch let error as URLError where error.code == .serverCertificateUntrusted || error.code == .secureConnectionFailed {
            throw DesktopBridgeError.certificateMismatch
        } catch is DecodingError {
            throw DesktopBridgeError.malformedResponse
        }
    }

    static func mayUseRelay(after error: URLError, method: String) -> Bool {
        let beforeSend: Set<URLError.Code> = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet]
        if beforeSend.contains(error.code) { return true }
        return ["GET", "HEAD"].contains(method) && [.timedOut, .networkConnectionLost].contains(error.code)
    }

    static func origin(of url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.path = ""; components.query = nil; components.fragment = nil
        return components.string
    }

    static func perform(_ request: URLRequest, session: URLSession, relay: DesktopRelayConfiguration?, alternateOrigins: [String] = []) async throws -> (Data, URLResponse) {
        var candidate = request
        var remaining = alternateOrigins.filter { $0 != request.url.flatMap(origin(of:)) }
        while true {
            do { return try await session.data(for: candidate) }
            catch let error as URLError {
                guard mayUseRelay(after: error, method: request.httpMethod ?? "GET") else { throw error }
                if !remaining.isEmpty {
                    let next = remaining.removeFirst(); try DesktopBridgePairing.validateOrigin(next)
                    guard let url = request.url, let original = URLComponents(url: url, resolvingAgainstBaseURL: false),
                          var target = URLComponents(string: next) else { throw DesktopBridgeError.invalidOrigin }
                    target.percentEncodedPath = original.percentEncodedPath; target.percentEncodedQuery = original.percentEncodedQuery
                    guard let address = target.url else { throw DesktopBridgeError.invalidOrigin }
                    candidate.url = address
                    continue
                }
                guard let relay, let url = candidate.url,
                      let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw error }
            let path = components.percentEncodedPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            let result = try await DesktopRelayTransport.request(configuration: relay, path: path,
                method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody)
            guard let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers) else { throw DesktopBridgeError.malformedResponse }
            return (result.data, response)
            }
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try refreshPairing()
        guard let url = request.url, var target = URLComponents(string: directOrigin),
              let original = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw DesktopBridgeError.invalidOrigin }
        target.percentEncodedPath = original.percentEncodedPath; target.percentEncodedQuery = original.percentEncodedQuery
        var current = request; current.url = target.url
        if requiresStoredCredential, !store.pairings().contains(where: { $0.id == pairing.id }) { throw DesktopBridgeError.permissionDenied }
        if let stored = store.credential(for: pairing) { token = stored }
        else if requiresStoredCredential { throw DesktopBridgeError.locked }
        current.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        var sentToken = token
        let alternatives = [pairing.origin] + (pairing.alternateOrigins ?? [])
        var result = try await Self.perform(current, session: session, relay: relay, alternateOrigins: alternatives)
        if (result.1 as? HTTPURLResponse)?.statusCode == 401 {
            // A 401 precedes execution on the Mac, so retrying this exact request cannot
            // duplicate a write. Network failures of an ambiguous write are never retried.
            if let pending = store.pendingRenewal(for: pairing), pending != sentToken {
                var health = URLRequest(url: URL(string: directOrigin + "/bridge/v2/health")!)
                health.setValue("Bearer \(pending)", forHTTPHeaderField: "Authorization")
                let probe = try await Self.perform(health, session: session, relay: relay, alternateOrigins: alternatives)
                if (probe.1 as? HTTPURLResponse)?.statusCode == 200 { try store.commitRenewal(for: pairing, token: pending) }
            }
            if let fresh = store.credential(for: pairing), fresh != sentToken,
               store.pairings().contains(where: { $0.id == pairing.id }) {
                token = fresh; sentToken = fresh; current.setValue("Bearer \(fresh)", forHTTPHeaderField: "Authorization")
                result = try await Self.perform(current, session: session, relay: relay, alternateOrigins: alternatives)
            }
        }
        if (result.1 as? HTTPURLResponse)?.statusCode == 401,
           (try? JSONDecoder.nodus.decode(JSONValue.self, from: result.0).objectValue?["error"]) == .string("invalid_token"),
           requiresStoredCredential, store.markAuthorizationRevoked(pairingId: pairing.id, rejectedToken: sentToken) {
            try? store.offlineCache(for: pairing).beginClosingForRevocation()
            NotificationCenter.default.post(name: DesktopBridgePairingStore.authorizationRevokedNotification, object: pairing.id)
            throw DesktopBridgeError.credentialRevoked
        }
        if let effective = result.1.url.flatMap(Self.origin(of:)) { directOrigin = effective }
        return result
    }

    public func capabilities() async throws -> DesktopBridgeCapabilitiesDocument {
        try refreshPairing()
        return try await request("/bridge/v1/capabilities", as: DesktopBridgeCapabilitiesDocument.self)
    }

    public func liveCapabilities() async throws -> DesktopLiveCapabilities {
        try refreshPairing()
        return try await request("/bridge/v2/capabilities", as: DesktopLiveCapabilities.self)
    }

    public func revoke() async throws {
        try refreshPairing()
        _ = try await raw(path: "/bridge/v2/pairing", method: "DELETE")
    }
    public func renew() async throws -> String {
        try refreshPairing()
        let candidate = try store.prepareRenewal(for: pairing)
        let response = try await raw(path: "/bridge/v2/pairing/renew", method: "POST", body: .object(["nextToken": .string(candidate)]))
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data)
        guard response.status == 200, value.objectValue?["id"]?.stringValue == pairing.id else { throw DesktopBridgeError.malformedResponse }
        try store.commitRenewal(for: pairing, token: candidate)
        token = candidate
        return candidate
    }
    public func controlPlane(_ path: String) async throws -> DesktopBridgeResponse {
        try refreshPairing()
        guard ["health", "server-capabilities"].contains(path) else { throw DesktopBridgeError.permissionDenied }
        return try await raw(path: "/bridge/v2/\(path)", method: "GET")
    }
    public func sendMutations(vaultId: String, body: Data) async throws -> DesktopBridgeResponse {
        try refreshPairing()
        guard pairing.vaultIds.contains(vaultId), pairing.domains.contains(.writing), !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: body)
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.invalidOrigin }
        return try await raw(path: "/bridge/v2/vaults/\(vault)/corpus/mutations", method: "POST", body: value)
    }

    private func chatHistoryPath(vaultId: String,kind: CompanionChatKind,id: String? = nil,writing: Bool = false) throws -> String {
        try refreshPairing()
        guard !pairing.isExpired,pairing.vaultIds.contains(vaultId),pairing.domains.contains(.corpus),!writing || pairing.domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters:allowed) else { throw DesktopBridgeError.invalidOrigin }
        var path = "/bridge/v2/vaults/\(vault)/chat-history/\(kind.rawValue)"
        if let id {
            guard !id.isEmpty,id.utf8.count <= 256,let encoded = id.addingPercentEncoding(withAllowedCharacters:allowed) else { throw DesktopBridgeError.malformedResponse }
            path += "/\(encoded)"
        }
        return path
    }
    public func chatHistoryPage(vaultId: String,kind: CompanionChatKind,cursor: Int = 0,revision: String? = nil) async throws -> CompanionChatPage {
        try refreshPairing()
        guard cursor >= 0 else { throw DesktopBridgeError.malformedResponse }
        var query = [URLQueryItem(name:"cursor",value:String(cursor))]
        if let revision { query.append(URLQueryItem(name:"revision",value:revision)) }
        let response = try await raw(path:chatHistoryPath(vaultId:vaultId,kind:kind),query:query,method:"GET",timeout:8)
        let page = try JSONDecoder.nodus.decode(CompanionChatPage.self,from:response.data)
        guard page.version == 1,page.kind == kind,page.revision.count == 64,page.rows.count <= 100,
              page.cursor == cursor + page.rows.count,!page.hasMore || page.cursor > cursor,
              revision == nil || revision == page.revision,
              page.rows.allSatisfy({ $0.objectValue?["id"]?.stringValue != nil && $0.objectValue?["title"]?.stringValue != nil }) else { throw DesktopBridgeError.malformedResponse }
        return page
    }
    public func chatDocument(vaultId: String,kind: CompanionChatKind,id: String) async throws -> CompanionChatDocument {
        try refreshPairing()
        let response = try await raw(path:chatHistoryPath(vaultId:vaultId,kind:kind,id:id),method:"GET",timeout:12)
        guard response.data.count <= 20 * 1024 * 1024 else { throw DesktopBridgeError.malformedResponse }
        let document = try JSONDecoder.nodus.decode(CompanionChatDocument.self,from:response.data)
        try document.validate(kind:kind,id:id)
        return document
    }
    public func saveChatEdit(vaultId: String,kind: CompanionChatKind,request: JSONValue) async throws -> JSONValue {
        try refreshPairing()
        guard try JSONEncoder.nodus.encode(request).count <= 20 * 1024 * 1024 else { throw PrivateBridgeCache.ReadPackError.tooLarge }
        let response = try await raw(path:chatHistoryPath(vaultId:vaultId,kind:kind,writing:true),method:"POST",body:request)
        return try JSONDecoder.nodus.decode(JSONValue.self,from:response.data)
    }

    public func saveWorkspaceEdit(vaultId: String, request: CompanionDocumentOutbox.Request, kind: CompanionDocumentOutbox.Kind = .workspaceNote) async throws -> JSONValue {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.invalidOrigin }
        var body: [String: JSONValue] = [
            "id": .string(request.id), (kind == .workspaceNote ? "noteId" : "documentId"): .string(request.noteId), "input": request.input
        ]
        if kind == .studyDocument, !pairing.domains.contains(.corpus) { throw DesktopBridgeError.permissionDenied }
        if let creation = request.creation { body["creation"] = creation }
        if let command = request.command {
            guard pairing.domains.contains(.corpus), kind == .studyDocument || ["annotationCreate", "annotationUpdate", "annotationDelete", "duplicate", "trash", "workspaceOrganization"].contains(command.objectValue?["action"]?.stringValue ?? "") else { throw DesktopBridgeError.permissionDenied }
            if command.objectValue?["action"] == .string("workspaceOrganization"), kind != .workspaceNote { throw DesktopBridgeError.permissionDenied }
            body["command"] = command
        }
        guard try JSONEncoder.nodus.encode(JSONValue.object(body)).count <= CompanionDocumentOutbox.maximumRequestBytes else {
            throw APIError(status: 413, code: "workspace_edit_too_large", message: "La nota y sus archivos superan el tamaño permitido para sincronizar.")
        }
        let response = try await raw(path: "/bridge/v2/vaults/\(vault)/\(kind == .workspaceNote ? "workspace-edits" : "study-edits")", method: "POST", body: .object(body))
        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: response.data)
        if kind == .workspaceNote { return value }
        guard var object = value.objectValue, let document = object["document"], document.objectValue?["id"] == .string(request.noteId) else { throw DesktopBridgeError.malformedResponse }
        // The durable editor queue has one acknowledgement shape. Keep the wire
        // identity typed while adapting its canonical record for that queue.
        object["note"] = document
        return .object(object)
    }

    public func savePageDocument(vaultId: String, request: CompanionPageDocuments.Request) async throws -> JSONValue {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus), pairing.domains.contains(.writing) else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.invalidOrigin }
        let body = JSONValue.object(["id": .string(request.id), "input": request.input])
        guard try JSONEncoder.nodus.encode(body).count <= CompanionPageDocuments.maximumRequestBytes else { throw DesktopBridgeError.malformedResponse }
        let response = try await raw(path: "/bridge/v2/vaults/\(vault)/page-edits", method: "POST", body: body)
        return try JSONDecoder.nodus.decode(JSONValue.self, from: response.data)
    }

    public func operation(vaultId: String, method: String, args: [JSONValue], timeout: TimeInterval? = nil) async throws -> JSONValue {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId) else { throw DesktopBridgeError.permissionDenied }
        if let timeout, !timeout.isFinite || timeout <= 0 || timeout > 120 { throw DesktopBridgeError.malformedResponse }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed), let url = URL(string: pairing.origin + "/bridge/v2/vaults/\(vault)/operations") else { throw DesktopBridgeError.invalidOrigin }
        var request = URLRequest(url: url)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.nodus.encode(JSONValue.object(["method": .string(method), "args": .array(args)]))
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw DesktopBridgeError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else { throw APIError.decode(status: http.statusCode, data: data, headers: http.allHeaderFields) }
        let envelope = try JSONDecoder.nodus.decode([String: JSONValue].self, from: data)
        guard let result = envelope["result"] else { throw DesktopBridgeError.malformedResponse }
        return result
    }

    func jobRequest(vaultId: String, id: String? = nil, query: [URLQueryItem] = [], method: String, body: JSONValue? = nil) async throws -> DesktopBridgeJobEnvelope {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId) else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed),
            id == nil || id!.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw DesktopBridgeError.permissionDenied }
        let response = try await raw(path: "/bridge/v2/vaults/\(vault)/jobs" + (id.map { "/\($0)" } ?? ""), query: query, method: method, body: body)
        return try JSONDecoder.nodus.decode(DesktopBridgeJobEnvelope.self, from: response.data)
    }
    public func listJobs(vaultId: String) async throws -> [DesktopBridgeJob] {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId) else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.invalidOrigin }
        let response = try await raw(path: "/bridge/v2/vaults/\(vault)/jobs", method: "GET")
        struct List: Decodable { let jobs: [DesktopBridgeJob] }
        return try JSONDecoder.nodus.decode(List.self, from: response.data).jobs
    }

    public func exportedFile(vaultId: String, id: String, sha256: String) async throws -> Data {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus), UUID(uuidString: id) != nil else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.invalidOrigin }
        let response = try await raw(path: "/bridge/v2/vaults/\(vault)/exports/\(id)", method: "GET")
        guard SHA256.hash(data: response.data).map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else { throw DesktopBridgeError.malformedResponse }
        return response.data
    }

    /// Native catalogues and readers retain the same protected, bounded copies
    /// as the shared surfaces. Only transport loss permits fallback; revoked
    /// grants, invalid certificates and server errors always remain errors.
    public func corpusWithOfflineCopy(vaultId: String, path: String = "", query: [URLQueryItem] = [], method: String = "GET", body: JSONValue? = nil, percentEncoded: Bool = false, cache suppliedCache: PrivateBridgeCache? = nil) async throws -> (response: DesktopBridgeResponse, fromCache: Bool) {
        try refreshPairing()
        if method == "POST", path == "context" {
            guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus), query.isEmpty,
                  let body, body.objectValue != nil else { throw DesktopBridgeError.permissionDenied }
            let cache = try suppliedCache ?? store.offlineCache(for: pairing)
            let hasSelected = try await CompanionSelectedContext.hasSource(cache: cache, vaultId: vaultId, domains: Array(pairing.domains))
            do {
                return (try await corpus(vaultId: vaultId, path: path, query: query, method: method, body: body,
                    percentEncoded: percentEncoded, timeout: hasSelected ? 4 : nil), false)
            } catch {
                guard hasSelected, let offline = error as? URLError,
                      [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(offline.code)
                else { throw error }
                try validateCompanionScope(vaultId: vaultId, domains: [.corpus])
                guard let selected = try await CompanionSelectedContext.downloaded(cache: cache, vaultId: vaultId, domains: Array(pairing.domains)) else { throw error }
                return (try selected.response(body: body), true)
            }
        }
        if method == "POST", path == "search/semantic" {
            guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
            let cache = try suppliedCache ?? store.offlineCache(for: pairing)
            let selected = try await CompanionSelectedContext.hasSource(cache: cache, vaultId: vaultId, domains: Array(pairing.domains))
            // A selected lexical copy is not a vector index. Fail the semantic
            // request promptly; the caller may then request its truthful lexical path.
            return (try await corpus(vaultId: vaultId, path: path, query: query, method: method, body: body,
                percentEncoded: percentEncoded, timeout: selected ? 4 : nil), false)
        }
        guard method == "GET" else { return (try await corpus(vaultId: vaultId, path: path, query: query, method: method, body: body, percentEncoded: percentEncoded), false) }
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
        let cache = try suppliedCache ?? store.offlineCache(for: pairing)
        var address = URLComponents(); address.path = try Self.corpusPath(vaultId: vaultId, path: path, percentEncoded: percentEncoded); address.queryItems = query.isEmpty ? nil : query
        let identity = "corpus-http:" + (address.string ?? "")
        let retained = try await cache.data(vaultId: vaultId, domain: .corpus, recordId: identity)
        let selectedIdeas = path.split(separator: "/").first == "ideas"
            ? try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: CompanionIdeaCopy.recordId) : false
        let localIdeas = path.split(separator: "/").first == "ideas"
            ? try await CompanionIdeaCopy.authored(cache: cache, vaultId: vaultId) : nil
        let collectionPath = path.split(separator: "/").first.map(String.init)
        let selectedCollection: Bool
        if let collectionPath, Collections[collectionPath] != nil {
            selectedCollection = try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus,
                recordId: CompanionCollectionCopy.recordId(path: collectionPath))
        } else { selectedCollection = false }
        let selectedResearch = ["deep-research", "assets"].contains(collectionPath ?? "")
            ? try await cache.hasDownloadedData(vaultId: vaultId, domain: .corpus, recordId: CompanionResearchCorpusCopy.recordId) : false
        do {
            let response = try await corpus(vaultId: vaultId, path: path, query: query, method: method, body: body, percentEncoded: percentEncoded, timeout: retained != nil || selectedIdeas || localIdeas != nil || selectedCollection || selectedResearch ? 4 : nil)
            if response.status == 200 { try await cache.store(JSONEncoder.nodus.encode(response), vaultId: vaultId, domain: .corpus, recordId: identity) }
            return (response, false)
        } catch {
            try validateCompanionScope(vaultId: vaultId, domains: [.corpus])
            // The Mac can legitimately return 404 before acknowledging a new
            // authored identity. Only that device's actual pending creation is
            // eligible; a deleted Mac record never falls back to an old download.
            let components = path.split(separator: "/").map { percentEncoded ? String($0).removingPercentEncoding ?? "" : String($0) }
            if let api = error as? APIError, api.isNotFound, components.count == 2, components[0] == "ideas", let localIdeas {
                let copy = try CompanionIdeaCopy(copies: [localIdeas])
                if copy.containsFullIdea(components[1]), let response = try copy.nativeResponse(path: path, query: query, percentEncoded: percentEncoded) { return (response, true) }
            }
            guard let offline = error as? URLError,
                  [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut].contains(offline.code) else { throw error }
            if selectedIdeas || localIdeas != nil, let copy = try await CompanionIdeaCopy.consultable(cache: cache, vaultId: vaultId),
               let response = try copy.nativeResponse(path: path, query: query, percentEncoded: percentEncoded) { return (response, true) }
            if selectedCollection, let collectionPath,
               let copy = try await CompanionCollectionCopy.downloaded(cache: cache, vaultId: vaultId, path: collectionPath),
               let response = try copy.nativeResponse(path: path, query: query, percentEncoded: percentEncoded) { return (response, true) }
            if selectedResearch, let copy = try await CompanionResearchCorpusCopy.downloaded(cache: cache, vaultId: vaultId),
               let response = try copy.nativeResponse(path: path, query: query, percentEncoded: percentEncoded) { return (response, true) }
            guard let bytes = retained else { throw error }
            return (try JSONDecoder.nodus.decode(DesktopBridgeResponse.self, from: bytes), true)
        }
    }

    public func corpus(vaultId: String, path: String = "", query: [URLQueryItem] = [], method: String = "GET", body: JSONValue? = nil, percentEncoded: Bool = false, timeout: TimeInterval? = nil) async throws -> DesktopBridgeResponse {
        try refreshPairing()
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        let readQuery = method == "POST" && ["search/semantic", "context"].contains(path)
        guard pairing.vaultIds.contains(vaultId), pairing.domains.contains(.corpus) else { throw DesktopBridgeError.permissionDenied }
        let actionWrite = method == "POST" && !readQuery
            ? try DesktopCompanionActions.validateWrite(path: path, query: query, body: body, domains: pairing.domains) : false
        guard ["GET", "HEAD"].contains(method) || readQuery || actionWrite else { throw DesktopBridgeError.permissionDenied }
        if readQuery {
            guard let body, body.objectValue != nil, try JSONEncoder.nodus.encode(body).count <= 256 * 1024 else { throw DesktopBridgeError.malformedResponse }
        } else if !actionWrite && body != nil { throw DesktopBridgeError.permissionDenied }
        return try await raw(path: Self.corpusPath(vaultId: vaultId, path: path, percentEncoded: percentEncoded), query: query, method: method, body: body, timeout: timeout)
    }

    func fileRequest(vaultId: String, kind: DesktopBridgeFileKind, id: String, action: String, query: [URLQueryItem] = [], timeout: TimeInterval? = nil) async throws -> DesktopBridgeResponse {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(kind.domain),
              !id.isEmpty, id != ".", id != "..", ["descriptor", "content"].contains(action) else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed),
              let record = id.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.invalidOrigin }
        return try await raw(path: "/bridge/v2/vaults/\(vault)/files/\(kind.rawValue)/\(record)/\(action)", query: query, method: "GET", timeout: timeout)
    }

    static func corpusPath(vaultId: String, path: String, percentEncoded: Bool) throws -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%?#"))
        let parts = try path.split(separator: "/").map { part in
            if !percentEncoded { return String(part) }
            guard let decoded = String(part).removingPercentEncoding else { throw DesktopBridgeError.invalidOrigin }
            return decoded
        }
        guard !parts.contains(where: { $0 == "." || $0 == ".." }), let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.permissionDenied }
        return "/bridge/v2/vaults/\(vault)/corpus/" + parts.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
    }

    private func raw(path: String, query: [URLQueryItem] = [], method: String, body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> DesktopBridgeResponse {
        try refreshPairing()
        guard var url = URLComponents(string: pairing.origin + path) else { throw DesktopBridgeError.invalidOrigin }
        url.queryItems = query.isEmpty ? nil : query
        guard let address = url.url else { throw DesktopBridgeError.invalidOrigin }
        var request = URLRequest(url: address)
        if let timeout { request.timeoutInterval = timeout }
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.nodus.encode(body)
        }
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw DesktopBridgeError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.decode(status: http.statusCode, data: data, headers: http.allHeaderFields)
        }
        return DesktopBridgeResponse(data: data, status: http.statusCode, headers: Dictionary(uniqueKeysWithValues: http.allHeaderFields.map { (String(describing: $0.key).lowercased(), String(describing: $0.value)) }))
    }

    private func immersionProgressPath(vaultId: String, sessionId: String) throws -> String {
        try refreshPairing()
        guard !pairing.isExpired, pairing.vaultIds.contains(vaultId), pairing.domains.contains(.writing), !sessionId.isEmpty else { throw DesktopBridgeError.permissionDenied }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters: allowed), let session = sessionId.addingPercentEncoding(withAllowedCharacters: allowed) else { throw DesktopBridgeError.malformedResponse }
        return "/bridge/v2/vaults/\(vault)/writing/immersion/\(session)/progress"
    }
    public func immersionProgress(vaultId: String, sessionId: String) async throws -> CompanionImmersionProgress.Snapshot {
        try refreshPairing()
        let response = try await raw(path: immersionProgressPath(vaultId: vaultId, sessionId: sessionId), method: "GET", timeout: 4)
        let value = try JSONDecoder.nodus.decode(CompanionImmersionProgress.Snapshot.self, from: response.data)
        try value.validate(sessionId: sessionId); return value
    }
    private func databaseReadingPath(vaultId:String,reportId:String) throws -> String {
        try refreshPairing()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        guard let vault = vaultId.addingPercentEncoding(withAllowedCharacters:allowed),let report = reportId.addingPercentEncoding(withAllowedCharacters:allowed) else { throw DesktopBridgeError.malformedResponse }
        return "/bridge/v2/vaults/\(vault)/writing/database-research/\(report)/reading"
    }
    public func databaseResearchReading(vaultId:String,reportId:String) async throws -> CompanionDatabaseResearch.Snapshot {
        try refreshPairing()
        let response = try await raw(path:databaseReadingPath(vaultId:vaultId,reportId:reportId),method:"GET",timeout:4)
        let value = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Snapshot.self,from:response.data)
        try value.validate(id:reportId); return value
    }
    public func saveDatabaseResearchReading(vaultId:String,reportId:String,request:CompanionDatabaseResearch.Request) async throws -> CompanionDatabaseResearch.Receipt {
        try refreshPairing()
        let body = try JSONDecoder.nodus.decode(JSONValue.self,from:JSONEncoder.nodus.encode(request))
        let response = try await raw(path:databaseReadingPath(vaultId:vaultId,reportId:reportId),method:"POST",body:body,timeout:10)
        let receipt = try JSONDecoder.nodus.decode(CompanionDatabaseResearch.Receipt.self,from:response.data)
        guard receipt.id == request.id else { throw DesktopBridgeError.malformedResponse }
        try receipt.snapshot.validate(id:reportId); return receipt
    }
    public func saveImmersionProgress(vaultId: String, sessionId: String, request: CompanionImmersionProgress.Request) async throws -> CompanionImmersionProgress.Receipt {
        try refreshPairing()
        let body = try JSONDecoder.nodus.decode(JSONValue.self, from: JSONEncoder.nodus.encode(request))
        let response = try await raw(path: immersionProgressPath(vaultId: vaultId, sessionId: sessionId), method: "POST", body: body, timeout: 10)
        let receipt = try JSONDecoder.nodus.decode(CompanionImmersionProgress.Receipt.self, from: response.data)
        guard receipt.id == request.id else { throw DesktopBridgeError.malformedResponse }
        try receipt.snapshot.validate(sessionId: sessionId); return receipt
    }
    public func privateSource(vaultId: String, reference: PrivateCorpusReference) async throws -> PrivateCorpusSource {
        try refreshPairing()
        try requirePrivateSourceGrant(vaultId: vaultId, reference: reference)
        let response = try await raw(path: reference.path(vaultId: vaultId), method: "GET", timeout: 4)
        let source = try JSONDecoder.nodus.decode(PrivateCorpusSource.self, from: response.data)
        try source.validate(for: reference)
        return source
    }

    public func privateSourceCatalogue(vaultId: String, kind: PrivateCorpusReference.Kind, offset: Int = 0, query: String = "", state: String = "active") async throws -> PrivateCorpusSource.Catalogue {
        try refreshPairing()
        let target = try PrivateCorpusReference(kind: kind, id: "catalogue")
        try requirePrivateSourceGrant(vaultId: vaultId, reference: target)
        guard offset >= 0 else { throw DesktopBridgeError.malformedResponse }
        let address = try target.path(vaultId: vaultId)
        let response = try await raw(path: String(address.dropLast("/catalogue".count)), query: [
            URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "state", value: state),
        ], method: "GET", timeout: 4)
        let page = try JSONDecoder.nodus.decode(PrivateCorpusSource.Catalogue.self, from: response.data)
        try page.validate(offset: offset)
        return page
    }

    public func privateSourcePage(vaultId: String, reference: PrivateCorpusReference,
        group: PrivateCorpusSource.Group, cursor: Int = 0) async throws -> PrivateCorpusSource.Page {
        try refreshPairing()
        try requirePrivateSourceGrant(vaultId: vaultId, reference: reference)
        guard reference.kind.groups.contains(group.key), cursor >= 0 else { throw DesktopBridgeError.permissionDenied }
        let response = try await raw(path: reference.path(vaultId: vaultId), query: [
            URLQueryItem(name: "group", value: group.key), URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "revision", value: group.revision),
        ], method: "GET", timeout: 10)
        let page = try JSONDecoder.nodus.decode(PrivateCorpusSource.Page.self, from: response.data)
        guard page.revision == group.revision, page.total == group.total, page.rows.count <= 100, page.cursor >= cursor,
              !page.hasMore || (!page.rows.isEmpty && page.cursor > cursor) else { throw DesktopBridgeError.malformedResponse }
        return page
    }

    private func requirePrivateSourceGrant(vaultId: String, reference: PrivateCorpusReference) throws {
        try refreshPairing()
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        guard pairing.vaultIds.contains(vaultId), pairing.domains.contains(reference.kind.domain) else { throw DesktopBridgeError.permissionDenied }
    }

    public func privateJSON<T: Decodable & Sendable>(
        vaultId: String,
        domain: DesktopBridgeDomain,
        path: String,
        as type: T.Type = T.self
    ) async throws -> T {
        try refreshPairing()
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        guard pairing.vaultIds.contains(vaultId), pairing.domains.contains(domain) else {
            throw DesktopBridgeError.permissionDenied
        }
        let segments = path.split(separator: "/").map(String.init)
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else {
            throw DesktopBridgeError.permissionDenied
        }
        let encodedVault = vaultId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? vaultId
        let encodedPath = segments.map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }.joined(separator: "/")
        return try await request("/bridge/v1/vaults/\(encodedVault)/\(domain.rawValue)/\(encodedPath)", as: type)
    }

    public func records(
        vaultId: String,
        domain: DesktopBridgeDomain,
        table: String,
        cursor: Int = 0,
        limit: Int = 50
    ) async throws -> DesktopBridgeRecordPage {
        try refreshPairing()
        guard !pairing.isExpired else { throw DesktopBridgeError.expired }
        guard pairing.vaultIds.contains(vaultId), pairing.domains.contains(domain) else {
            throw DesktopBridgeError.permissionDenied
        }
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            throw DesktopBridgeError.permissionDenied
        }
        let encodedVault = vaultId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? vaultId
        guard var components = URLComponents(string: pairing.origin + "/bridge/v1/vaults/\(encodedVault)/\(domain.rawValue)/records") else {
            throw DesktopBridgeError.invalidOrigin
        }
        components.queryItems = [
            URLQueryItem(name: "table", value: table),
            URLQueryItem(name: "cursor", value: String(max(0, cursor))),
            URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
        ]
        guard let url = components.url else { throw DesktopBridgeError.invalidOrigin }
        return try await request(url, as: DesktopBridgeRecordPage.self)
    }

    private func request<T: Decodable & Sendable>(_ path: String, as type: T.Type) async throws -> T {
        try refreshPairing()
        guard let url = URL(string: pairing.origin + path) else { throw DesktopBridgeError.invalidOrigin }
        return try await request(url, as: type)
    }

    private func request<T: Decodable & Sendable>(_ url: URL, as type: T.Type) async throws -> T {
        try refreshPairing()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await perform(request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DesktopBridgeError.permissionDenied
            }
            guard let value = try? JSONDecoder.nodus.decode(type, from: data) else {
                throw DesktopBridgeError.malformedResponse
            }
            return value
        } catch let error as URLError where error.code == .serverCertificateUntrusted || error.code == .secureConnectionFailed {
            throw DesktopBridgeError.certificateMismatch
        }
    }
}

public struct DesktopBridgeResponse: Sendable, Codable {
    public let data: Data
    public let status: Int
    public let headers: [String: String]
}

public struct DesktopLiveCapabilities: Decodable, Sendable {
    public struct Vault: Decodable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let type: VaultType
    }
    public let protocolVersion: Int
    public let deviceId: String
    public let deviceName: String
    public let vaults: [Vault]
    public let operations: [String]
    public let wholeWorkspace: Bool?
    public let domains: [DesktopBridgeDomain]?
}

struct PairingRequest: Encodable {
    let code: String
    let deviceId: String
    let deviceName: String
    let nextToken: String?
}

struct PairingEnvelope: Decodable {
    struct RawPairing: Decodable {
        let id: String
        let deviceId: String
        let deviceName: String
        let vaultIds: [String]
        let domains: [DesktopBridgeDomain]
        let createdAt: Date
        let expiresAt: Date?
        let wholeWorkspace: Bool?
    }
    let token: String
    let relay: DesktopRelayConfiguration?
    let pairing: RawPairing
}

/// Public pairing metadata stays in preferences; tokens and relay keys stay in Keychain.
/// Revoking locally deletes it synchronously, so the app cannot issue another request even if
/// the Mac is currently unreachable and has not yet recorded its own revocation.
public struct DesktopBridgePairingStore: @unchecked Sendable {
    func offlineCache(for pairing: DesktopBridgePairing) throws -> PrivateBridgeCache {
        try PrivateBridgeCache(pairingId: pairing.id, directory: cacheDirectory, keychain: keychain)
    }

    private static let renewalLock = NSLock()
    private static let pendingLock = NSLock()
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let cacheDirectory: URL
    private let metadataKey = "desktop-bridge-pairings-v1"
    private let pendingKey = "desktop-bridge-pending-offer-ids-v1"
    private let pendingIndexKey = "desktop-bridge-pending-index-v1"

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore(), cacheDirectory: URL = PrivateBridgeCache.defaultDirectory) {
        self.defaults = defaults
        self.keychain = keychain
        self.cacheDirectory = cacheDirectory
    }

    public static let authorizationRevokedNotification = Notification.Name("NodusDesktopBridgeAuthorizationRevoked")
    private var revokedAuthorizationKey: String { metadataKey + ".revokedAuthorizations" }
    public func isAuthorizationRevoked(pairingId: String) -> Bool { (defaults.stringArray(forKey: revokedAuthorizationKey) ?? []).contains(pairingId) }
    @discardableResult
    public func markAuthorizationRevoked(pairingId: String, rejectedToken: String? = nil) -> Bool {
        Self.renewalLock.withLock {
            if let rejectedToken, keychain.value(for: KeychainStore.desktopBridgeKey(pairingId: pairingId)) != rejectedToken { return false }
            defaults.set(Array(Set((defaults.stringArray(forKey: revokedAuthorizationKey) ?? []) + [pairingId])), forKey: revokedAuthorizationKey)
            return true
        }
    }
    public func pairings(includeRevoked: Bool = false) -> [DesktopBridgePairing] {
        guard let data = defaults.data(forKey: metadataKey) else { return [] }
        let all = (try? JSONDecoder.nodus.decode([DesktopBridgePairing].self, from: data)) ?? []
        return includeRevoked ? all : all.filter { !isAuthorizationRevoked(pairingId: $0.id) }
    }

    public func save(_ pairing: DesktopBridgePairing, token: String) throws {
        try Self.renewalLock.withLock {
            guard !isAuthorizationRevoked(pairingId: pairing.id) else { throw DesktopBridgeError.credentialRevoked }
            var values = pairings(includeRevoked: true).filter { $0.id != pairing.id }
            values.append(pairing)
            try keychain.set(token, for: KeychainStore.desktopBridgeKey(pairingId: pairing.id))
            defaults.set(try JSONEncoder.nodus.encode(values), forKey: metadataKey)
        }
    }
    /// A capabilities request can overlap token renewal. Replace only metadata,
    /// deriving scope from the freshest grant without writing the captured token.
    public func updateWorkspaceMetadata(_ capabilities: DesktopLiveCapabilities, expectedPairing: DesktopBridgePairing, trustedMacDeviceId: String) throws -> DesktopBridgePairing {
        try Self.renewalLock.withLock {
            guard !isAuthorizationRevoked(pairingId: expectedPairing.id),
                  let current = pairings().first(where: { $0.id == expectedPairing.id }),
                  current.deviceId == expectedPairing.deviceId,
                  current.certificateFingerprint == expectedPairing.certificateFingerprint,
                  abs(current.pairedAt.timeIntervalSince(expectedPairing.pairedAt)) < 0.001 else { throw DesktopBridgeError.permissionDenied }
            let refreshed = try current.refreshedWorkspace(capabilities, trustedMacDeviceId: trustedMacDeviceId)
            let values = pairings(includeRevoked: true).map { $0.id == current.id ? refreshed : $0 }
            defaults.set(try JSONEncoder.nodus.encode(values), forKey: metadataKey)
            return refreshed
        }
    }
    public func completeAuthoringRetirement(pairingId: String, retiredVaultIds: Set<String>) throws -> DesktopBridgePairing {
        try Self.renewalLock.withLock {
            guard !isAuthorizationRevoked(pairingId: pairingId), let current = pairings().first(where: { $0.id == pairingId }) else { throw DesktopBridgeError.credentialRevoked }
            let updated = try current.authoringArchiveScope(current.vaultIds, retained: (current.retainedAuthoringVaultIds ?? []).subtracting(retiredVaultIds))
            defaults.set(try JSONEncoder.nodus.encode(pairings(includeRevoked: true).map { $0.id == pairingId ? updated : $0 }), forKey: metadataKey)
            return updated
        }
    }

    public func credential(for pairing: DesktopBridgePairing) -> String? {
        keychain.value(for: KeychainStore.desktopBridgeKey(pairingId: pairing.id))
    }

    /// Only opaque offer IDs enter preferences. The code, authenticated offer and
    /// candidate credential stay together in the non-synchronizing Keychain.
    public func pendingOffers() -> [DesktopPairingOffer] {
        Self.pendingLock.withLock {
            ((try? pendingPairingIDs()) ?? []).reversed().compactMap {
                pendingPairing(id: $0)?.offer
            }
        }
    }

    /// A stored credential proves the POST succeeded, not that the previous grant's
    /// work was retired and recovered. Foreground discovery must not finish this step.
    public func hasPendingWorkspaceRegistration(grantId: String) throws -> Bool {
        try Self.pendingLock.withLock {
            var pendingRegistration = false
            for id in try pendingPairingIDs() {
                guard let pending = pendingPairing(id: id) else { throw DesktopBridgeError.locked }
                if (pending.offer.renewalPairingId ?? pending.offer.id) == grantId { pendingRegistration = true }
            }
            return pendingRegistration
        }
    }

    func pendingPairingToken(offerId: String) -> String? {
        Self.pendingLock.withLock { pendingPairing(id: offerId)?.token }
    }

    private func pendingPairing(id: String) -> DesktopPendingPairing? {
        guard let text = keychain.value(for: KeychainStore.desktopBridgePendingKey(offerId: id)),
              let data = Data(base64Encoded: text) else { return nil }
        return try? JSONDecoder.nodus.decode(DesktopPendingPairing.self, from: data)
    }

    private func pendingPairingIDs() throws -> [String] {
        if let text = keychain.value(for: pendingIndexKey) {
            guard let data = Data(base64Encoded: text),
                  let ids = try? JSONDecoder().decode([String].self, from: data) else { throw DesktopBridgeError.malformedResponse }
            return ids
        }
        if keychain.contains(pendingIndexKey) { throw DesktopBridgeError.locked }
        return defaults.stringArray(forKey: pendingKey) ?? []
    }

    private func savePendingPairingIDs(_ ids: [String]) throws {
        // The durable index commits before any pairing POST, independently of
        // asynchronous preferences writes or a restored preferences file.
        if ids.isEmpty { try keychain.remove(pendingIndexKey); defaults.removeObject(forKey: pendingKey) }
        else {
            try keychain.set(try JSONEncoder().encode(ids).base64EncodedString(), for: pendingIndexKey)
            defaults.set(ids, forKey: pendingKey)
        }
    }

    func preparePendingPairing(offer: DesktopPairingOffer, deviceId: String, deviceName: String,
                               token: String) throws -> DesktopPendingPairing {
        try Self.pendingLock.withLock {
            var ids = try pendingPairingIDs()
            if ids.contains(offer.id) {
                guard let pending = pendingPairing(id: offer.id) else { throw DesktopBridgeError.locked }
                guard pending.deviceId == deviceId,
                      pending.offer.certificateFingerprint == offer.certificateFingerprint,
                      pending.offer.macDeviceId == offer.macDeviceId,
                      pending.offer.renewalPairingId == offer.renewalPairingId,
                      pending.offer.wholeWorkspace == offer.wholeWorkspace,
                      Set(pending.offer.origins) == Set(offer.origins),
                      Set(pending.offer.vaultIds) == Set(offer.vaultIds),
                      Set(pending.offer.domains) == Set(offer.domains) else { throw DesktopBridgeError.permissionDenied }
                return pending
            }
            guard offer.expiresAt > Date() else { throw DesktopBridgeError.expired }
            let pending = DesktopPendingPairing(offer: offer, deviceId: deviceId, deviceName: deviceName, token: token)
            try keychain.set(try JSONEncoder.nodus.encode(pending).base64EncodedString(),
                for: KeychainStore.desktopBridgePendingKey(offerId: offer.id))
            ids.append(offer.id); try savePendingPairingIDs(ids)
            return pending
        }
    }

    func updatePendingPairing(_ pending: DesktopPendingPairing, token: String) throws {
        try Self.pendingLock.withLock {
            guard pendingPairing(id: pending.offer.id)?.token == pending.token else { throw DesktopBridgeError.permissionDenied }
            let updated = DesktopPendingPairing(offer: pending.offer, deviceId: pending.deviceId,
                deviceName: pending.deviceName, token: token)
            try keychain.set(try JSONEncoder.nodus.encode(updated).base64EncodedString(),
                for: KeychainStore.desktopBridgePendingKey(offerId: pending.offer.id))
        }
    }

    /// Called after the complete workspace is saved, or when its owner unlinks it.
    public func completePendingPairing(grantId: String) throws {
        try Self.pendingLock.withLock {
            let ids = try pendingPairingIDs()
            var retained = [String]()
            for id in ids {
                guard let pending = pendingPairing(id: id) else { retained.append(id); continue }
                if (pending.offer.renewalPairingId ?? id) == grantId {
                    try keychain.remove(KeychainStore.desktopBridgePendingKey(offerId: id))
                } else { retained.append(id) }
            }
            try savePendingPairingIDs(retained)
        }
    }

    /// Store the replacement before contacting the Mac. If its response is lost,
    /// a pinned health request can prove which credential the Mac committed.
    public func prepareRenewal(for pairing: DesktopBridgePairing) throws -> String {
        try Self.renewalLock.withLock {
            guard pairings().contains(where: { $0.id == pairing.id }), credential(for: pairing) != nil,
                  !pairing.isExpired else { throw DesktopBridgeError.permissionDenied }
            if let pending = pendingRenewal(for: pairing) { return pending }
            var bytes = [UInt8](repeating: 0, count: 32)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard status == errSecSuccess else { throw KeychainStore.Failure.unexpectedStatus(status) }
            let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            try keychain.set(token, for: KeychainStore.desktopBridgeRenewalKey(pairingId: pairing.id))
            return token
        }
    }

    public func pendingRenewal(for pairing: DesktopBridgePairing) -> String? {
        keychain.value(for: KeychainStore.desktopBridgeRenewalKey(pairingId: pairing.id))
    }

    public func commitRenewal(for pairing: DesktopBridgePairing, token: String) throws {
        try Self.renewalLock.withLock {
            guard pairings().contains(where: { $0.id == pairing.id }) else { throw DesktopBridgeError.permissionDenied }
            guard pendingRenewal(for: pairing) == token else {
                if credential(for: pairing) == token { return }
                throw DesktopBridgeError.permissionDenied
            }
            try keychain.set(token, for: KeychainStore.desktopBridgeKey(pairingId: pairing.id))
            try keychain.remove(KeychainStore.desktopBridgeRenewalKey(pairingId: pairing.id))
        }
    }

    public func saveRelay(_ relay: DesktopRelayConfiguration, pairingId: String) throws {
        try relay.validate()
        guard relay.expiresAt > Date() else { throw DesktopBridgeError.expired }
        try keychain.set(try JSONEncoder.nodus.encode(relay).base64EncodedString(), for: KeychainStore.desktopBridgeRelayKey(pairingId: pairingId))
    }

    public func relay(for pairing: DesktopBridgePairing) -> DesktopRelayConfiguration? {
        guard let encoded = keychain.value(for: KeychainStore.desktopBridgeRelayKey(pairingId: pairing.id)),
              let data = Data(base64Encoded: encoded), let configuration = try? JSONDecoder.nodus.decode(DesktopRelayConfiguration.self, from: data),
              (try? configuration.validate()) != nil, configuration.expiresAt > Date() else { return nil }
        return configuration
    }

    public func revokeLocally(_ pairing: DesktopBridgePairing, authoringRecovery: PrivateBridgeAuthoringRecovery.Receipt? = nil, cacheDirectory: URL = PrivateBridgeCache.defaultDirectory) throws {
        let folder = cacheDirectory.appendingPathComponent("bridge-\(pairing.id)", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            let protected = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .contains { $0.pathExtension == "bridgecache" && !$0.lastPathComponent.hasPrefix("read-") }
            if protected {
                guard let authoringRecovery, authoringRecovery.completeAuthoringInventory,
                      try authoringRecovery.validates(pairingId: pairing.id, folder: folder),
                      keychain.value(for: authoringRecovery.recoveryKeyName) != nil else { throw PrivateBridgeAuthoringRecovery.RecoveryError.recoveryRequired }
            }
        }
        try completePendingPairing(grantId: pairing.id)
        Self.renewalLock.lock()
        defer { Self.renewalLock.unlock() }
        try keychain.remove(KeychainStore.desktopBridgeKey(pairingId: pairing.id))
        try keychain.remove(KeychainStore.desktopBridgeRenewalKey(pairingId: pairing.id))
        try keychain.remove(KeychainStore.desktopBridgeRelayKey(pairingId: pairing.id))
        try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing.id))
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        defaults.set(
            try JSONEncoder.nodus.encode(pairings(includeRevoked: true).filter { $0.id != pairing.id }),
            forKey: metadataKey
        )
        defaults.set((defaults.stringArray(forKey: revokedAuthorizationKey) ?? []).filter { $0 != pairing.id }, forKey: revokedAuthorizationKey)
    }
}

final class DesktopBridgeSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let fingerprint: String

    init(fingerprint: String) { self.fingerprint = DesktopBridgePairing.normalizedFingerprint(fingerprint).lowercased() }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust,
            let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let actual = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }.joined()
        completionHandler(actual == fingerprint ? .useCredential : .cancelAuthenticationChallenge,
                          actual == fingerprint ? URLCredential(trust: trust) : nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Opaque private cache encrypted independently of iOS file protection. The AES key lives in
/// the non-synchronizing, when-unlocked Keychain; the files use `.complete`, so neither layer
/// is readable from a locked device.
/// Encrypted copies of consulted content share a bounded LRU budget per Mac.
/// Drafts and accepted jobs are durable work and never participate in eviction.
public actor PrivateBridgeCache {
    public static let defaultReadLimitBytes = 250 * 1_024 * 1_024
    public static let maximumSelectedCopyBytes = 50 * 1_024 * 1_024
    public struct Usage: Sendable, Equatable {
        public let reusableBytes: Int
        public let downloadedBytes: Int
        public let protectedBytes: Int
        public let readLimitBytes: Int
    }
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NodusPrivateBridge", isDirectory: true)
    }

    // Several surfaces construct cache actors for the same pairing. Serialize disk
    // accounting and key creation across them, including reads that update the LRU.
    private static let diskLock = NSLock()
    nonisolated(unsafe) private static var authoringActivities: [String: Int] = [:]
    private let folder: URL
    private let key: SymmetricKey
    private let readLimitBytes: Int
    private var initialScopeEpochs: [String: String] = [:]
    private struct VaultScope: Codable { let epoch: String; let closed: Bool }
    private func scopeKey(_ vault: String) -> String { PrivateBridgeAuthoringRecovery.hash(Data(vault.utf8)) }
    private func scopeURL(_ vault: String) -> URL { folder.appendingPathComponent("scope-" + scopeKey(vault) + ".metadata") }
    private func requireVaultScope(_ vault: String) throws {
        let url = scopeURL(vault)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let state = try JSONDecoder.nodus.decode(VaultScope.self, from: Data(contentsOf: url))
        guard !state.closed, (initialScopeEpochs[scopeKey(vault)] ?? "initial") == state.epoch else { throw DesktopBridgeError.permissionDenied }
    }
    private func readScopeURL(_ file: URL) -> URL { file.appendingPathExtension("scope") }
    private func recordReadScope(_ file: URL, vault: String) throws {
        try PrivateBridgeProtectedFile.write(Data(scopeKey(vault).utf8), to: readScopeURL(file))
    }

    public init(pairingId: String, directory: URL, keychain: KeychainStore = KeychainStore(), readLimitBytes: Int = PrivateBridgeCache.defaultReadLimitBytes) throws {
        folder = directory.appendingPathComponent("bridge-\(pairingId)", isDirectory: true)
        self.readLimitBytes = max(0, readLimitBytes)
        let cacheFolder = folder
        key = try Self.diskLock.withLock {
            try FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
#if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: cacheFolder.path)
#endif
            BackupPolicy.apply(.excluded, to: cacheFolder)
            let keyName = KeychainStore.desktopBridgeCacheKey(pairingId: pairingId)
            if let encoded = keychain.value(for: keyName), let data = Data(base64Encoded: encoded), data.count == 32 {
                return SymmetricKey(data: data)
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw DesktopBridgeError.locked }
            let data = Data(bytes)
            try keychain.set(data.base64EncodedString(), for: keyName)
            return SymmetricKey(data: data)
        }
        initialScopeEpochs = try Self.diskLock.withLock {
            try Self.recoverIndexedTransactions(in: cacheFolder)
            var epochs: [String: String] = [:]
            for url in try FileManager.default.contentsOfDirectory(at: cacheFolder, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix("scope-") && url.pathExtension == "metadata" {
                let state = try JSONDecoder.nodus.decode(VaultScope.self, from: Data(contentsOf: url))
                epochs[String(url.deletingPathExtension().lastPathComponent.dropFirst(6))] = state.epoch
            }
            return epochs
        }
    }

    public init(pairingId: String, keychain: KeychainStore = KeychainStore()) throws {
        try self.init(pairingId: pairingId, directory: Self.defaultDirectory, keychain: keychain)
    }

    /// False means an oversized reusable copy was deliberately not retained. The
    /// caller can still display the online response. Durable work always persists.
    @discardableResult
    public func store(_ data: Data, vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws -> Bool {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw DesktopBridgeError.malformedResponse }
        return try Self.diskLock.withLock {
            try Self.recoverIndexedTransactions(in: folder)
            if Self.isDurable(domain) { try requireWritable() } else { try requireReadingAllowed() }
            try requireVaultScope(vaultId)
            try cleanReadPacks()
            let url = fileURL(vaultId: vaultId, domain: domain, recordId: recordId)
            let legacy = legacyURL(vaultId: vaultId, domain: domain, recordId: recordId)
            if !Self.isDurable(domain), combined.count > max(0, readLimitBytes - (try readPackBytes())) {
                try removeIfPresent(url); try removeIfPresent(legacy)
                return false
            }
            try PrivateBridgeProtectedFile.write(combined, to: url)
            BackupPolicy.apply(.excluded, to: url)
            if !Self.isDurable(domain) { try recordReadScope(url, vault: vaultId) }
            try removeIfPresent(legacy)
            try trimReusableCopies(keeping: url)
            return true
        }
    }

    public struct IndexedGenerationSummary: Sendable {
        public let recordId: String
        public let data: Data
        public init(recordId: String, data: Data) { self.recordId = recordId; self.data = data }
    }
    private struct IndexedTransaction: Codable { let files: [String: String] }
    private static func recoverIndexedTransactions(in folder: URL) throws {
        for directory in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where directory.lastPathComponent.hasPrefix("indexed-") && directory.pathExtension == "transaction" {
            guard UUID(uuidString: String(directory.deletingPathExtension().lastPathComponent.dropFirst(8))) != nil else { throw DesktopBridgeError.malformedResponse }
            let marker = directory.appendingPathComponent("commit.json")
            guard FileManager.default.fileExists(atPath: marker.path) else { try FileManager.default.removeItem(at: directory); continue }
            let transaction = try JSONDecoder.nodus.decode(IndexedTransaction.self, from: Data(contentsOf: marker))
            guard transaction.files.count >= 2, transaction.files.count <= 3,
                transaction.files.keys.allSatisfy({ PrivateBridgeAuthoringRecovery.validFilename($0) && $0.hasPrefix("work-") }) else { throw DesktopBridgeError.malformedResponse }
            // All staged ciphertext is verified before any destination is changed.
            for (name, hash) in transaction.files {
                guard PrivateBridgeAuthoringRecovery.hash(try Data(contentsOf: directory.appendingPathComponent(name))) == hash else { throw DesktopBridgeError.malformedResponse }
            }
            for name in transaction.files.keys.sorted() {
                try PrivateBridgeProtectedFile.write(Data(contentsOf: directory.appendingPathComponent(name)), to: folder.appendingPathComponent(name))
                BackupPolicy.apply(.excluded, to: folder.appendingPathComponent(name))
            }
            try FileManager.default.removeItem(at: directory)
        }
    }
    /// The commit marker makes checkpoint, index and optional summary recover as
    /// one durable generation, even if the process stops between file replacements.
    public func storeIndexedGeneration(_ data: Data,vaultId: String,recordId: String,indexId: String,entity: String,
        summary: IndexedGenerationSummary? = nil) throws {
        guard !entity.isEmpty,entity.utf8.count <= 256 else { throw DesktopBridgeError.malformedResponse }
        try Self.diskLock.withLock {
            try Self.recoverIndexedTransactions(in: folder)
            try requireWritable(); try requireVaultScope(vaultId)
            let indexURL = fileURL(vaultId:vaultId,domain:.researchGeneration,recordId:indexId)
            var entries: [String] = []
            if FileManager.default.fileExists(atPath:indexURL.path) {
                entries = try JSONDecoder.nodus.decode([String].self,from:AES.GCM.open(AES.GCM.SealedBox(combined:Data(contentsOf:indexURL)),using:key))
            }
            entries = Array(Set(entries + [entity])).sorted()
            guard entries.count <= 10_000 else { throw DesktopBridgeError.malformedResponse }
            var values = [(indexURL,try JSONEncoder.nodus.encode(entries)),(fileURL(vaultId:vaultId,domain:.researchGeneration,recordId:recordId),data)]
            if let summary {
                guard summary.recordId == "autonomous:deepResearch:summary:" + entity,
                      indexId == "autonomous:deepResearch:index:v1",
                      recordId == (try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)),
                      summary.data.count <= 256 * 1024 else { throw DesktopBridgeError.malformedResponse }
                values.append((fileURL(vaultId:vaultId,domain:.researchGeneration,recordId:summary.recordId),summary.data))
            }
            guard Set(values.map { $0.0.lastPathComponent }).count == values.count else { throw DesktopBridgeError.malformedResponse }
            let directory = folder.appendingPathComponent("indexed-" + UUID().uuidString + ".transaction", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            BackupPolicy.apply(.excluded, to: directory)
            var hashes: [String: String] = [:]
            do {
                for (url, bytes) in values {
                    guard let sealed = try AES.GCM.seal(bytes,using:key).combined else { throw DesktopBridgeError.malformedResponse }
                    try PrivateBridgeProtectedFile.write(sealed, to: directory.appendingPathComponent(url.lastPathComponent))
                    hashes[url.lastPathComponent] = PrivateBridgeAuthoringRecovery.hash(sealed)
                }
                try PrivateBridgeProtectedFile.write(JSONEncoder.nodus.encode(IndexedTransaction(files: hashes)), to: directory.appendingPathComponent("commit.json"))
            } catch { try? FileManager.default.removeItem(at: directory); throw error }
            try Self.recoverIndexedTransactions(in: folder)
        }
    }
    public func data(vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws -> Data? {
        try Self.diskLock.withLock {
            try Self.recoverIndexedTransactions(in: folder)
            if Self.isDurable(domain) { try requireWritable() } else { try requireReadingAllowed() }
            try requireVaultScope(vaultId)
            try cleanReadPacks()
            let url = fileURL(vaultId: vaultId, domain: domain, recordId: recordId)
            let legacy = legacyURL(vaultId: vaultId, domain: domain, recordId: recordId)
            let source = FileManager.default.fileExists(atPath: url.path) ? url : legacy
            guard FileManager.default.fileExists(atPath: source.path) else {
                let name = legacy.lastPathComponent
                for pack in try readPackManifests().sorted(by: { $0.createdAt > $1.createdAt }) where pack.vaultId == vaultId && pack.files.contains(name) {
                    let copy = folder.appendingPathComponent(pack.directory).appendingPathComponent(name)
                    return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: copy)), using: key)
                }
                return nil
            }
            if !Self.isDurable(domain), !FileManager.default.fileExists(atPath: readScopeURL(source).path),
               FileManager.default.fileExists(atPath: scopeURL(vaultId).path) {
                // Unclassified historical reads cannot survive a retired authorization epoch.
                try removeIfPresent(source); return nil
            }
            let value = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: source)), using: key)
            // Migrate only after decrypting and knowing the domain. Unclassified
            // legacy files may hold drafts and must never be blindly evicted.
            if source == legacy { try FileManager.default.moveItem(at: legacy, to: url) }
            if !Self.isDurable(domain) { try recordReadScope(url, vault: vaultId) }
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            try trimReusableCopies(keeping: url)
            return value
        }
    }

    public func remove(vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws {
        try Self.diskLock.withLock {
            try Self.recoverIndexedTransactions(in: folder)
            if Self.isDurable(domain) { try requireWritable() } else { try requireReadingAllowed() }
            try requireVaultScope(vaultId)
            try removeIfPresent(fileURL(vaultId: vaultId, domain: domain, recordId: recordId))
            try removeIfPresent(legacyURL(vaultId: vaultId, domain: domain, recordId: recordId))
        }
    }

    private nonisolated var closingMarker: URL { folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".closing") }
    private nonisolated var revocationMarker: URL { folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".revoked") }
    private nonisolated func requireWritable() throws {
        if FileManager.default.fileExists(atPath: revocationMarker.path) { throw PrivateBridgeAuthoringRecovery.RecoveryError.revokedWrites }
    }
    public nonisolated func beginAuthoringActivity() throws {
        try Self.diskLock.withLock {
            try requireWritable()
            guard !FileManager.default.fileExists(atPath: closingMarker.path) else { throw PrivateBridgeAuthoringRecovery.RecoveryError.revokedWrites }
            Self.authoringActivities[folder.path, default: 0] += 1
        }
    }
    public nonisolated func endAuthoringActivity() {
        Self.diskLock.withLock {
            let count = Self.authoringActivities[folder.path, default: 0]
            if count <= 1 { Self.authoringActivities[folder.path] = nil }
            else { Self.authoringActivities[folder.path] = count - 1 }
        }
    }
    public nonisolated func beginClosingForRevocation() throws {
        try Self.diskLock.withLock {
            try PrivateBridgeProtectedFile.write(Data(), to: closingMarker)
            BackupPolicy.apply(.excluded, to: closingMarker)
        }
    }
    public nonisolated static func waitForAuthoringToFinish(pairingId: String, directory: URL = PrivateBridgeCache.defaultDirectory) async throws {
        let path = directory.appendingPathComponent("bridge-" + pairingId).path
        while diskLock.withLock({ authoringActivities[path, default: 0] > 0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    public func waitForAuthoringToFinish() async throws {
        while Self.diskLock.withLock({ Self.authoringActivities[folder.path, default: 0] > 0 }) {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private nonisolated func requireReadingAllowed() throws {
        try requireWritable()
        guard !FileManager.default.fileExists(atPath: closingMarker.path) else { throw PrivateBridgeAuthoringRecovery.RecoveryError.revokedWrites }
    }
    public func freezeForRevocation(_ frozen: Bool) throws {
        try Self.diskLock.withLock {
            if frozen {
                guard Self.authoringActivities[folder.path, default: 0] == 0 else { throw PrivateBridgeAuthoringRecovery.RecoveryError.activeGeneration }
                try PrivateBridgeProtectedFile.write(Data(), to: revocationMarker); BackupPolicy.apply(.excluded, to: revocationMarker) }
            else { try removeIfPresent(revocationMarker); try removeIfPresent(closingMarker) }
        }
    }
    /// Reading copies are revocable independently of the encrypted authored backup.
    public func purgeReadingCopies(vaultIds: Set<String>? = nil) throws {
        try Self.diskLock.withLock {
            for vault in vaultIds ?? [] {
                let url = scopeURL(vault)
                let old = try? JSONDecoder.nodus.decode(VaultScope.self, from: Data(contentsOf: url))
                if old?.closed != true {
                    try PrivateBridgeProtectedFile.write(try JSONEncoder.nodus.encode(VaultScope(epoch: UUID().uuidString, closed: true)), to: url)
                }
            }
            let scopeKeys = vaultIds.map { Set($0.map(scopeKey)) }
            for file in try cacheFiles() where file.url.lastPathComponent.hasPrefix("read-") {
                let recorded = try? String(contentsOf: readScopeURL(file.url), encoding: .utf8)
                if scopeKeys == nil || recorded.map({ scopeKeys!.contains($0) }) == true {
                    try removeIfPresent(file.url); try removeIfPresent(readScopeURL(file.url))
                }
            }
            for pack in try readPackManifests() where vaultIds == nil || vaultIds!.contains(pack.vaultId) { try removeIfPresent(readPackPointer(pack.id)) }
            try cleanReadPacks()
        }
    }
    /// Remove only exact archived authored records for scopes no longer authorized.
    public func retireArchivedVaultRecords(_ records: [PrivateBridgeAuthoringRecovery.Record], receipt: PrivateBridgeAuthoringRecovery.Receipt) throws {
        try Self.diskLock.withLock {
            let pairingId = String(folder.lastPathComponent.dropFirst("bridge-".count))
            guard Set(records.map(\.filename)).isSubset(of: receipt.archivedFilenames), try receipt.validates(pairingId: pairingId, folder: folder) else { throw PrivateBridgeAuthoringRecovery.RecoveryError.recoveryRequired }
            for vault in Set(records.compactMap(\.vaultId)) {
                try PrivateBridgeProtectedFile.write(try JSONEncoder.nodus.encode(VaultScope(epoch: UUID().uuidString, closed: true)), to: scopeURL(vault))
            }
            for record in records where record.vaultId != nil {
                guard PrivateBridgeAuthoringRecovery.validFilename(record.filename) else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
                try removeIfPresent(folder.appendingPathComponent(record.filename))
                try removeIfPresent(folder.appendingPathComponent(String(record.filename.dropFirst(5))))
            }
        }
    }
    public func authoringRecoverySnapshot(vaultIds: Set<String>) throws -> PrivateBridgeAuthoringRecovery.Snapshot {
        try Self.diskLock.withLock {
            try Self.recoverIndexedTransactions(in: folder)
            let writingIds = ["companion-documents-v1", "companion-study-documents-v1", "companion-page-documents-v1", "companion-immersion-progress-v1", "companion-database-reading-v1"]
            let researchIds = ["job-ledger-v1", "authoring-recovery-generations-v1", "autonomous:completion-index:v1", "autonomous:academic:index:v1", "autonomous:database:index:v1", "autonomous:deepResearch:index:v1", "companion:world-map-generation-index:v1"]
            var known: [String: (vault: String, writing: Bool, ledger: Bool, recordId: String, kind: String?)] = [:]
            for vault in vaultIds {
                for id in writingIds { known[legacyURL(vaultId: vault, domain: .writing, recordId: id).lastPathComponent] = (vault, true, false, id, nil) }
                for id in researchIds { known[legacyURL(vaultId: vault, domain: .researchGeneration, recordId: id).lastPathComponent] = (vault, false, id == "job-ledger-v1", id, nil) }
            }
            for vault in vaultIds {
                let url = fileURL(vaultId: vault, domain: .researchGeneration, recordId: "autonomous:completion-index:v1")
                if FileManager.default.fileExists(atPath: url.path) {
                    let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
                    for record in try JSONDecoder.nodus.decode([String].self, from: bytes) {
                        guard record.hasPrefix("autonomous:"), record.contains(":completion:") else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
                        known[legacyURL(vaultId: vault, domain: .researchGeneration, recordId: record).lastPathComponent] = (vault, false, false, record, nil)
                    }
                }
            }
            for vault in vaultIds {
                let index = fileURL(vaultId: vault, domain: .researchGeneration, recordId: "autonomous:deepResearch:index:v1")
                if FileManager.default.fileExists(atPath: index.path) {
                    let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: index)), using: key)
                    for entity in try JSONDecoder.nodus.decode([String].self, from: bytes) {
                        let checkpoint = try CompanionGenerationPublication.recordId(kind: "deepResearch", entity: entity)
                        guard FileManager.default.fileExists(atPath: fileURL(vaultId: vault, domain: .researchGeneration, recordId: checkpoint).path) else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
                        let summary = "autonomous:deepResearch:summary:" + entity
                        known[legacyURL(vaultId: vault, domain: .researchGeneration, recordId: summary).lastPathComponent] = (vault, false, false, summary, "deepResearchSummary")
                    }
                }
            }
            var records: [PrivateBridgeAuthoringRecovery.Record] = [], fingerprints: [String: String] = [:]
            for file in try cacheFiles() where !file.url.lastPathComponent.hasPrefix("read-") {
                let original = file.url.lastPathComponent
                let base = original.hasPrefix("work-") ? String(original.dropFirst(5)) : original
                let encrypted = try Data(contentsOf: file.url)
                fingerprints[original] = PrivateBridgeAuthoringRecovery.hash(encrypted)
                let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key)
                let value = try JSONDecoder.nodus.decode(JSONValue.self, from: data)
                var scope = known[base]
                if scope == nil, let object = value.objectValue, let request = object["request"]?.objectValue,
                   let id = object["id"]?.stringValue, UUID(uuidString: id) != nil {
                    for vault in vaultIds {
                        if let revision = object["revision"]?.stringValue, let model = object["model"], request["mapId"]?.stringValue != nil {
                            let hash = PrivateBridgeAuthoringRecovery.hash(try JSONEncoder.nodus.encode(JSONValue.array([.object(request), .string(revision), model])))
                            let record = "companion:world-map-generation:v1:" + hash
                            if legacyURL(vaultId: vault, domain: .researchGeneration, recordId: record).lastPathComponent == base { scope = (vault, false, false, record, "worldMap") }
                        }
                        for kind in ["dictionary", "immersion", "translation", "writing", "argument", "workshop", "database", "academic", "deepResearch"] {
                            let entity = kind == "dictionary" ? request["entryId"]?.stringValue : object["entityKey"]?.stringValue
                            if let entity, let record = try? CompanionGenerationPublication.recordId(kind: kind, entity: entity),
                               legacyURL(vaultId: vault, domain: .researchGeneration, recordId: record).lastPathComponent == base {
                                scope = (vault, false, false, record, kind)
                            }
                        }
                    }
                }
                // The native WK localStorage shim predates typed outboxes. Classify only
                // its exact vault/domain/key; unknown keys may contain complete editorial
                // drafts and remain exportable, without being seeded into a new grant.
                if scope == nil, let vault = vaultIds.first(where: {
                    legacyURL(vaultId: $0, domain: .writing, recordId: "surface-storage:v1").lastPathComponent == base
                }) {
                    guard let entries = value.objectValue else { throw PrivateBridgeAuthoringRecovery.RecoveryError.unclassifiedWork }
                    let retained = entries.filter { key, value in
                        guard let text = value.stringValue else { return true }
                        if key == "nodus.argumentMap.autoFocus" { return text != "true" && text != "false" }
                        if key == "nodus.graph.detailFontSize" || key == "nodus.graph.detailWidth" {
                            return Double(text).map { !$0.isFinite } ?? true
                        }
                        return true
                    }
                    if !retained.isEmpty {
                        records.append(.init(filename: "work-" + base, vaultId: vault,
                            data: try JSONEncoder.nodus.encode(JSONValue.object(retained)), ledger: false, writing: true,
                            recordId: "surface-storage:v1", generationKind: "legacySurfaceStorage"))
                    }
                    continue
                }
                // Standalone source preparation is a consulted copy, not authored work.
                if scope == nil, let object = value.objectValue, object["source"] != nil, object["id"] == nil, object["request"] == nil { continue }
                // Completed autonomous provider calls are stored as literal strings; preserve
                // their exact hashed key, requiring the full original vault scope for adoption.
                if scope == nil, original.hasPrefix("work-"), value.stringValue != nil {
                    records.append(.init(filename: "work-" + base, vaultId: nil, data: data, ledger: false, writing: false, recordId: nil, generationKind: nil)); continue
                }
                guard let scope else { throw PrivateBridgeAuthoringRecovery.RecoveryError.unclassifiedWork }
                if let capturedVault = value.objectValue?["vaultId"]?.stringValue, capturedVault != scope.vault { throw PrivateBridgeAuthoringRecovery.RecoveryError.unclassifiedWork }
                var authoredData = data
                if scope.writing, var fields = value.objectValue {
                    fields["workspaceOrganizationSnapshot"] = nil
                    authoredData = try JSONEncoder.nodus.encode(JSONValue.object(fields))
                }
                records.append(.init(filename: "work-" + base, vaultId: scope.vault, data: authoredData, ledger: scope.ledger, writing: scope.writing, recordId: scope.recordId, generationKind: scope.kind))
            }
            return .init(records: records, fingerprints: fingerprints)
        }
    }
    public func adoptAuthoringRecovery(_ records: [PrivateBridgeAuthoringRecovery.Record], requiresReview: Bool) throws {
        let records = records.filter { $0.generationKind != "legacySurfaceStorage" }
        try Self.diskLock.withLock {
            var payloads: [String: Data] = [:]
            var mergedRecoveryIndices = Set<String>()
            for record in records {
                guard PrivateBridgeAuthoringRecovery.validFilename(record.filename) else { throw PrivateBridgeAuthoringRecovery.RecoveryError.invalidArchive }
                payloads[record.filename] = requiresReview ? try PrivateBridgeAuthoringRecovery.reviewed(record) : record.data
            }
            // A crash can save a paid result before its publication ledger. Reconstruct only
            // a provider-free save/review entry, never the paid generation itself.
            for record in records {
                guard let vault = record.vaultId, let recovered = try PrivateBridgeAuthoringRecovery.recoveredRequest(record, requiresReview: requiresReview) else { continue }
                let name = fileURL(vaultId: vault, domain: .researchGeneration, recordId: "job-ledger-v1").lastPathComponent
                var ledger: [String: DesktopJobLedger.Request] = [:]
                if let data = payloads[name] { ledger = try JSONDecoder.nodus.decode([String: DesktopJobLedger.Request].self, from: data) }
                else if FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                    ledger = try JSONDecoder.nodus.decode([String: DesktopJobLedger.Request].self, from: AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: folder.appendingPathComponent(name))), using: key))
                }
                if ledger[recovered.id] == nil { ledger[recovered.id] = recovered }
                else if var existing = ledger[recovered.id], existing.state == "recoveryReview",
                        existing.checkpoint == nil, existing.method == recovered.method,
                        existing.args == recovered.args {
                    // A normal map save prepares its exact args before a checkpoint is
                    // attached. Join that durable output without replacing receipts/IDs.
                    existing.checkpoint = recovered.checkpoint
                    existing.checkpointRecordId = recovered.checkpointRecordId
                    ledger[existing.id] = existing
                }
                payloads[name] = try JSONEncoder.nodus.encode(ledger)
            }
            if requiresReview {
                for vault in Set(records.compactMap(\.vaultId)) {
                    var ids = Set<String>()
                    for record in records where record.vaultId == vault {
                        let value = try JSONDecoder.nodus.decode(JSONValue.self, from: record.data)
                        if let id = value.objectValue?["id"]?.stringValue { ids.insert(id) }
                        if record.ledger { for row in value.objectValue?.values ?? Dictionary<String, JSONValue>().values {
                            if let id = row.objectValue?["checkpoint"]?.objectValue?["id"]?.stringValue { ids.insert(id) }
                        } }
                    }
                    let name = fileURL(vaultId: vault, domain: .researchGeneration, recordId: "authoring-recovery-generations-v1").lastPathComponent
                    if let imported = payloads[name] { ids.formUnion(try JSONDecoder.nodus.decode([String].self, from: imported)) }
                    mergedRecoveryIndices.insert(name)
                    if let bytes = try? Data(contentsOf: folder.appendingPathComponent(name)), let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key) {
                        ids.formUnion(try JSONDecoder.nodus.decode([String].self, from: opened))
                    }
                    payloads[name] = try JSONEncoder.nodus.encode(ids.sorted())
                }
            }
            // Check every destination before writing: existing newer work is never overwritten.
            var staged: [(URL, Data)] = []
            for (name, data) in payloads {
                let target = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: target.path) {
                    let current = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: target)), using: key)
                    if current != data {
                        guard mergedRecoveryIndices.contains(name), let encrypted = try AES.GCM.seal(data, using: key).combined else { throw PrivateBridgeAuthoringRecovery.RecoveryError.recoveryRequired }
                        staged.append((target, encrypted))
                    }
                } else {
                    guard let encrypted = try AES.GCM.seal(data, using: key).combined else { throw DesktopBridgeError.malformedResponse }
                    staged.append((target, encrypted))
                }
            }
            for (target, data) in staged { try PrivateBridgeProtectedFile.write(data, to: target); BackupPolicy.apply(.excluded, to: target) }
            for vault in Set(records.compactMap(\.vaultId)) {
                let url = scopeURL(vault)
                if FileManager.default.fileExists(atPath: url.path) {
                    let state = try JSONDecoder.nodus.decode(VaultScope.self, from: Data(contentsOf: url))
                    try PrivateBridgeProtectedFile.write(try JSONEncoder.nodus.encode(VaultScope(epoch: state.epoch, closed: false)), to: url)
                }
            }
            try removeIfPresent(revocationMarker)
            try removeIfPresent(closingMarker)
        }
    }

    /// Called only with the freshly authenticated grant's current vault identifiers.
    public func reopenAuthorizedVaultScopes(_ vaultIds: Set<String>) throws {
        try Self.diskLock.withLock {
            try requireWritable()
            for vault in vaultIds {
                let url = scopeURL(vault)
                if FileManager.default.fileExists(atPath: url.path) {
                    let old = try JSONDecoder.nodus.decode(VaultScope.self, from: Data(contentsOf: url))
                    try PrivateBridgeProtectedFile.write(try JSONEncoder.nodus.encode(VaultScope(epoch: old.epoch, closed: false)), to: url)
                }
            }
        }
    }

    /// A recovered intent may consult an already durable paid response, but cannot pay again.
    public func requireGenerationExecutionAllowed(vaultId: String, generationId: String) throws {
        if let bytes = try data(vaultId: vaultId, domain: .researchGeneration, recordId: "authoring-recovery-generations-v1"),
           try JSONDecoder.nodus.decode([String].self, from: bytes).contains(generationId) {
            throw PrivateBridgeAuthoringRecovery.RecoveryError.recoveryRequired
        }
    }

    public func usage() throws -> Usage {
        try Self.diskLock.withLock {
            try cleanReadPacks()
            let files = try cacheFiles()
            return Usage(reusableBytes: files.filter { $0.url.lastPathComponent.hasPrefix("read-") }.reduce(0) { $0 + $1.size },
                         downloadedBytes: try readPackBytes(),
                         protectedBytes: files.filter { !$0.url.lastPathComponent.hasPrefix("read-") }.reduce(0) { $0 + $1.size },
                         readLimitBytes: readLimitBytes)
        }
    }

    /// Frees consulted copies while keeping local drafts, work queues and all
    /// still-unclassified files left by older app versions.
    public func removeReusableCopies() throws {
        try Self.diskLock.withLock {
            for file in try cacheFiles() where file.url.lastPathComponent.hasPrefix("read-") { try removeIfPresent(file.url) }
        }
    }

    private static func isDurable(_ domain: DesktopBridgeDomain) -> Bool { domain == .writing || domain == .researchGeneration }

    /// The same chosen records refresh one download, independent of selection
    /// order. Each vault and different selection retain separate copies.
    public static func readPackSelectionId(vaultId: String, recordIds: [String]) throws -> UUID {
        guard !vaultId.isEmpty, !recordIds.isEmpty, recordIds.allSatisfy({ !$0.isEmpty }) else { throw ReadPackError.invalidSelection }
        let scope: JSONValue = .object(["vault": .string(vaultId), "records": .array(Set(recordIds).sorted().map(JSONValue.string))])
        var bytes = Array(SHA256.hash(data: try JSONEncoder.nodus.encode(scope)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUID v8, application-specific hash.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    private func cacheFiles() throws -> [(url: URL, size: Int, date: Date)] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            .filter { $0.pathExtension == "bridgecache" }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
            }
    }
    private func trimReusableCopies(keeping: URL) throws {
        let files = try cacheFiles().filter { $0.url.lastPathComponent.hasPrefix("read-") }.sorted {
            if $0.url == keeping { return false }
            if $1.url == keeping { return true }
            return $0.date < $1.date
        }
        var total = files.reduce(0) { $0 + $1.size }
        let available = max(0, readLimitBytes - (try readPackBytes()))
        for file in files where total > available {
            try removeIfPresent(file.url); try removeIfPresent(readScopeURL(file.url)); total -= file.size
        }
    }
    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    private func fileURL(vaultId: String, domain: DesktopBridgeDomain, recordId: String) -> URL {
        let legacy = legacyURL(vaultId: vaultId, domain: domain, recordId: recordId)
        return folder.appendingPathComponent((Self.isDurable(domain) ? "work-" : "read-") + legacy.lastPathComponent)
    }
    private func legacyURL(vaultId: String, domain: DesktopBridgeDomain, recordId: String) -> URL {
        let address = "\(vaultId)\u{1f}\(domain.rawValue)\u{1f}\(recordId)"
        let name = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name).appendingPathExtension("bridgecache")
    }

    public struct ReadPackRecord: Sendable {
        public let domain: DesktopBridgeDomain
        public let recordId: String
        public let data: Data
        public init(domain: DesktopBridgeDomain, recordId: String, data: Data) {
            self.domain = domain; self.recordId = recordId; self.data = data
        }
    }
    public struct ReadPack: Codable, Sendable, Identifiable {
        public let id: UUID
        public let vaultId: String
        public let title: String
        public let createdAt: Date
        public let expiresAt: Date
        public let bytes: Int
        public let recordCount: Int
        public let primaryFile: DesktopBridgeFileDescriptor?
        fileprivate let directory: String
        fileprivate let files: [String]
    }
    public enum ReadPackError: LocalizedError {
        case tooLarge, perDownloadLimit, invalidSelection
        public var errorDescription: String? {
            switch self {
            case .tooLarge: "La selección supera el espacio disponible para descargas. Selecciona menos documentos o elimina otra descarga."
            case .perDownloadLimit: "Cada descarga admite hasta 50 MB, incluidos sus archivos y metadatos. Selecciona menos contenidos o conserva los archivos por separado."
            case .invalidSelection: "La selección de descarga está incompleta o no es válida."
            }
        }
    }
    /// Commit the complete selection with one atomic encrypted pointer. A failed
    /// refresh retains the previous download; no partial pack is advertised.
    @discardableResult
    public func saveReadPack(id: UUID = UUID(), vaultId: String, title: String, expiresAt: Date, records: [ReadPackRecord], primaryFile: DesktopBridgeFileDescriptor? = nil) throws -> ReadPack {
        guard !vaultId.isEmpty, !title.isEmpty, expiresAt > Date(), !records.isEmpty,
              records.allSatisfy({ !Self.isDurable($0.domain) }) else { throw ReadPackError.invalidSelection }
        var payloadBytes = 0
        for record in records {
            guard record.data.count <= Self.maximumSelectedCopyBytes - payloadBytes else { throw ReadPackError.perDownloadLimit }
            payloadBytes += record.data.count
        }
        if let file = primaryFile {
            try file.validate()
            let record = "file:\(file.kind.rawValue):\(file.id)"
            guard let metadata = records.first(where: { $0.domain == file.kind.domain && $0.recordId == record }),
                  let content = records.first(where: { $0.domain == file.kind.domain && $0.recordId == "\(record):\(file.sha256)" }),
                  try JSONDecoder.nodus.decode(DesktopBridgeFileDescriptor.self, from: metadata.data) == file,
                  content.data.count == file.byteSize,
                  SHA256.hash(data: content.data).map({ String(format: "%02x", $0) }).joined() == file.sha256.lowercased() else { throw ReadPackError.invalidSelection }
        }
        return try Self.diskLock.withLock {
            try requireReadingAllowed()
            try requireVaultScope(vaultId)
            try cleanReadPacks()
            let existing = try readPackManifests()
            let otherBytes = existing.filter { $0.id != id }.reduce(0) { $0 + $1.bytes }
            let directory = "pack-copy-" + UUID().uuidString
            let staged = folder.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
            BackupPolicy.apply(.excluded, to: staged)
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: staged) } }
            var names = Set<String>(), bytes = 0
            for record in records {
                let name = legacyURL(vaultId: vaultId, domain: record.domain, recordId: record.recordId).lastPathComponent
                guard names.insert(name).inserted, let sealed = try AES.GCM.seal(record.data, using: key).combined else { throw ReadPackError.invalidSelection }
                bytes += sealed.count
                guard bytes <= Self.maximumSelectedCopyBytes else { throw ReadPackError.perDownloadLimit }
                guard bytes + otherBytes <= readLimitBytes else { throw ReadPackError.tooLarge }
                try PrivateBridgeProtectedFile.write(sealed, to: staged.appendingPathComponent(name))
            }
            // Include the encrypted pointer in the same per-Mac budget.
            let createdAt = Date()
            func manifest(_ size: Int) -> ReadPack {
                ReadPack(id: id, vaultId: vaultId, title: title, createdAt: createdAt, expiresAt: expiresAt,
                         bytes: size, recordCount: records.count, primaryFile: primaryFile, directory: directory, files: names.sorted())
            }
            var pack = manifest(bytes), pointer = Data()
            for _ in 0..<4 {
                guard let sealed = try AES.GCM.seal(JSONEncoder.nodus.encode(pack), using: key).combined else { throw ReadPackError.invalidSelection }
                pointer = sealed
                if pack.bytes == bytes + pointer.count { break }
                pack = manifest(bytes + pointer.count)
            }
            guard pack.bytes == bytes + pointer.count else { throw ReadPackError.invalidSelection }
            guard pack.bytes <= Self.maximumSelectedCopyBytes else { throw ReadPackError.perDownloadLimit }
            guard pack.bytes + otherBytes <= readLimitBytes else { throw ReadPackError.tooLarge }
            try PrivateBridgeProtectedFile.write(pointer, to: readPackPointer(id))
            BackupPolicy.apply(.excluded, to: readPackPointer(id))
            committed = true
            for name in names { try removeIfPresent(folder.appendingPathComponent("read-" + name)); try removeIfPresent(folder.appendingPathComponent(name)) }
            try cleanReadPacks()
            try trimReusableCopies(keeping: folder) // downloaded copies have priority over the consulted LRU
            return pack
        }
    }
    public func readPacks(vaultId: String) throws -> [ReadPack] {
        try Self.diskLock.withLock {
            try requireReadingAllowed()
            try requireVaultScope(vaultId)
            try cleanReadPacks()
            return try readPackManifests().filter { $0.vaultId == vaultId }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    /// Selected catalogues can span several downloads. Read every unexpired
    /// selection in newest-first order instead of hiding all but the last pack.
    /// Consulted copies never enter this list and cannot broaden a selection.
    public func downloadedData(vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws -> [Data] {
        try Self.diskLock.withLock {
            try requireReadingAllowed()
            try requireVaultScope(vaultId)
            try cleanReadPacks()
            let name = legacyURL(vaultId: vaultId, domain: domain, recordId: recordId).lastPathComponent
            return try readPackManifests().filter { $0.vaultId == vaultId && $0.files.contains(name) }
                .sorted { $0.createdAt > $1.createdAt }.map { pack in
                    let copy = folder.appendingPathComponent(pack.directory).appendingPathComponent(name)
                    return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: copy)), using: key)
                }
        }
    }
    public func hasDownloadedData(vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws -> Bool {
        try Self.diskLock.withLock {
            try requireReadingAllowed()
            try requireVaultScope(vaultId)
            try cleanReadPacks()
            let name = legacyURL(vaultId: vaultId, domain: domain, recordId: recordId).lastPathComponent
            return try readPackManifests().contains { $0.vaultId == vaultId && $0.files.contains(name) }
        }
    }
    public func removeReadPack(id: UUID, vaultId: String) throws {
        try Self.diskLock.withLock {
            guard try readPackManifests().contains(where: { $0.id == id && $0.vaultId == vaultId }) else { return }
            try removeIfPresent(readPackPointer(id)); try cleanReadPacks()
        }
    }
    private func readPackPointer(_ id: UUID) -> URL { folder.appendingPathComponent("pin-\(id.uuidString).readpack") }
    private func readPackManifests() throws -> [ReadPack] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "readpack" }.map { url in
                let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
                let pack = try JSONDecoder.nodus.decode(ReadPack.self, from: bytes)
                guard url.lastPathComponent == readPackPointer(pack.id).lastPathComponent, pack.directory.hasPrefix("pack-copy-"),
                      UUID(uuidString: String(pack.directory.dropFirst("pack-copy-".count))) != nil,
                      pack.files.allSatisfy({ $0.count == 76 && $0.hasSuffix(".bridgecache") && $0.prefix(64).allSatisfy(\.isHexDigit) }) else { throw ReadPackError.invalidSelection }
                return pack
            }
    }
    private func readPackBytes() throws -> Int { try readPackManifests().reduce(0) { $0 + $1.bytes } }
    private func cleanReadPacks() throws {
        let packs = try readPackManifests(), now = Date()
        for pack in packs where pack.expiresAt <= now { try removeIfPresent(readPackPointer(pack.id)) }
        let retained = Set(packs.filter { $0.expiresAt > now }.map(\.directory))
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            if name.hasSuffix(".bridgecache.scope"), !FileManager.default.fileExists(atPath: url.deletingPathExtension().path) { try removeIfPresent(url) }
            if name.hasPrefix("pack-copy-"), UUID(uuidString: String(name.dropFirst("pack-copy-".count))) != nil, !retained.contains(name) { try removeIfPresent(url) }
        }
    }
}
