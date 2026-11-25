import Foundation

/// What the listener reports.
public enum RemoteEvent: Sendable, Equatable {
    case connected
    case command(RemoteCommand)
    /// The connection ended. `final`: the token was refused, so retrying is pointless.
    case disconnected(final: Bool)
}

/// The slice of a WebSocket the listener needs, so tests can stand in for it.
protocol RemoteSocket: Sendable {
    /// The next message; throws when the socket fails or is cancelled.
    func receive() async throws -> Data
    func send(_ text: String) async throws
    /// Closes the socket; a pending `receive` must then throw promptly.
    func cancel()
    /// The HTTP status of a refused upgrade, once known.
    var upgradeStatus: Int? { get }
}

struct URLSessionRemoteSocket: RemoteSocket {
    let task: URLSessionWebSocketTask

    init(session: URLSession, request: URLRequest) {
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func receive() async throws -> Data {
        switch try await task.receive() {
        case .string(let text): return Data(text.utf8)
        case .data(let bytes): return bytes
        @unknown default: return Data()
        }
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
    var upgradeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
}

/// The TV's side of remote control: connects to the server's WebSocket, says
/// what it can do, answers keep-alives and yields the phone's commands,
/// reconnecting with backoff until the stream is cancelled. Cancelling the
/// stream closes the socket at once.
public enum RemoteListener {
    public static func events(
        client: JellyfinClient,
        session: URLSession? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) -> AsyncStream<RemoteEvent> {
        let urlSession = session ?? URLSessionTransport.shared.session
        return events(
            makeSocket: { client.socketRequest().map { URLSessionRemoteSocket(session: urlSession, request: $0) } },
            capabilities: { try await client.reportCapabilities() },
            sleep: sleep, now: { Date() }, jitter: { Double.random(in: 0...1) }
        )
    }

    static func events(
        makeSocket: @escaping @Sendable () -> (any RemoteSocket)?,
        capabilities: @escaping @Sendable () async throws -> Void,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        now: @escaping @Sendable () -> Date,
        jitter: @escaping @Sendable () -> Double
    ) -> AsyncStream<RemoteEvent> {
        AsyncStream { continuation in
            let task = Task {
                var failures = 0
                while !Task.isCancelled {
                    let began = now()
                    guard let socket = makeSocket() else { break }
                    let outcome = await connectOnce(socket: socket, capabilities: capabilities, sleep: sleep) { continuation.yield($0) }
                    if Task.isCancelled { break }
                    continuation.yield(.disconnected(final: outcome == .refused))
                    if outcome == .refused { break }
                    failures = ReconnectBackoff.failures(after: failures, connectionLasted: now().timeIntervalSince(began))
                    await sleep(ReconnectBackoff.delay(afterFailures: failures, jitter: jitter()))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    enum Outcome { case dropped, refused }

    static func connectOnce(
        socket: any RemoteSocket,
        capabilities: @Sendable () async throws -> Void,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        emit: @Sendable (RemoteEvent) -> Void
    ) async -> Outcome {
        defer { socket.cancel() }
        // receive() ignores task cancellation: closing the socket is what ends it.
        return await withTaskCancellationHandler {
            var opened = false
            // The server asks for a KeepAlive every n/2 seconds (ForceKeepAlive n).
            var keepAlive: Task<Void, Never>?
            defer { keepAlive?.cancel() }
            while !Task.isCancelled {
                let data: Data
                do { data = try await socket.receive() } catch {
                    // Jellyfin answers an unknown token on the upgrade with 401 or 403.
                    if !opened, let status = socket.upgradeStatus, status == 401 || status == 403 { return .refused }
                    return .dropped
                }
                // The server speaks first (ForceKeepAlive), so a first message
                // means the upgrade went through. Not "connected" until the
                // server knows what this session can do.
                if !opened {
                    do { try await capabilities() } catch JellyfinError.unauthorized {
                        // A revoked token: retrying won't bring it back.
                        return .refused
                    } catch { return .dropped }
                    opened = true
                    emit(.connected)
                }
                switch RemoteMessage.decode(data) {
                case .command(let command): emit(.command(command))
                case .forceKeepAlive(let seconds):
                    keepAlive?.cancel()
                    keepAlive = Task {
                        while !Task.isCancelled {
                            try? await socket.send(#"{"MessageType":"KeepAlive"}"#)
                            await sleep(Double(seconds) / 2)
                        }
                    }
                case .ignored: break
                }
            }
            return .dropped
        } onCancel: {
            socket.cancel()
        }
    }
}
