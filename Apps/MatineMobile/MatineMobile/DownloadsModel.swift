import Foundation
import MatineKit
import Observation

/// What the screens know about downloads: each item's state and progress,
/// and the actions (download, cancel, delete). The work is MatineKit's
/// `Downloader`; this only mirrors its updates for SwiftUI.
@MainActor @Observable
final class DownloadsModel {
    struct Status: Equatable {
        var state: DownloadedItem.State
        var fraction: Double?
    }

    static let cellularKey = "downloadsCellular"

    let downloader: Downloader
    let engine: URLSessionDownloadEngine
    /// Told when a download was refused with 401: that profile has to sign in again.
    var onSessionExpired: (@MainActor (String) -> Void)?
    private let root = DownloadStore.defaultRoot()
    private(set) var statuses: [String: Status] = [:]
    /// Bumped when something finished or was deleted: screens that list downloads reload on it.
    private(set) var changes = 0
    /// Set when a download could not even start (no connection, the server said no).
    var problem = false
    private(set) var allowsCellular = UserDefaults.standard.bool(forKey: DownloadsModel.cellularKey)
    private var queues: [String: ProgressQueue] = [:]

    init() {
        let (stream, updates) = AsyncStream.makeStream(of: DownloadUpdate.self, bufferingPolicy: .unbounded)
        let root = root
        let engine = URLSessionDownloadEngine.background(identifier: Downloader.sessionIdentifier, destination: Downloader.destination(root: root))
        self.engine = engine
        downloader = Downloader(root: root, engine: engine, onUpdate: { updates.yield($0) })
        let allowed = allowsCellular
        Task { [downloader] in
            await downloader.setAllowsCellular(allowed)
            await downloader.start()
        }
        Task { [weak self] in
            for await update in stream { self?.apply(update) }
        }
    }

    private static func key(_ userId: String, _ itemId: String) -> String { "\(userId)/\(itemId)" }

    private func apply(_ update: DownloadUpdate) {
        let key = Self.key(update.userId, update.itemId)
        if update.status == 401 { onSessionExpired?(update.userId) }
        guard let state = update.state else {
            statuses[key] = nil
            changes += 1
            return
        }
        let status = Status(state: state, fraction: update.fraction)
        if let old = statuses[key], old.state == state {
            // A tick that barely moved repaints every screen that reads any status: skip it.
            switch (old.fraction, status.fraction) {
            case let (before?, after?) where abs(after - before) < 0.01 && after < 1: return
            case (nil, nil): return
            default: break
            }
        }
        if statuses[key]?.state != state { changes += 1 }
        statuses[key] = status
    }

    func store(for userId: String) -> DownloadStore { downloader.store(for: userId) }

    func queue(for userId: String) -> ProgressQueue {
        if let queue = queues[userId] { return queue }
        let queue = ProgressQueue(store: store(for: userId))
        queues[userId] = queue
        return queue
    }

    /// Reads what is on disk for the profile (a launch, a profile opened).
    func load(userId: String) {
        for entry in store(for: userId).entries() {
            let key = Self.key(userId, entry.item.id)
            if statuses[key] == nil { statuses[key] = Status(state: entry.state, fraction: entry.state == .complete ? 1 : nil) }
        }
        changes += 1
    }

    func status(_ itemId: String, userId: String) -> Status? { statuses[Self.key(userId, itemId)] }

    func setAllowsCellular(_ allowed: Bool) {
        UserDefaults.standard.set(allowed, forKey: Self.cellularKey)
        allowsCellular = allowed
        Task { [downloader] in await downloader.setAllowsCellular(allowed) }
    }

    // MARK: Actions

    func download(_ item: Item, client: JellyfinClient, userId: String) {
        statuses[Self.key(userId, item.id)] = Status(state: .downloading, fraction: 0)
        Task {
            do {
                try await downloader.enqueue(itemId: item.id, client: client, userId: userId)
            } catch {
                statuses[Self.key(userId, item.id)] = nil
                if (error as? JellyfinError) == .unauthorized { onSessionExpired?(userId) } else { problem = true }
            }
        }
    }

    func downloadSeason(seriesId: String, seasonId: String, episodes: [Item], client: JellyfinClient, userId: String) {
        for episode in episodes where status(episode.id, userId: userId) == nil {
            statuses[Self.key(userId, episode.id)] = Status(state: .downloading, fraction: 0)
        }
        Task {
            do {
                try await downloader.enqueueSeason(seriesId: seriesId, seasonId: seasonId, client: client, userId: userId)
            } catch {
                for episode in episodes where statuses[Self.key(userId, episode.id)]?.state == .downloading && store(for: userId).entry(episode.id) == nil {
                    statuses[Self.key(userId, episode.id)] = nil
                }
                if (error as? JellyfinError) == .unauthorized { onSessionExpired?(userId) } else { problem = true }
            }
        }
    }

    func retry(client: JellyfinClient, userId: String) {
        Task { await downloader.resumeAll(client: client, userId: userId, includingRefused: true) }
    }

    func remove(_ itemId: String, userId: String) {
        statuses[Self.key(userId, itemId)] = nil
        changes += 1
        Task { await downloader.remove(itemId: itemId, userId: userId) }
    }

    func removeAll(userId: String) {
        for key in statuses.keys where key.hasPrefix(userId + "/") { statuses[key] = nil }
        changes += 1
        Task { await downloader.removeAll(userId: userId) }
    }

    /// Forgets a profile's downloads along with the profile (sign out): files,
    /// manifest, resume data and the progress queue, the whole folder.
    func forget(userId: String) async {
        for key in statuses.keys where key.hasPrefix(userId + "/") { statuses[key] = nil }
        queues[userId] = nil
        changes += 1
        await downloader.erase(userId: userId)
    }
}
