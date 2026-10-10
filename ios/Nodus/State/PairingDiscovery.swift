import Foundation
import NodusKit
import Observation

@MainActor @Observable
final class PairingDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private(set) var offer: DesktopPairingOffer?
    private(set) var error: String?
    private(set) var searching = false
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var code = ""
    private var timeout: Task<Void, Never>?

    func search(code: String) {
        stop(); self.code = code; offer = nil; error = nil; searching = true
        browser.delegate = self
        browser.searchForServices(ofType: "_nodus-mobile._tcp.", inDomain: "local.")
        timeout = Task {
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, searching else { return }
            error = String(localized: "No Mac with this code was found. Check that both devices are on the same network, or scan the QR.")
            stop()
        }
    }
    func stop() { timeout?.cancel(); timeout = nil; browser.stop(); services.forEach { $0.stop() }; services = []; searching = false }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service); service.delegate = self; service.resolve(withTimeout: 10)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        error = String(localized: "Local network discovery is unavailable. Allow local network access or scan the QR."); stop()
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let data = sender.txtRecordData() else { return }
        let fields = NetService.dictionary(fromTXTRecord: data)
        guard let countData = fields["n"], let count = Int(String(decoding: countData, as: UTF8.self)), count > 0, count <= 92,
              let proof = fields["proof"] else { return }
        var payload = ""
        for index in 0..<count { guard let part = fields["p\(index)"] else { return }; payload += String(decoding: part, as: UTF8.self) }
        // Offers with other codes and forged TXT records are ignored before any network pairing.
        guard let validated = try? DesktopPairingOffer.discovered(payload: payload, proof: String(decoding: proof, as: UTF8.self), code: code) else { return }
        offer = validated; stop()
    }
}
