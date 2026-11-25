import Foundation

extension JellyfinClient {
    /// The item's parents, nearest first (season, series, folders, the library).
    public func ancestors(of itemId: String, userId: String) async throws -> [Item] {
        try await get("/Items/\(itemId)/Ancestors", query: [URLQueryItem(name: "userId", value: userId)])
    }

    /// The original file. The token is in the Authorization header, never the URL.
    func downloadRequest(itemId: String) -> URLRequest {
        var request = URLRequest(url: url("/Items/\(itemId)/Download"))
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    /// The fallback for a file the server won't direct-play: a Jellyfin remux
    /// into MP4, streams copied where they already play.
    func remuxRequest(itemId: String, mediaSourceId: String) -> URLRequest {
        var request = URLRequest(url: url("/Videos/\(itemId)/stream.mp4", query: [
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "videoCodec", value: AppleTVProfile.videoCodecs),
            URLQueryItem(name: "audioCodec", value: AppleTVProfile.audioCodecs),
            URLQueryItem(name: "allowVideoStreamCopy", value: "true"),
            URLQueryItem(name: "allowAudioStreamCopy", value: "true"),
            URLQueryItem(name: "deviceId", value: identity.deviceId),
        ]))
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }

    /// Whether the server answers at all (no sign-in): the test for "online".
    public func isReachable() async -> Bool {
        (try? await send("GET", "/System/Info/Public")) != nil
    }
}

/// How far an item's download is, for a progress bar.
public struct DownloadUpdate: Sendable, Equatable {
    public var userId: String
    public var itemId: String
    /// Nil: the item was deleted.
    public var state: DownloadedItem.State?
    /// The server's refusal when a download failed with one (401: sign in again).
    public var status: Int? = nil
    /// 0...1, nil when the server didn't say how big the file is.
    public var fraction: Double?
}

final class StoreCache: @unchecked Sendable {
    private let lock = NSLock()
    private var stores: [String: DownloadStore] = [:]

    func forget(_ userId: String) { lock.withLock { stores[userId] = nil } }

    func store(for userId: String, root: URL) -> DownloadStore {
        lock.withLock {
            if let store = stores[userId] { return store }
            let store = DownloadStore(root: root, userId: userId)
            stores[userId] = store
            return store
        }
    }
}

