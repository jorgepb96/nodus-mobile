import Foundation
import Network

/// Whether this device has a network, and which one.
///
/// The interface is carried because it is half the diagnosis on a server that lives on
/// somebody's desk: a phone that has dropped off the house Wi-Fi onto cellular is fully
/// online, reaches everything on the internet, and reaches nothing at 192.168.1.20.
public enum NetworkStatus: Sendable, Hashable {
    case up(Interface, isExpensive: Bool, isConstrained: Bool)
    case down
    /// The monitor did not settle in time. Treated as "probably up" by everything that reads
    /// it: refusing to knock because the doorbell was slow is worse than knocking and being
    /// told there is nothing there.
    case unknown

    public enum Interface: Sendable, Hashable {
        case wifi
        case cellular
        case wired
        case other
    }

    public var interface: Interface? {
        guard case .up(let interface, _, _) = self else { return nil }
        return interface
    }

    public var isExpensive: Bool {
        guard case .up(_, let expensive, _) = self else { return false }
        return expensive
    }

    public var isConstrained: Bool {
        guard case .up(_, _, let constrained) = self else { return false }
        return constrained
    }
}

/// One question, asked once: does this device have a network right now?
///
/// `NWPathMonitor` is a stream and every caller here wants a single answer before deciding
/// whether it is worth contacting anything. The monitor is started, its first path is taken,
/// and it is cancelled again — so nothing is left running to be kept in sync.
public enum NetworkReachability {
    /// - Parameter within: how long to wait for the first path before giving up and answering
    ///   `.unknown`. The monitor answers in milliseconds — it is reading state the system
    ///   already holds — so a second is already generous. The bound matters because this is
    ///   asked *after* a request has failed, and it is spent on top of whatever that request
    ///   spent: "the computer may be asleep" has to arrive inside five seconds, and the budget
    ///   for saying so is not all the timeout's.
    public static func current(within seconds: TimeInterval = 1) async -> NetworkStatus {
        let monitor = NWPathMonitor()
        let gate = FirstAnswer()

        monitor.pathUpdateHandler = { path in gate.settle(Self.status(of: path)) }
        monitor.start(queue: DispatchQueue(label: "org.nodus.reachability"))

        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            gate.settle(.unknown)
        }
        let answer = await withCheckedContinuation { gate.attach($0) }
        deadline.cancel()
        monitor.cancel()
        return answer
    }

    private static func status(of path: NWPath) -> NetworkStatus {
        // `.requiresConnection` is a path that could come up but has not — a VPN that is
        // configured and not connected, most often. Nothing can be reached over it now, and
        // saying "you have a network" about it is how a diagnosis goes wrong at step one.
        guard path.status == .satisfied else { return .down }
        let interface: NetworkStatus.Interface
        if path.usesInterfaceType(.wifi) {
            interface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            interface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = .wired
        } else {
            interface = .other
        }
        return .up(interface, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
    }
}

/// The first of two racing answers wins and the other is dropped.
///
/// `@unchecked Sendable` over a lock rather than an actor, because both writers are callbacks
/// that cannot await: `NWPathMonitor` calls its handler on a dispatch queue of its own, and a
/// continuation may only ever be resumed once.
private final class FirstAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NetworkStatus, Never>?
    private var settled: NetworkStatus?

    func attach(_ continuation: CheckedContinuation<NetworkStatus, Never>) {
        lock.lock()
        if let settled {
            lock.unlock()
            continuation.resume(returning: settled)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func settle(_ status: NetworkStatus) {
        lock.lock()
        guard settled == nil else { return lock.unlock() }
        settled = status
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: status)
    }
}
