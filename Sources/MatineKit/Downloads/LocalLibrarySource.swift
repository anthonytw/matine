import Foundation

/// The offline mirror: the library as the profile's downloads make it. The
/// same questions as the server's, answered from the files on the device.
///
/// Rules: a library is listed if anything in it is downloaded; a series
/// shows only its downloaded episodes, a season only if one of its episodes
/// is downloaded. Items keep the server's metadata and artwork, and so do
/// their parents. Anything still downloading is not listed.
public struct LocalLibrarySource: LibrarySource {
    public let store: DownloadStore
    public let queue: ProgressQueue
    var throttle: WriteThrottle { queue.writes }
    public var userId: String { store.userId }

    public init(store: DownloadStore, queue: ProgressQueue) {
        self.store = store
        self.queue = queue
    }

    public enum Unavailable: Error, Equatable, Sendable {
        /// Asked for something that isn't on this device (or needs the server).
        case notDownloaded
        case needsServer
    }

    // MARK: The mirror's contents

    /// A consistent view of what is downloaded, for one answer.
    struct Snapshot {
        var entries: [DownloadedItem]
        var parents: [String: Item]
        var byId: [String: DownloadedItem]

        init(_ manifest: DownloadManifest) {
            entries = manifest.complete
            parents = manifest.parents
            byId = Dictionary(uniqueKeysWithValues: entries.map { ($0.item.id, $0) })
        }

        func episodes(ofSeries id: String) -> [DownloadedItem] {
            entries.filter { $0.item.kind == .episode && $0.item.seriesId == id }
        }

        func episodes(ofSeason id: String) -> [DownloadedItem] {
            entries.filter { $0.item.kind == .episode && $0.item.parentId == id }
        }

        /// Airing order, specials last (as Play on a series treats them).
        static func airing(_ list: [DownloadedItem]) -> [DownloadedItem] {
            list.sorted {
                let a = ($0.item.seasonNumber ?? 1) == 0 ? Int.max : ($0.item.seasonNumber ?? 1)
                let b = ($1.item.seasonNumber ?? 1) == 0 ? Int.max : ($1.item.seasonNumber ?? 1)
                if a != b { return a < b }
                return ($0.item.episodeNumber ?? 0, $0.item.name) < ($1.item.episodeNumber ?? 0, $1.item.name)
            }
        }

        /// Series that have at least one downloaded episode, with the unwatched count.
        func series() -> [Item] {
            let ids = Set(entries.compactMap { $0.item.kind == .episode ? $0.item.seriesId : nil })
            return ids.compactMap { id in parents[id].map { seriesTile($0) } }
        }

        func seriesTile(_ series: Item) -> Item {
            var tile = series
            var data = tile.userData ?? UserData()
            data.unplayedItemCount = episodes(ofSeries: series.id).filter { $0.item.userData?.played != true }.count
            tile.userData = data
            return tile
        }

        func seasonTile(_ season: Item) -> Item {
            var tile = season
            var data = tile.userData ?? UserData()
            data.unplayedItemCount = episodes(ofSeason: season.id).filter { $0.item.userData?.played != true }.count
            tile.userData = data
            return tile
        }

        func library(of series: Item) -> String? {
            episodes(ofSeries: series.id).first?.libraryId
        }

        /// The top level of a library: films and videos in it, and series with a downloaded episode in it.
        func topLevel(libraryId: String) -> [(item: Item, added: Date)] {
            var found: [(Item, Date)] = []
            for entry in entries where [.movie, .video].contains(entry.item.kind) && entry.libraryId == libraryId {
                found.append((entry.item, entry.addedAt))
            }
            for series in series() {
                let inside = episodes(ofSeries: series.id).filter { $0.libraryId == libraryId }
                if let added = inside.map(\.addedAt).max() { found.append((series, added)) }
            }
            return found
        }