/// Downloads items into profiles' stores. One per app: it owns the transfer
/// engine, so every profile's downloads (and the ones the system finished
/// while the app was suspended) arrive in one place.
///
/// What is downloaded is the original file (`/Items/{id}/Download`): the
/// library is pre-converted to direct-play MP4. Only an item the server says
/// would not direct-play falls back to a Jellyfin remux.
public actor Downloader {
    public static let sessionIdentifier = "io.github.anthonytw.matine.downloads"

    private let root: URL
    private let engine: any DownloadEngine
    private let onUpdate: @Sendable (DownloadUpdate) -> Void
    private let stores = StoreCache()
    private var running: Task<Void, Never>?
    /// Enqueues under way (key `user/item`): asking twice is one transfer.
    private var inFlight: Set<String> = []
    /// Enqueues whose item was deleted before they got going.
    private var abandoned: Set<String> = []
    /// Bumped by "delete all": an enqueue started before it must not land after it.
    private var epochs: [String: Int] = [:]
    /// The last progress tick forwarded per key: the rest are dropped (see `handle`).
    private var lastTick: [String: (fraction: Double?, at: Date)] = [:]
    private let now: @Sendable () -> Date
    /// A tick is forwarded when it moved this much, or this long after the last one.
    static let tickStep = 0.01
    static let tickInterval: TimeInterval = 0.5
    /// Artwork's height: enough for a detail page's backdrop on an iPad.
    static let artHeight = 1080

    /// `onUpdate` hears every state change, and progress ticks at most every 0.5 s or 1% per item (any thread).
    public init(
        root: URL, engine: any DownloadEngine, now: @escaping @Sendable () -> Date = { Date() },
        onUpdate: @escaping @Sendable (DownloadUpdate) -> Void = { _ in }
    ) {
        self.root = root
        self.now = now
        self.engine = engine
        self.onUpdate = onUpdate
    }

    /// Where the engine puts the file for `"<userId>/<itemId>"`.
    public static func destination(root: URL) -> @Sendable (String) -> URL? {
        { key in
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return DownloadStore.fileURL(directory: root.appendingPathComponent(DownloadStore.safe(parts[0]), isDirectory: true), itemId: parts[1])
        }
    }

    /// The profile's store: always the same instance, so every screen and the
    /// transfer events see one manifest.
    public nonisolated func store(for userId: String) -> DownloadStore {
        stores.store(for: userId, root: root)
    }

    static func key(_ userId: String, _ itemId: String) -> String { "\(userId)/\(itemId)" }

    /// Starts reading the engine's events. Call once.
    public func start() {
        guard running == nil else { return }
        let events = engine.events
        running = Task { [weak self] in
            for await event in events { await self?.handle(event) }
        }
    }

    // MARK: Queueing

    /// Downloads one film, video or episode: its metadata, its parents'
    /// metadata, artwork, then the file. Does nothing for an item already
    /// downloaded or on its way.
    public func enqueue(itemId: String, client: JellyfinClient, userId: String) async throws {
        try await enqueue(itemId: itemId, client: client, userId: userId, shared: nil)
    }

    /// What every episode of one season has in common, fetched once.
    struct SeasonParents {
        var parents: [Item]
        var library: Item?
    }

    private func enqueue(itemId: String, client: JellyfinClient, userId: String, shared: SeasonParents?) async throws {
        let store = store(for: userId)
        let key = Self.key(userId, itemId)
        // Whatever way this call ends without starting a transfer, the screens
        // are told what is true, so none is left showing "downloading".
        func report() {
            let entry = store.entry(itemId)
            onUpdate(DownloadUpdate(userId: userId, itemId: itemId, state: entry?.state, fraction: entry?.state == .complete ? 1 : nil))
        }
        if inFlight.contains(key) {
            // Asked again after a delete while the first ask was still under way: let that one go on.
            abandoned.remove(key)
            return
        }
        if let existing = store.entry(itemId), existing.state != .failed {
            report()
            return
        }
        inFlight.insert(key)
        abandoned.remove(key)
        defer { inFlight.remove(key) }
        let epoch = epochs[userId, default: 0]
        /// False once the item was deleted, or the profile's downloads erased, while we were asking the server.
        func wanted() -> Bool { !abandoned.contains(key) && epochs[userId, default: 0] == epoch }

        let item = try await client.item(itemId, userId: userId)
        guard [.movie, .video, .episode].contains(item.kind) else { throw DownloadError.notDownloadable }

        // Series and season for an episode; the library from the ancestors.
        var parents: [Item] = []
        let library: Item?
        if let shared, [item.parentId, item.seriesId].compactMap({ $0 }).allSatisfy({ id in shared.parents.contains { $0.id == id } }) {
            parents = shared.parents
            library = shared.library
        } else {
            if item.kind == .episode {
                if let seasonId = item.parentId { parents.append(try await client.item(seasonId, userId: userId)) }
                if let seriesId = item.seriesId { parents.append(try await client.item(seriesId, userId: userId)) }
            }
            library = try? await client.ancestors(of: itemId, userId: userId).first { $0.kind == .collectionFolder }
        }
        if let library { parents.append(library) }

        // Let Playback's own decision say whether the file plays as it is.
        let plan = try await client.playbackPlan(itemId: itemId, userId: userId, profile: .phone(device: client.identity.deviceName, constrained: false))
        let method: DownloadedItem.Method = plan.method == .directPlay ? .original : .remux

        guard wanted() else { report(); return }
        let entry = DownloadedItem(
            item: item, state: .downloading, method: method, mediaSourceId: plan.mediaSourceId, fileName: nil,
            bytes: 0, addedAt: Date(), touchedAt: nil, libraryId: library?.id, expectedBytes: nil, failure: nil
        )
        try store.begin(entry, parents: parents)
        await fetchArt(for: [item] + parents, client: client, store: store)
        // Deleted while the artwork came: nothing to start.
        guard wanted(), store.entry(itemId) != nil else { report(); return }
        try? FileManager.default.removeItem(at: store.resumeURL(itemId: itemId))
        launch(entry, client: client, userId: userId, resumeData: nil)
        onUpdate(DownloadUpdate(userId: userId, itemId: itemId, state: .downloading, fraction: 0))
    }

    /// Every episode of one season of a series. The season, series and
    /// library are fetched once for all of them. An episode that fails does
    /// not stop the rest: the first such error is thrown at the end (a
    /// refused sign-in or a cancellation stops at once).
    public func enqueueSeason(seriesId: String, seasonId: String, client: JellyfinClient, userId: String) async throws {
        let episodes = try await client.seasonEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
            .filter { $0.kind == .episode }
        guard let first = episodes.first else { return }
        let season = try await client.item(seasonId, userId: userId)
        let series = try await client.item(seriesId, userId: userId)
        let library = try? await client.ancestors(of: first.id, userId: userId).first { $0.kind == .collectionFolder }
        let shared = SeasonParents(parents: [season, series], library: library)
        var firstError: (any Error)?
        for episode in episodes {
            do {
                try await enqueue(itemId: episode.id, client: client, userId: userId, shared: shared)
            } catch is CancellationError {
                throw CancellationError()
            } catch JellyfinError.unauthorized {
                throw JellyfinError.unauthorized
            } catch let error as JellyfinError where error.isConnectivity {
                // The server is gone: asking for every other episode would only wait for each to time out.
                throw error
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func launch(_ entry: DownloadedItem, client: JellyfinClient, userId: String, resumeData: Data?) {
        var request = entry.method == .original
            ? client.downloadRequest(itemId: entry.item.id)
            : client.remuxRequest(itemId: entry.item.id, mediaSourceId: entry.mediaSourceId)
        request.allowsCellularAccess = allowsCellular
        request.allowsExpensiveNetworkAccess = allowsCellular
        engine.start(request, key: Self.key(userId, entry.item.id), resumeData: resumeData)
    }

    /// Cellular downloads are off until the owner turns them on.
    private var allowsCellular = false
    public func setAllowsCellular(_ allowed: Bool) { allowsCellular = allowed }

    /// Picks the profile's unfinished downloads back up: a file that arrived
    /// while the app was gone is simply marked complete; the rest restart (with
    /// what was already fetched when the system kept it), unless a transfer is
    /// alive for them. A download the server refused stays failed until the
    /// owner asks again (`includingRefused`).
    public func resumeAll(client: JellyfinClient, userId: String, includingRefused: Bool = false) async {
        let store = store(for: userId)
        let live = await engine.activeKeys()
        for entry in store.entries() where entry.state != .complete {
            let id = entry.item.id, key = Self.key(userId, id)
            if live.contains(key) || inFlight.contains(key) { continue }
            if entry.state == .failed, entry.failure == .refused, !includingRefused { continue }
            // The engine moves a file into place only when it is whole.
            let file = store.fileURL(itemId: id)
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init),
               size > 0, entry.expectedBytes.map({ $0 == size }) ?? true {
                store.markComplete(id, bytes: size)
                onUpdate(DownloadUpdate(userId: userId, itemId: id, state: .complete, fraction: 1))
                continue
            }
            let data = try? Data(contentsOf: store.resumeURL(itemId: id))
            store.markDownloading(id)
            launch(entry, client: client, userId: userId, resumeData: data)
            onUpdate(DownloadUpdate(userId: userId, itemId: id, state: .downloading, fraction: nil))
        }
    }

    /// Stops a download and deletes whatever came of it.
    public func remove(itemId: String, userId: String) {
        let key = Self.key(userId, itemId)
        if inFlight.contains(key) { abandoned.insert(key) }
        engine.cancel(key: key)
        lastTick[key] = nil
        store(for: userId).remove(itemId)
        onUpdate(DownloadUpdate(userId: userId, itemId: itemId, state: nil, fraction: nil))
    }

    public func removeAll(userId: String) {
        epochs[userId, default: 0] += 1
        let store = store(for: userId)
        for entry in store.entries() { engine.cancel(key: Self.key(userId, entry.item.id)) }
        lastTick = lastTick.filter { !$0.key.hasPrefix(userId + "/") }
        store.removeAll()
    }

    /// Everything of the profile, gone: transfers, files, artwork, manifest,
    /// resume data and the progress queue (sign-out).
    public func erase(userId: String) {
        epochs[userId, default: 0] += 1
        let store = store(for: userId)
        for entry in store.entries() { engine.cancel(key: Self.key(userId, entry.item.id)) }
        lastTick = lastTick.filter { !$0.key.hasPrefix(userId + "/") }
        store.destroy()
        stores.forget(userId)
    }

    // MARK: Events

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .progress(let key, let written, let total):
            guard let (userId, itemId) = Self.split(key) else { return }
            if total > 0 { store(for: userId).setExpectedBytes(itemId, total) }
            let fraction = total > 0 ? Double(written) / Double(total) : nil
            // Many ticks a second would repaint every screen for nothing.
            let time = now()
            if let last = lastTick[key], time >= last.at, time.timeIntervalSince(last.at) < Self.tickInterval {
                let small: Bool
                switch (fraction, last.fraction) {
                case let (new?, old?): small = abs(new - old) < Self.tickStep
                case (nil, nil): small = true
                default: small = false
                }
                if small { return }
            }
            lastTick[key] = (fraction, time)
            onUpdate(DownloadUpdate(userId: userId, itemId: itemId, state: .downloading, fraction: fraction))
        case .finished(let key, let bytes):
            lastTick[key] = nil
            guard let (userId, itemId) = Self.split(key) else { return }
            let store = store(for: userId)
            // Cancelled and deleted while the last bytes were landing: drop the file.
            guard store.entry(itemId) != nil else {
                try? FileManager.default.removeItem(at: store.fileURL(itemId: itemId))
                return
            }
            store.markComplete(itemId, bytes: bytes)
            try? FileManager.default.removeItem(at: store.resumeURL(itemId: itemId))
            onUpdate(DownloadUpdate(userId: userId, itemId: itemId, state: .complete, fraction: 1))
        case .failed(let key, let status, let resumeData):
            lastTick[key] = nil
            guard let (userId, itemId) = Self.split(key) else { return }
            let store = store(for: userId)
            guard store.entry(itemId) != nil else { return }
            // Resume data only helps a transfer a lost connection cut short; a
            // refusal or a bad answer starts over, never from stale bytes.
            if let resumeData, status == nil {
                try? resumeData.write(to: store.resumeURL(itemId: itemId), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else {
                try? FileManager.default.removeItem(at: store.resumeURL(itemId: itemId))
            }
            store.markFailed(itemId, status == nil ? .connection : .refused)
            onUpdate(DownloadUpdate(userId: userId, itemId: itemId, state: .failed, status: status, fraction: nil))
        }
    }

    static func split(_ key: String) -> (String, String)? {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    // MARK: Artwork

    /// Artwork is tokenless and tag-versioned, so a name on disk is never stale.
    private func fetchArt(for items: [Item], client: JellyfinClient, store: DownloadStore) async {
        for item in items {
            for ref in DownloadStore.artwork(of: item) where !store.hasArt(ref) {
                let request = URLRequest(url: client.imageURL(ref, maxHeight: Self.artHeight))
                guard let (data, status) = try? await client.transport.perform(request), (200..<300).contains(status), !data.isEmpty else { continue }
                try? store.saveArt(data, for: ref)
            }
        }
    }
}
