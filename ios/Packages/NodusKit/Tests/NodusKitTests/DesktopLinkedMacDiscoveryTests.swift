import Foundation
import CryptoKit
import Testing
@testable import NodusKit

@Suite("Already linked Mac discovery", .serialized)
struct DesktopLinkedMacDiscoveryTests {
    let mac = "6f8c053b-c5ef-4566-9578-a8372d952b01"
    func txt(_ origins: [String]) -> [String: Data] {
        var fields = ["discoveryVersion": Data("1".utf8), "macId": Data(mac.utf8), "rc": Data(String(origins.count).utf8)]
        for (index, origin) in origins.enumerated() { fields["r\(index)"] = Data(origin.utf8) }
        return fields
    }
    @Test("TXT hints are bounded HTTPS origins, preserve IPv6, and never supply a new pin")
    func advertisement() throws {
        let origins = ["https://192.168.1.4:7443", "https://mac.local:7443", "https://[fd7a:115c:a1e0::1]:7443"]
        let advertised = try DesktopLinkedMacAdvertisement(txt: txt(origins))
        #expect(advertised.macDeviceId == mac); #expect(advertised.origins == origins)
        for invalid in ["http://mac.local:7443", "https://user:secret@mac.local", "https://mac.local/path", "https://mac.local/", "https://mac.local?q=a", "https://mac.local#fragment", "https://mac.local:0", "https://mac.local:65536"] {
            #expect(throws: (any Error).self) { try DesktopLinkedMacAdvertisement(txt: txt([invalid])) }
        }
        for count in ["0", "17", "-1", "01", "999999999999999999999"] {
            var fields = txt(origins); fields["rc"] = Data(count.utf8)
            #expect(throws: (any Error).self) { try DesktopLinkedMacAdvertisement(txt: fields) }
        }
        var oversized = txt(origins); oversized["r0"] = Data(repeating: 65, count: 241)
        #expect(throws: (any Error).self) { try DesktopLinkedMacAdvertisement(txt: oversized) }
        #expect(throws: (any Error).self) { try DesktopLinkedMacAdvertisement(txt: ["n": Data("1".utf8), "proof": Data("old-offer".utf8)]) }
    }
    #if os(macOS) // This fixture launches local Node/OpenSSL; iOS transport remains a native acceptance gate.
    @Test("Real local HTTPS rejects another certificate before HTTP and probes the approved Mac without bearer")
    func realPinnedTLS() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent("linked-discovery-tls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func openssl(_ arguments: [String]) throws {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl"); process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit(); #expect(process.terminationStatus == 0)
        }
        for name in ["approved", "other"] {
            try openssl(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", root.appendingPathComponent(name + ".key").path,
                "-out", root.appendingPathComponent(name + ".crt").path, "-days", "1", "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1"])
        }
        let der = root.appendingPathComponent("approved.der")
        try openssl(["x509", "-in", root.appendingPathComponent("approved.crt").path, "-outform", "DER", "-out", der.path])
        let pin = SHA256.hash(data: try Data(contentsOf: der)).map { String(format: "%02x", $0) }.joined()
        let script = root.appendingPathComponent("fixture.mjs")
        try """
        import https from 'node:https';import fs from 'node:fs';import path from 'node:path';
        const root=process.argv[2],mac=process.argv[3],log=path.join(root,'requests.jsonl'),ports={};
        for(const [kind,cert,deviceId]of [['approved','approved',mac],['other','other',mac],['wrongMac','approved','other-mac']]) {
          const server=https.createServer({key:fs.readFileSync(path.join(root,cert+'.key')),cert:fs.readFileSync(path.join(root,cert+'.crt'))},(req,res)=>{
            fs.appendFileSync(log,JSON.stringify({kind,path:req.url,hasAuthorization:!!req.headers.authorization})+'\\n');
            res.writeHead(200,{'content-type':'application/json'});res.end(JSON.stringify({protocolVersion:1,deviceId,deviceName:'Fixture Mac',vaultIds:[],domains:[]}));
          });server.listen(0,'127.0.0.1',()=>{ports[kind]=server.address().port;if(Object.keys(ports).length===3)fs.writeFileSync(path.join(root,'ports.json'),JSON.stringify(ports));});
        }
        setTimeout(()=>process.exit(0),20000);
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["node", script.path, root.path, mac]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        let portsURL = root.appendingPathComponent("ports.json")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: portsURL.path) { try await Task.sleep(for: .milliseconds(50)) }
        let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: portsURL))
        let f = try Fixture(); defer { f.clean() }; let pairing = try f.grant(mac: mac, pin: pin)
        try f.store.save(pairing, token: "isolated-fixture-token")
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration, delegate: DesktopBridgeSessionDelegate(fingerprint: pin), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let client = DesktopBridgeClient(pairing: pairing, token: "isolated-fixture-token", store: f.store, session: session)
        let oldClient = DesktopBridgeClient(pairing: pairing, token: "isolated-fixture-token", store: f.store, session: session)
        func origin(_ name: String) throws -> String { "https://127.0.0.1:" + String(try #require(ports[name])) }
        await #expect(throws: (any Error).self) { try await client.verifyDiscoveredOrigin(origin("other"), trustedMacDeviceId: mac) }
        await #expect(throws: DesktopBridgeError.self) { try await client.verifyDiscoveredOrigin(origin("wrongMac"), trustedMacDeviceId: mac) }
        #expect(f.store.pairings().first?.origin == pairing.origin)
        _ = try await client.verifyDiscoveredOrigin(origin("approved"), trustedMacDeviceId: mac)
        _ = try await oldClient.controlPlane("health")
        let lines = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        let requests = try lines.map { try JSONDecoder.nodus.decode(JSONValue.self, from: Data($0.utf8)) }
        #expect(requests.count == 3)
        #expect(!requests.contains { $0.objectValue?["kind"] == .string("other") })
        #expect(requests.prefix(2).allSatisfy { $0.objectValue?["hasAuthorization"] == .bool(false) && $0.objectValue?["path"] == .string("/bridge/v1/capabilities") })
        #expect(requests.last?.objectValue?["hasAuthorization"] == .bool(true))
    }
    #endif

    @Test("Transient resolution retries are bounded, independent and never duplicated")
    func resolutionRetryBackoff() throws {
        var policy = DesktopLinkedMacResolutionRetries()
        let first = policy.track("Mac A"), duplicate = policy.track("Mac A"), second = policy.track("Mac B")
        #expect(first && !duplicate && second)
        for seconds in [1, 2, 4, 8, 16, 30, 30, 30] {
            let pending = policy.failed("Mac A"), retry = try #require(pending)
            #expect(retry.delay == .seconds(seconds))
            let repeated = policy.failed("Mac A")
            #expect(repeated == nil, "A repeated failure callback cannot create another timer")
            let consumed = policy.consume(retry, service: "Mac A"), consumedAgain = policy.consume(retry, service: "Mac A")
            #expect(consumed && !consumedAgain, "A timer can issue only one resolve")
        }
        let pendingB = policy.failed("Mac B"), independent = try #require(pendingB)
        #expect(independent.delay == .seconds(1))
        for i in 2..<32 { let tracked = policy.track("Mac \(i)"); #expect(tracked) }
        let overflow = policy.track("service-over-limit"); #expect(!overflow)
    }
    @Test("Success, disappearance and stop invalidate pending retries without resurrecting a browser")
    func resolutionRetryLifecycle() throws {
        var policy = DesktopLinkedMacResolutionRetries()
        let tracked = policy.track("Mac"); #expect(tracked)
        let pendingSuccess = policy.failed("Mac"), beforeSuccess = try #require(pendingSuccess)
        policy.resolved("Mac")
        let lateSuccess = policy.consume(beforeSuccess, service: "Mac"); #expect(!lateSuccess)
        let pendingRemoval = policy.failed("Mac"), beforeRemoval = try #require(pendingRemoval)
        #expect(beforeRemoval.delay == .seconds(1))
        policy.remove("Mac")
        let lateRemoval = policy.consume(beforeRemoval, service: "Mac"), missing = policy.failed("Mac")
        #expect(!lateRemoval && missing == nil)
        let rediscovered = policy.track("Mac"); #expect(rediscovered)
        let pendingStop = policy.failed("Mac"), beforeStop = try #require(pendingStop)
        policy.stop()
        let lateStop = policy.consume(beforeStop, service: "Mac"), stopped = policy.failed("Mac")
        #expect(!lateStop && stopped == nil)
        let started = policy.track("Mac"); #expect(started)
        let pendingRestart = policy.failed("Mac"), restarted = try #require(pendingRestart)
        #expect(restarted.delay == .seconds(1))
        let staleTimer = policy.consume(beforeStop, service: "Mac"), freshTimer = policy.consume(restarted, service: "Mac")
        #expect(!staleTimer && freshTimer, "A canceled old timer cannot consume a new search's retry")
    }
    struct Fixture {
        let id = UUID().uuidString
        let defaults: UserDefaults
        let keychain: KeychainStore
        let store: DesktopBridgePairingStore
        let session: URLSession
        init() throws {
            defaults = UserDefaults(suiteName: "linked-discovery-" + id)!
            keychain = KeychainStore(service: "linked-discovery-" + id)
            store = DesktopBridgePairingStore(defaults: defaults, keychain: keychain)
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [DiscoveryProtocol.self]
            session = URLSession(configuration: configuration)
        }
        func grant(mac: String, domains: Set<DesktopBridgeDomain> = [.corpus,.writing], expiry: Date? = nil, pin: String = String(repeating: "a",count:64)) throws -> DesktopBridgePairing {
            try DesktopBridgePairing(id: id, origin: "https://old.nodus.test:7443", certificateFingerprint: pin, deviceId: "phone-not-mac", deviceName: "Phone", vaultIds: ["fixed-vault"], domains: domains, pairedAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: expiry, macDeviceId: mac)
        }
        func clean() { session.invalidateAndCancel(); defaults.removePersistentDomain(forName: "linked-discovery-" + id); try? keychain.remove(KeychainStore.desktopBridgeKey(pairingId: id)) }
    }
    @Test("The identity probe has no bearer; only a verified Mac address is persisted and later used")
    func identityProbe() async throws {
        let f = try Fixture(); defer { f.clean() }; let pairing = try f.grant(mac: mac)
        try f.store.save(pairing, token: "private-phone-token")
        let client = DesktopBridgeClient(pairing: pairing, token: "private-phone-token", store: f.store, session: f.session)
        let alreadyOpenClient = DesktopBridgeClient(pairing: pairing, token: "private-phone-token", store: f.store, session: f.session)
        DiscoveryProtocol.state.reset(mac: mac)
        let updated = try await client.verifyDiscoveredOrigin("https://new.nodus.test:7443", trustedMacDeviceId: mac)
        #expect(updated.origin == "https://new.nodus.test:7443")
        #expect(updated.id == pairing.id && updated.deviceId == pairing.deviceId && updated.vaultIds == pairing.vaultIds && updated.domains == pairing.domains && updated.certificateFingerprint == pairing.certificateFingerprint)
        #expect(f.store.credential(for: updated) == "private-phone-token")
        #expect(DiscoveryProtocol.state.requests().first?.value(forHTTPHeaderField: "Authorization") == nil)
        _ = try await alreadyOpenClient.controlPlane("health")
        #expect(DiscoveryProtocol.state.requests().last?.url?.host == "new.nodus.test")
        #expect(DiscoveryProtocol.state.requests().last?.value(forHTTPHeaderField: "Authorization") == "Bearer private-phone-token")
    }
    @Test("A newly discovered VPN alternative is pinned and saved without replacing the healthy primary")
    func vpnAlternative() async throws {
        let f = try Fixture(); defer { f.clean() }; let pairing = try f.grant(mac: mac)
        try f.store.save(pairing, token: "private")
        let client = DesktopBridgeClient(pairing: pairing, token: "private", store: f.store, session: f.session)
        DiscoveryProtocol.state.reset(mac: mac)
        let updated = try await client.verifyDiscoveredOrigin("https://100.90.80.70:7443", trustedMacDeviceId: mac, makePrimary: false)
        #expect(updated.origin == pairing.origin)
        #expect(updated.alternateOrigins?.contains("https://100.90.80.70:7443") == true)
        #expect(updated.macDeviceId == pairing.macDeviceId && updated.domains == pairing.domains && updated.vaultIds == pairing.vaultIds)
        #expect(DiscoveryProtocol.state.requests().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        _ = try await client.controlPlane("health")
        #expect(DiscoveryProtocol.state.requests().last?.url?.host == "old.nodus.test")
    }
    @Test("Forged identity, transport certificate failure, cancellation and concurrent revocation leave address intact")
    func rejectedHints() async throws {
        let f = try Fixture(); defer { f.clean() }; let pairing = try f.grant(mac: mac)
        try f.store.save(pairing, token: "private")
        let client = DesktopBridgeClient(pairing: pairing, token: "private", store: f.store, session: f.session)
        for error in [URLError.Code.serverCertificateUntrusted, .secureConnectionFailed, .timedOut, .cancelled] {
            DiscoveryProtocol.state.reset(mac: mac, error: error)
            await #expect(throws: (any Error).self) { try await client.verifyDiscoveredOrigin("https://forged.nodus.test", trustedMacDeviceId: mac) }
            #expect(f.store.pairings().first?.origin == pairing.origin)
        }
        DiscoveryProtocol.state.reset(mac: UUID().uuidString)
        await #expect(throws: DesktopBridgeError.self) { try await client.verifyDiscoveredOrigin("https://other-mac.nodus.test", trustedMacDeviceId: mac) }
        #expect(f.store.pairings().first?.origin == pairing.origin)
        #expect(DiscoveryProtocol.state.requests().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        let store = f.store
        DiscoveryProtocol.state.reset(mac: mac, action: { _ = store.markAuthorizationRevoked(pairingId: pairing.id) })
        await #expect(throws: DesktopBridgeError.self) { try await client.verifyDiscoveredOrigin("https://late.nodus.test", trustedMacDeviceId: mac) }
        #expect(f.store.pairings(includeRevoked: true).first?.origin == pairing.origin)
    }
    @Test("Pending handshakes and expired grants cannot be activated by discovery")
    func pendingAndExpired() async throws {
        let f = try Fixture(); defer { f.clean() }; let pairing = try f.grant(mac: mac)
        try f.store.save(pairing, token: "private")
        let offer = DesktopPairingOffer(version: 2, id: pairing.id, code: "ABCDE-23456", origins: [pairing.origin],
            certificateFingerprint: pairing.certificateFingerprint, vaultIds: Array(pairing.vaultIds), domains: Array(pairing.domains),
            expiresAt: Date().addingTimeInterval(600), deviceName: "Mac", macDeviceId: mac,
            vaults: nil, relay: nil, renewalPairingId: nil, wholeWorkspace: nil)
        _ = try f.store.preparePendingPairing(offer: offer, deviceId: pairing.deviceId, deviceName: pairing.deviceName, token: "candidate")
        defer { try? f.store.completePendingPairing(grantId: pairing.id) }
        let client = DesktopBridgeClient(pairing: pairing, token: "private", store: f.store, session: f.session)
        DiscoveryProtocol.state.reset(mac: mac)
        await #expect(throws: DesktopBridgeError.self) { try await client.verifyDiscoveredOrigin("https://moved.nodus.test", trustedMacDeviceId: mac) }
        #expect(try f.store.hasPendingWorkspaceRegistration(grantId: pairing.id))
        #expect(DiscoveryProtocol.state.requests().isEmpty)
        try f.store.completePendingPairing(grantId: pairing.id)
        try f.store.save(f.grant(mac: mac, expiry: Date(timeIntervalSince1970: 1)), token: "expired")
        await #expect(throws: DesktopBridgeError.self) { try await client.verifyDiscoveredOrigin("https://moved.nodus.test", trustedMacDeviceId: mac) }
        #expect(DiscoveryProtocol.state.requests().isEmpty)
        #expect(f.store.pairings().first?.origin == pairing.origin)
    }
    @Test("Discovery retains a concurrent renewed token, expiry and weaker scope without completing pending registration")
    func renewalRace() async throws {
        let f = try Fixture(); defer { f.clean() }; let pairing = try f.grant(mac: mac)
        try f.store.save(pairing, token: "old")
        let newer = try f.grant(mac: mac, domains: [.corpus], expiry: Date(timeIntervalSince1970: 2_000_000_000))
        let client = DesktopBridgeClient(pairing: pairing, token: "old", store: f.store, session: f.session)
        let store = f.store
        DiscoveryProtocol.state.reset(mac: mac, action: { try? store.save(newer, token: "renewed") })
        let updated = try await client.verifyDiscoveredOrigin("https://moved.nodus.test", trustedMacDeviceId: mac)
        #expect(updated.domains == [.corpus]); #expect(updated.expiresAt == newer.expiresAt)
        #expect(f.store.credential(for: updated) == "renewed")
        #expect(updated.vaultIds == pairing.vaultIds && updated.pairedAt == pairing.pairedAt)
    }
}
private final class DiscoveryProtocol: URLProtocol, @unchecked Sendable {
    static let state = DiscoveryState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (mac,error,action) = Self.state.record(request); action?()
        if let error { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        let data = try! JSONSerialization.data(withJSONObject: ["protocolVersion":1,"deviceId":mac,"deviceName":"Mac","vaultIds":[],"domains":[]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode:200,httpVersion:nil,headerFields:nil)!, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class DiscoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var mac = "", error: URLError.Code?, calls: [URLRequest] = [], action: (@Sendable () -> Void)?
    func reset(mac: String, error: URLError.Code? = nil, action: (@Sendable () -> Void)? = nil) { lock.withLock { self.mac=mac; self.error=error; calls=[]; self.action=action } }
    func record(_ request: URLRequest) -> (String,URLError.Code?,(@Sendable () -> Void)?) { lock.withLock { calls.append(request); let next=action;action=nil;return(mac,error,next) } }
    func requests() -> [URLRequest] { lock.withLock { calls } }
}