        func libraries() -> [Item] {
            let ids = Set(entries.compactMap(\.libraryId))
            return ids.compactMap { parents[$0] }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    func view() -> Snapshot { Snapshot(store.snapshot()) }

    static func sortKey(_ item: Item) -> String {
        item.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// True when the item's file is on the device and complete.
    public func isDownloaded(_ itemId: String) -> Bool { store.playableFile(itemId) != nil }

    // MARK: LibrarySource

    public func home() async throws -> HomeContent {
        let view = view()
        let libraries = view.libraries()
        var rows: [HomeRow] = []

        // Seguir viendo: half-watched first (most recent), then the next
        // downloaded episode of each series under way.
        let playable = view.entries.filter { [.movie, .video, .episode].contains($0.item.kind) }
        let halfWatched = playable
            .filter { $0.item.userData?.played != true && ($0.item.userData?.playbackPositionTicks ?? 0) > 0 }
            .sorted { ($0.touchedAt ?? $0.addedAt) > ($1.touchedAt ?? $1.addedAt) }
            .map(\.item)
        var nextUp: [Item] = []
        for series in view.series() {
            let episodes = Snapshot.airing(view.episodes(ofSeries: series.id))
            guard episodes.contains(where: { $0.item.userData?.played == true }),
                  let next = episodes.first(where: { $0.item.userData?.played != true }) else { continue }
            nextUp.append(next.item)
        }
        rows.append(HomeRow(kind: .continueWatching, items: HomeLoader.watching(resume: halfWatched, nextUp: nextUp)))

        let pinned = (playable.filter { $0.item.kind != .episode }.map(\.item) + view.series())
            .filter { $0.userData?.isFavorite == true }
            .sorted { Self.sortKey($0) < Self.sortKey($1) }
        rows.append(HomeRow(kind: .pinned, items: pinned))

        for library in libraries {
            let latest = view.topLevel(libraryId: library.id).sorted { $0.added > $1.added }.prefix(20).map(\.item)
            rows.append(HomeRow(kind: .latest(libraryId: library.id, libraryName: library.name), items: Array(latest)))
        }
        return HomeContent(rows: rows.filter { !$0.items.isEmpty }, libraries: libraries)
    }

    public func libraries() async throws -> [Item] { view().libraries() }

    public func libraryPage(libraryId: String, sort: LibrarySort, start: Int, limit: Int, countTotal: Bool) async throws -> ItemPage {
        let all = view().topLevel(libraryId: libraryId)
        let ordered: [Item]
        switch sort {
        case .title: ordered = all.map(\.item).sorted { Self.sortKey($0) < Self.sortKey($1) }
        case .dateAdded: ordered = all.sorted { $0.added > $1.added }.map(\.item)
        }
        let page = ordered.dropFirst(max(start, 0)).prefix(max(limit, 0))
        return ItemPage(items: Array(page), total: countTotal ? ordered.count : nil, start: start, limit: limit)
    }

    public func item(_ itemId: String) async throws -> Item {
        let view = view()
        if let entry = view.byId[itemId] { return entry.item }
        guard let parent = view.parents[itemId] else { throw Unavailable.notDownloaded }
        switch parent.kind {
        case .series where !view.episodes(ofSeries: itemId).isEmpty: return view.seriesTile(parent)
        case .season where !view.episodes(ofSeason: itemId).isEmpty: return view.seasonTile(parent)
        case .collectionFolder where view.libraries().contains(where: { $0.id == itemId }): return parent
        default: throw Unavailable.notDownloaded
        }
    }

    public func seasons(seriesId: String) async throws -> [Item] {
        let view = view()
        let seasons = Set(view.episodes(ofSeries: seriesId).compactMap(\.item.parentId)).compactMap { view.parents[$0] }
        return seasons.map(view.seasonTile).sorted { ($0.seasonIndex ?? 0) < ($1.seasonIndex ?? 0) }
    }

    public func episodes(seriesId: String, seasonId: String) async throws -> [Item] {
        Snapshot.airing(view().episodes(ofSeason: seasonId).filter { $0.item.seriesId == seriesId }).map(\.item)
    }

    public func episodeToPlay(seriesId: String) async throws -> Item? {
        let episodes = Snapshot.airing(view().episodes(ofSeries: seriesId)).map(\.item)
        let halfWatched = episodes.first { ($0.userData?.playbackPositionTicks ?? 0) > 0 && $0.userData?.played != true }
        return halfWatched ?? episodes.first { $0.userData?.played != true } ?? episodes.first
    }

    public func catalog() async throws -> [Item] {
        let view = view()
        return view.entries.map(\.item) + view.series()
    }

    public func setPinned(_ pinned: Bool, itemId: String) async throws {
        throw Unavailable.needsServer
    }

    public func playbackPlan(itemId: String, startTicks: Int64, allowDirectPlay: Bool, constrained: Bool) async throws -> PlaybackPlan {
        guard let url = store.playableFile(itemId), let entry = store.entry(itemId) else { throw Unavailable.notDownloaded }
        return PlaybackPlan(
            itemId: itemId, mediaSourceId: entry.mediaSourceId, playSessionId: nil, method: .directPlay, url: url, startTicks: startTicks
        )
    }

    /// Nothing to send: the file is local.
    public var streamHeaders: [String: String] { [:] }

    /// The stored artwork's file; a path that isn't there for art we don't have (the view shows its title card).
    public func imageURL(_ ref: ImageRef, maxHeight: Int) -> URL { store.artURL(ref) }

    // MARK: Progress made on the device

    public func reportStart(_ report: PlaybackReport) async throws {}

    public func reportProgress(_ report: PlaybackReport) async throws {
        record(report.ItemId, report.PositionTicks, final: report.IsPaused)
    }

    public func reportStopped(_ report: PlaybackReport) async throws {
        record(report.ItemId, report.PositionTicks, final: true)
    }

    /// Keeps the position in the mirror and queues it for the server. Each
    /// write rewrites the manifest, so while playing it is done about once a
    /// minute per item; a pause or the end always writes.
    func record(_ itemId: String, _ ticks: Int64, final: Bool = true) {
        guard throttle.due(itemId, ticks: ticks, force: final) else { return }
        guard store.entry(itemId) != nil else { return }
        let finished = store.applyProgress(itemId: itemId, positionTicks: ticks)
        queue.record(itemId: itemId, positionTicks: ticks, played: finished)
    }
}

/// Lets a progress write through at most once per `interval` per item, unless
/// forced, and never twice for the same position (a paused player reports
/// the same ticks every few seconds).
final class WriteThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: (at: Date, ticks: Int64)] = [:]
    let interval: TimeInterval

    init(interval: TimeInterval = 60) { self.interval = interval }

    func due(_ itemId: String, ticks: Int64, force: Bool, now: Date = Date()) -> Bool {
        lock.withLock {
            if let before = last[itemId] {
                if before.ticks == ticks { return false }
                if !force, now >= before.at, now.timeIntervalSince(before.at) < interval { return false }
            }
            last[itemId] = (now, ticks)
            return true
        }
    }
}
