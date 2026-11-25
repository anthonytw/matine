import Foundation
import Testing
@testable import MatineKit

/// A scripted socket: hands out its messages, then blocks (like a quiet
/// server) until cancelled or `failAfterMessages` is reached.
final class FakeSocket: RemoteSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [String]
    private let endsWithError: Bool
    private let status: Int?
    private var cancelled = false
    private var sentMessages: [String] = []
    private var waiter: CheckedContinuation<Data, any Error>?

    init(script: [String] = [], endsWithError: Bool = false, status: Int? = nil) {
        self.script = script
        self.endsWithError = endsWithError
        self.status = status
    }

    var sent: [String] { lock.withLock { sentMessages } }
    var wasCancelled: Bool { lock.withLock { cancelled } }
    var upgradeStatus: Int? { status }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Data, any Error>? = lock.withLock {
                if cancelled { return .failure(URLError(.cancelled)) }
                if !script.isEmpty { return .success(Data(script.removeFirst().utf8)) }
                if endsWithError { return .failure(URLError(.networkConnectionLost)) }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    func send(_ text: String) async throws { lock.withLock { sentMessages.append(text) } }

    func cancel() {
        let pending = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            cancelled = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(throwing: URLError(.cancelled))
    }
}

/// Collects what the listener yields.
final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [RemoteEvent] = []
    var all: [RemoteEvent] { lock.withLock { list } }
    func add(_ event: RemoteEvent) { lock.withLock { list.append(event) } }
}

final class Sleeps: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [TimeInterval] = []
    var all: [TimeInterval] { lock.withLock { list } }
    func add(_ seconds: TimeInterval) { lock.withLock { list.append(seconds) } }
}

private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite struct RemoteListenerTests {
    private static let playJSON = #"{"MessageType":"Play","Data":{"ItemIds":["a"],"PlayCommand":"PlayNow"}}"#

    @Test func cancellingEndsAConnectionThatIsWaitingPromptly() async throws {
        let socket = FakeSocket(script: [#"{"MessageType":"ForceKeepAlive","Data":60}"#])
        let events = Events()
        let task = Task {
            await RemoteListener.connectOnce(socket: socket, capabilities: {}, sleep: { _ in try? await Task.sleep(for: .milliseconds(5)) }) { events.add($0) }
        }
        #expect(await waitUntil { events.all.contains(.connected) })
        task.cancel()
        let started = ContinuousClock.now
        _ = await task.value
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(socket.wasCancelled)
    }

    @Test func cancellingTheStreamClosesTheSocketAndStopsKeepAlives() async throws {
        let socket = FakeSocket(script: [#"{"MessageType":"ForceKeepAlive","Data":60}"#])
        let stream = RemoteListener.events(
            makeSocket: { socket }, capabilities: {}, sleep: { _ in try? await Task.sleep(for: .milliseconds(5)) },
            now: { Date() }, jitter: { 0.5 }
        )
        let task = Task { for await _ in stream {} }
        #expect(await waitUntil { !socket.sent.isEmpty })
        task.cancel()
        #expect(await waitUntil { socket.wasCancelled })
        try await Task.sleep(for: .milliseconds(50))
        let count = socket.sent.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(socket.sent.count == count)
    }

    @Test func keepAliveIsSentAtHalfTheServersInterval() async throws {
        let socket = FakeSocket(script: [#"{"MessageType":"ForceKeepAlive","Data":60}"#])
        let sleeps = Sleeps()
        let task = Task {
            await RemoteListener.connectOnce(socket: socket, capabilities: {}, sleep: { sleeps.add($0); try? await Task.sleep(for: .milliseconds(5)) }) { _ in }
        }
        #expect(await waitUntil { socket.sent.count >= 3 })
        task.cancel()
        _ = await task.value
        #expect(socket.sent.allSatisfy { $0 == #"{"MessageType":"KeepAlive"}"# })
        #expect(Set(sleeps.all) == [30])
    }

    @Test func commandsAreYieldedAndTheRestIgnored() async throws {
        let socket = FakeSocket(script: [#"{"MessageType":"ForceKeepAlive","Data":60}"#, #"{"MessageType":"Sessions","Data":[]}"#, Self.playJSON], endsWithError: true)
        let events = Events()
        let outcome = await RemoteListener.connectOnce(socket: socket, capabilities: {}, sleep: { _ in try? await Task.sleep(for: .milliseconds(5)) }) { events.add($0) }
        #expect(outcome == .dropped)
        #expect(events.all == [.connected, .command(.play(itemIds: ["a"], startIndex: nil, startTicks: 0))])
    }

    @Test func notConnectedUntilTheServerHasTheCapabilities() async throws {
        struct Down: Error {}
        let socket = FakeSocket(script: [#"{"MessageType":"ForceKeepAlive","Data":60}"#, Self.playJSON], endsWithError: true)
        let events = Events()
        let outcome = await RemoteListener.connectOnce(socket: socket, capabilities: { throw Down() }, sleep: { _ in }) { events.add($0) }
        #expect(outcome == .dropped)
        #expect(events.all.isEmpty)
    }

    @Test func aTokenRefusedAtTheCapabilitiesStopsTheRetries() async throws {
        let socket = FakeSocket(script: [#"{"MessageType":"ForceKeepAlive","Data":60}"#], endsWithError: true)
        let outcome = await RemoteListener.connectOnce(socket: socket, capabilities: { throw JellyfinError.unauthorized }, sleep: { _ in }) { _ in }
        #expect(outcome == .refused)
    }

    @Test func aRefusedTokenStopsTheRetries() async throws {
        let made = Sleeps()
        let events = Events()
        let stream = RemoteListener.events(
            makeSocket: { made.add(1); return FakeSocket(endsWithError: true, status: 403) }, capabilities: {},
            sleep: { _ in }, now: { Date() }, jitter: { 0.5 }
        )
        for await event in stream { events.add(event) }
        #expect(events.all == [.disconnected(final: true)])
        #expect(made.all.count == 1)
    }

    @Test func droppedConnectionsReconnectWithGrowingBackoffThatAShortSessionKeeps() async throws {
        let sleeps = Sleeps()
        let attempts = Sleeps()
        let stream = RemoteListener.events(
            makeSocket: { attempts.add(1); return FakeSocket(endsWithError: true) }, capabilities: {},
            sleep: { sleeps.add($0); if sleeps.all.count >= 4 { try? await Task.sleep(for: .seconds(60)) } },
            now: { Date() }, jitter: { 0.5 }
        )
        let task = Task { for await _ in stream {} }
        #expect(await waitUntil { sleeps.all.count >= 4 })
        task.cancel()
        #expect(Array(sleeps.all.prefix(4)) == [1, 2, 4, 8])
    }

    @Test func aLongConnectionStartsTheBackoffOver() async throws {
        let sleeps = Sleeps()
        let clock = Sleeps()
        // Each connection "lasts" 40 s on the injected clock.
        let stream = RemoteListener.events(
            makeSocket: { FakeSocket(endsWithError: true) }, capabilities: {},
            sleep: { sleeps.add($0); if sleeps.all.count >= 3 { try? await Task.sleep(for: .seconds(60)) } },
            now: { clock.add(0); return Date(timeIntervalSince1970: Double(clock.all.count) * 40) }, jitter: { 0.5 }
        )
        let task = Task { for await _ in stream {} }
        #expect(await waitUntil { sleeps.all.count >= 3 })
        task.cancel()
        #expect(Array(sleeps.all.prefix(3)) == [1, 1, 1])
    }
}
