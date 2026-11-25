import Foundation
import Network

/// How long to wait before restarting a failed listener or browser: 1, 2, 4
/// … up to 30 seconds.
func nearbyRetryDelay(afterFailures failures: Int) -> TimeInterval {
    min(30, pow(2, Double(max(0, failures - 1))))
}

/// The phone's side: announces `join` on the local network while it lives.
/// The service instance gets a random name (not the device's) and carries
/// the announcement in its TXT record; nothing connects to it, and a
/// connection attempt is dropped at once. A listener the network drops is
/// started again with a growing delay (nothing is logged). `stop()` (or
/// releasing the last reference) takes the announcement off the air.
public final class NearbyAdvertiser: @unchecked Sendable {
    private let join: NearbyJoin
    private let queue = DispatchQueue(label: "matine.nearby.advertise")
    // Touched only on `queue`.
    private var listener: NWListener?
    private var stopped = false
    private var failures = 0

    public init(_ join: NearbyJoin) {
        self.join = join
        queue.async { self.begin() }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.listener?.cancel()
            self.listener = nil
        }
    }

    deinit { listener?.cancel() }

    private func begin() {
        guard !stopped else { return }
        guard let listener = try? NWListener(using: .tcp) else { return retry() }
        listener.service = NWListener.Service(
            name: UUID().uuidString, type: NearbyJoin.serviceType, domain: nil,
            txtRecord: NWTXTRecord(join.txt)
        )
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            self.queue.async {
                guard self.listener === listener else { return }
                switch state {
                case .ready: self.failures = 0
                case .failed:
                    // A listener the network dropped is replaced (not on .waiting:
                    // that can be the local network prompt, still unanswered).
                    listener.cancel()
                    self.listener = nil
                    self.retry()
                default: break
                }
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    private func retry() {
        guard !stopped else { return }
        failures += 1
        queue.asyncAfter(deadline: .now() + nearbyRetryDelay(afterFailures: failures)) { [weak self] in self?.begin() }
    }
}

/// The TV's side: what is announced nearby, as a stream of the current list
/// each time it changes (only the newest list is kept, and at most
/// `NearbyJoin.resultCap` entries). A browser the network drops is started
/// again with a growing delay. Cancelling the consumer stops the browse.
public enum NearbyBrowser {
    public static func joins() -> AsyncStream<[NearbyJoin]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let session = Session(continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }

    private final class Session: @unchecked Sendable {
        private let continuation: AsyncStream<[NearbyJoin]>.Continuation
        private let queue = DispatchQueue(label: "matine.nearby.browse")
        // Touched only on `queue`.
        private var browser: NWBrowser?
        private var stopped = false
        private var failures = 0

        init(_ continuation: AsyncStream<[NearbyJoin]>.Continuation) { self.continuation = continuation }

        func start() { queue.async { self.begin() } }

        func stop() {
            queue.async {
                self.stopped = true
                self.browser?.cancel()
                self.browser = nil
            }
        }

        private func begin() {
            guard !stopped else { return }
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: NearbyJoin.serviceType, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [continuation] results, _ in
                var joins: [NearbyJoin] = []
                for result in results {
                    guard joins.count < NearbyJoin.resultCap else { break }
                    guard case .bonjour(let record) = result.metadata, let join = NearbyJoin(txt: record.dictionary) else { continue }
                    joins.append(join)
                }
                continuation.yield(joins)
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser else { return }
                self.queue.async {
                    guard self.browser === browser else { return }
                    switch state {
                    case .ready: self.failures = 0
                    case .failed:
                        browser.cancel()
                        self.browser = nil
                        self.failures += 1
                        // Nothing is on the air that we can still hear.
                        self.continuation.yield([])
                        self.queue.asyncAfter(deadline: .now() + nearbyRetryDelay(afterFailures: self.failures)) { self.begin() }
                    default: break
                    }
                }
            }
            self.browser = browser
            browser.start(queue: queue)
        }
    }
}
