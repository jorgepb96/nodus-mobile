import CryptoKit
import Foundation
import Security

public enum DesktopBridgeDomain: String, Sendable, Hashable, Codable, CaseIterable {
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
        expiresAt: Date?
    ) throws {
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
        let fingerprint = Self.normalizedFingerprint(certificateFingerprint)
        guard fingerprint.count == 64, fingerprint.allSatisfy(\.isHexDigit) else {
            throw DesktopBridgeError.invalidFingerprint
        }
        self.id = id
        self.origin = origin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.certificateFingerprint = fingerprint.lowercased()
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.vaultIds = vaultIds
        self.domains = domains
        self.pairedAt = pairedAt
        self.expiresAt = expiresAt
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
        case .locked: "Private Bridge data is unavailable while this device is locked."
        }
    }
}

/// Direct private transport. It accepts only the leaf certificate fingerprint approved at
/// pairing and blocks redirects, so a DNS or captive-portal change cannot move a private
/// request to another host.
public actor DesktopBridgeClient {
    private let pairing: DesktopBridgePairing
    private let session: URLSession
    private var token: String

    public init(pairing: DesktopBridgePairing, token: String) {
        self.pairing = pairing
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        let delegate = DesktopBridgeSessionDelegate(fingerprint: pairing.certificateFingerprint)
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    /// Completes an offer shown by Desktop. The fingerprint travels out-of-band with the code
    /// and pins the very first request; pairing is never a "trust on first use" connection.
    public static func pair(
        origin: String,
        certificateFingerprint: String,
        code: String,
        deviceId: String,
        deviceName: String
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
            expiresAt: nil
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = DesktopBridgeSessionDelegate(fingerprint: provisional.certificateFingerprint)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        guard let url = URL(string: provisional.origin + "/bridge/v1/pair") else {
            throw DesktopBridgeError.invalidOrigin
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.nodus.encode(PairingRequest(
            code: code,
            deviceId: deviceId,
            deviceName: deviceName
        ))
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
                throw DesktopBridgeError.permissionDenied
            }
            let envelope = try JSONDecoder.nodus.decode(PairingEnvelope.self, from: data)
            return (
                try DesktopBridgePairing(
                    id: envelope.pairing.id,
                    origin: provisional.origin,
                    certificateFingerprint: provisional.certificateFingerprint,
                    deviceId: envelope.pairing.deviceId,
                    deviceName: envelope.pairing.deviceName,
                    vaultIds: Set(envelope.pairing.vaultIds),
                    domains: Set(envelope.pairing.domains),
                    pairedAt: envelope.pairing.createdAt,
                    expiresAt: envelope.pairing.expiresAt
                ),
                envelope.token
            )
        } catch let error as URLError where error.code == .serverCertificateUntrusted || error.code == .secureConnectionFailed {
            throw DesktopBridgeError.certificateMismatch
        } catch is DecodingError {
            throw DesktopBridgeError.malformedResponse
        }
    }

    public func capabilities() async throws -> DesktopBridgeCapabilitiesDocument {
        try await request("/bridge/v1/capabilities", as: DesktopBridgeCapabilitiesDocument.self)
    }

    public func privateJSON<T: Decodable & Sendable>(
        vaultId: String,
        domain: DesktopBridgeDomain,
        path: String,
        as type: T.Type = T.self
    ) async throws -> T {
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
        guard let url = URL(string: pairing.origin + path) else { throw DesktopBridgeError.invalidOrigin }
        return try await request(url, as: type)
    }

    private func request<T: Decodable & Sendable>(_ url: URL, as type: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
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

private struct PairingRequest: Encodable {
    let code: String
    let deviceId: String
    let deviceName: String
}

private struct PairingEnvelope: Decodable {
    struct RawPairing: Decodable {
        let id: String
        let deviceId: String
        let deviceName: String
        let vaultIds: [String]
        let domains: [DesktopBridgeDomain]
        let createdAt: Date
        let expiresAt: Date?
    }
    let token: String
    let pairing: RawPairing
}

/// Public pairing metadata stays in ordinary app preferences; only the bearer token is secret.
/// Revoking locally deletes it synchronously, so the app cannot issue another request even if
/// the Mac is currently unreachable and has not yet recorded its own revocation.
public struct DesktopBridgePairingStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let keychain: KeychainStore
    private let metadataKey = "desktop-bridge-pairings-v1"

    public init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
    }

    public func pairings() -> [DesktopBridgePairing] {
        guard let data = defaults.data(forKey: metadataKey) else { return [] }
        return (try? JSONDecoder.nodus.decode([DesktopBridgePairing].self, from: data)) ?? []
    }

    public func save(_ pairing: DesktopBridgePairing, token: String) throws {
        var values = pairings().filter { $0.id != pairing.id }
        values.append(pairing)
        try keychain.set(token, for: KeychainStore.desktopBridgeKey(pairingId: pairing.id))
        defaults.set(try JSONEncoder.nodus.encode(values), forKey: metadataKey)
    }

    public func credential(for pairing: DesktopBridgePairing) -> String? {
        keychain.value(for: KeychainStore.desktopBridgeKey(pairingId: pairing.id))
    }

    public func revokeLocally(_ pairing: DesktopBridgePairing) throws {
        try keychain.remove(KeychainStore.desktopBridgeKey(pairingId: pairing.id))
        try? keychain.remove(KeychainStore.desktopBridgeCacheKey(pairingId: pairing.id))
        try? FileManager.default.removeItem(at: PrivateBridgeCache.defaultDirectory
            .appendingPathComponent("bridge-\(pairing.id)", isDirectory: true))
        defaults.set(
            try JSONEncoder.nodus.encode(pairings().filter { $0.id != pairing.id }),
            forKey: metadataKey
        )
    }
}

