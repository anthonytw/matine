import Foundation

/// Whether the server can be reached right now. The hybrid source flips it
/// to offline when a call fails for lack of a connection; the app flips it
/// back after a probe succeeds (and when the system says the network is gone).
public final class ConnectionState: @unchecked Sendable {
    private let lock = NSLock()
    private var offline: Bool
    private var observer: (@Sendable (Bool) -> Void)?

    public init(offline: Bool = false) { self.offline = offline }

    public var isOffline: Bool { lock.withLock { offline } }

    /// Called (on any thread) whenever the state changes.
    public func onChange(_ observer: @escaping @Sendable (Bool) -> Void) {
        lock.withLock { self.observer = observer }
    }

    public func set(offline new: Bool) {
        let (changed, observer) = lock.withLock { () -> (Bool, (@Sendable (Bool) -> Void)?) in
            defer { offline = new }
            return (offline != new, self.observer)
        }
        if changed { observer?(new) }
    }
}

/// What the phone app reads through: the server when it answers, the offline
/// mirror when it doesn't (decided call by call, so a dropped connection
/// switches the screens over by itself). A downloaded item always plays from
/// the device's file, online or not, and its progress goes to the server when
/// it can, else waits in the queue.
public struct HybridLibrarySource: LibrarySource {
    public let server: ServerLibrarySource
    public let local: LocalLibrarySource
    public let connection: ConnectionState
    public var userId: String { server.userId }

    public init(server: ServerLibrarySource, local: LocalLibrarySource, connection: ConnectionState) {
        self.server = server
        self.local = local
        self.connection = connection
    }

    /// The server's answer, or the mirror's when the server can't be reached.
    private func read<T>(_ fromServer: () async throws -> T, _ fromMirror: () async throws -> T) async throws -> T {
        if connection.isOffline { return try await fromMirror() }
        do {
            return try await fromServer()
        } catch let error as JellyfinError where error.isConnectivity && !Task.isCancelled {
            connection.set(offline: true)
            return try await fromMirror()
        }
    }

    public func home() async throws -> HomeContent {
        try await read({ try await server.home() }, { try await local.home() })
    }

    public func libraries() async throws -> [Item] {
        try await read({ try await server.libraries() }, { try await local.libraries() })
    }

    public func libraryPage(libraryId: String, sort: LibrarySort, start: Int, limit: Int, countTotal: Bool) async throws -> ItemPage {
        try await read(
            { try await server.libraryPage(libraryId: libraryId, sort: sort, start: start, limit: limit, countTotal: countTotal) },
            { try await local.libraryPage(libraryId: libraryId, sort: sort, start: start, limit: limit, countTotal: countTotal) }
        )
    }

    public func item(_ itemId: String) async throws -> Item {
        try await read({ try await server.item(itemId) }, { try await local.item(itemId) })
    }

    public func seasons(seriesId: String) async throws -> [Item] {
        try await read({ try await server.seasons(seriesId: seriesId) }, { try await local.seasons(seriesId: seriesId) })
    }

    public func episodes(seriesId: String, seasonId: String) async throws -> [Item] {
        try await read(
            { try await server.episodes(seriesId: seriesId, seasonId: seasonId) },
            { try await local.episodes(seriesId: seriesId, seasonId: seasonId) }
        )
    }

    public func episodeToPlay(seriesId: String) async throws -> Item? {
        try await read({ try await server.episodeToPlay(seriesId: seriesId) }, { try await local.episodeToPlay(seriesId: seriesId) })
    }

    public func catalog() async throws -> [Item] {
        try await read({ try await server.catalog() }, { try await local.catalog() })
    }

    public func setPinned(_ pinned: Bool, itemId: String) async throws {
        try await server.setPinned(pinned, itemId: itemId)
    }

    public func playbackPlan(itemId: String, startTicks: Int64, allowDirectPlay: Bool, constrained: Bool) async throws -> PlaybackPlan {
        if local.isDownloaded(itemId) {
            return try await local.playbackPlan(itemId: itemId, startTicks: startTicks, allowDirectPlay: allowDirectPlay, constrained: constrained)
        }
        return try await server.playbackPlan(itemId: itemId, startTicks: startTicks, allowDirectPlay: allowDirectPlay, constrained: constrained)
    }

    public var streamHeaders: [String: String] { server.streamHeaders }

    /// Downloaded artwork first (no network, the same picture: the tag is in its name).
    public func imageURL(_ ref: ImageRef, maxHeight: Int) -> URL {
        local.store.hasArt(ref) ? local.imageURL(ref, maxHeight: maxHeight) : server.imageURL(ref, maxHeight: maxHeight)
    }

    // MARK: Reports

    public func reportStart(_ report: PlaybackReport) async throws {
        guard local.isDownloaded(report.ItemId) else { return try await server.reportStart(report) }
        if !connection.isOffline { try? await server.reportStart(report) }
    }

    public func reportProgress(_ report: PlaybackReport) async throws {
        guard local.isDownloaded(report.ItemId) else { return try await server.reportProgress(report) }
        try await reportLocal(report, final: report.IsPaused) { try await server.reportProgress($0) }
    }

    public func reportStopped(_ report: PlaybackReport) async throws {
        guard local.isDownloaded(report.ItemId) else { return try await server.reportStopped(report) }
        try await reportLocal(report, final: true) { try await server.reportStopped($0) }
    }

    /// A downloaded item's report: kept in the mirror always; sent to the
    /// server if it answers, else queued for when it does.
    private func reportLocal(_ report: PlaybackReport, final: Bool, send: (PlaybackReport) async throws -> Void) async throws {
        if !connection.isOffline {
            do {
                try await send(report)
                if local.throttle.due(report.ItemId, ticks: report.PositionTicks, force: final) {
                    local.store.applyProgress(itemId: report.ItemId, positionTicks: report.PositionTicks)
                }
                return
            } catch let error as JellyfinError where error.isConnectivity && !Task.isCancelled {
                connection.set(offline: true)
            } catch {
                // The server refused (an expired session, say): keep it for later too.
            }
        }
        local.record(report.ItemId, report.PositionTicks, final: final)
    }
}
