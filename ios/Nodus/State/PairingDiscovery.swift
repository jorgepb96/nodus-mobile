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

/// Separate from single-use-code discovery: these TXT records are address hints
/// for Macs whose identity and certificate were already approved by the user.
@MainActor
final class LinkedMacDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private(set) var advertisements: [DesktopLinkedMacAdvertisement] = []
    private var callback: ((DesktopLinkedMacAdvertisement) -> Void)?
    private var searching = false
    private var restartAfter = Date.distantPast
    private var retryPolicy = DesktopLinkedMacResolutionRetries()
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private func key(_ service: NetService) -> String { service.domain + service.type + service.name }
    func start(receive: @escaping (DesktopLinkedMacAdvertisement) -> Void) {
        callback = receive
        guard !searching, Date() >= restartAfter else { return }
        searching = true; browser.delegate = self
        browser.searchForServices(ofType: "_nodus-mobile._tcp.", inDomain: "local.")
    }
    func stop() {
        searching = false; retryPolicy.stop()
        retryTasks.values.forEach { $0.cancel() }; retryTasks = [:]
        browser.stop(); services.values.forEach { $0.stopMonitoring(); $0.stop() }
        services = [:]; advertisements = []; callback = nil
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        let id = key(service)
        guard searching, retryPolicy.track(id) else { return }
        services[id] = service; service.delegate = self; service.resolve(withTimeout: 4)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        let id = key(service)
        retryPolicy.remove(id); retryTasks.removeValue(forKey: id)?.cancel()
        if let old = services.removeValue(forKey: id) { old.stopMonitoring(); old.stop() }
        refreshAdvertisements()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        stop(); restartAfter = Date().addingTimeInterval(30)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        let id = key(sender)
        guard searching, services[id] === sender else { return }
        retryPolicy.resolved(id); retryTasks.removeValue(forKey: id)?.cancel()
        sender.startMonitoring(); refreshAdvertisements()
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = key(sender)
        guard searching, services[id] === sender, let retry = retryPolicy.failed(id) else { return }
        sender.stop()
        retryTasks[id] = Task { [weak self, weak sender] in
            do { try await Task.sleep(for: retry.delay) } catch { return }
            guard let self, let sender, !Task.isCancelled, self.searching,
                  self.services[id] === sender, self.retryPolicy.consume(retry, service: id) else { return }
            self.retryTasks[id] = nil
            sender.resolve(withTimeout: 4)
        }
    }
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        guard searching, services[key(sender)] === sender else { return }
        refreshAdvertisements()
    }
    private func refreshAdvertisements() {
        advertisements = services.values.compactMap { service in
            guard let bytes = service.txtRecordData() else { return nil }
            return try? DesktopLinkedMacAdvertisement(txt: NetService.dictionary(fromTXTRecord: bytes))
        }
        for advertisement in advertisements { callback?(advertisement) }
    }
}