private final class DesktopBridgeSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
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
public actor PrivateBridgeCache {
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NodusPrivateBridge", isDirectory: true)
    }

    private let folder: URL
    private let key: SymmetricKey

    public init(pairingId: String, directory: URL, keychain: KeychainStore = KeychainStore()) throws {
        folder = directory.appendingPathComponent("bridge-\(pairingId)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: folder.path)
        BackupPolicy.apply(.excluded, to: folder)
        let keyName = KeychainStore.desktopBridgeCacheKey(pairingId: pairingId)
        if let encoded = keychain.value(for: keyName), let data = Data(base64Encoded: encoded), data.count == 32 {
            key = SymmetricKey(data: data)
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw DesktopBridgeError.locked
            }
            let data = Data(bytes)
            try keychain.set(data.base64EncodedString(), for: keyName)
            key = SymmetricKey(data: data)
        }
    }

    public init(pairingId: String, keychain: KeychainStore = KeychainStore()) throws {
        try self.init(pairingId: pairingId, directory: Self.defaultDirectory, keychain: keychain)
    }

    public func store(_ data: Data, vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws {
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else { throw DesktopBridgeError.malformedResponse }
        let url = fileURL(vaultId: vaultId, domain: domain, recordId: recordId)
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
        BackupPolicy.apply(.excluded, to: url)
    }

    public func data(vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws -> Data? {
        let url = fileURL(vaultId: vaultId, domain: domain, recordId: recordId)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: url)), using: key)
    }

    public func remove(vaultId: String, domain: DesktopBridgeDomain, recordId: String) throws {
        let url = fileURL(vaultId: vaultId, domain: domain, recordId: recordId)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func fileURL(vaultId: String, domain: DesktopBridgeDomain, recordId: String) -> URL {
        let address = "\(vaultId)\u{1f}\(domain.rawValue)\u{1f}\(recordId)"
        let name = SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name).appendingPathExtension("bridgecache")
    }
}
