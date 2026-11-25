import Foundation

/// Where a downloaded item was left while the server couldn't be told.
public struct ProgressRecord: Codable, Sendable, Hashable {
    public var itemId: String
    public var positionTicks: Int64
    /// Watched to the end (past 90%): the server is told "played", which also resets its resume point.
    public var played: Bool
    public var at: Date
}

/// Progress made offline, waiting for the server. One record per item, the
/// latest one wins; a record is removed only once the server has it. It only
/// ever marks things played or moves a resume point: nothing it sends can
/// make a watched item unwatched.
public final class ProgressQueue: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var records: [String: ProgressRecord]
    /// Paces the writes of progress made on the device: one per profile, however many sources read through it.
    let writes = WriteThrottle()

    public init(store: DownloadStore) {
        url = store.progressURL
        let saved = (try? Data(contentsOf: url)).flatMap { try? DownloadStore.decoder.decode([ProgressRecord].self, from: $0) } ?? []
        records = Dictionary(saved.map { ($0.itemId, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var pending: [ProgressRecord] {
        lock.withLock { records.values.sorted { $0.at < $1.at } }
    }

    /// Replaces the item's record: the newest position wins.
    public func record(itemId: String, positionTicks: Int64, played: Bool, at: Date = Date()) {
        lock.withLock {
            // A position never undoes "played" that is still waiting to be sent.
            let wasPlayed = records[itemId]?.played == true
            records[itemId] = ProgressRecord(
                itemId: itemId, positionTicks: played || wasPlayed ? 0 : positionTicks, played: played || wasPlayed, at: at
            )
            save()
        }
    }

    private func save() {
        try? DownloadStore.encoder.encode(Array(records.values)).write(to: url, options: .atomic)
    }

    private func clear(_ record: ProgressRecord) {
        lock.withLock {
            // Only if nothing newer arrived while it was being sent.
            if records[record.itemId] == record { records[record.itemId] = nil; save() }
        }
    }

    /// Sends what is waiting, oldest first. A watched mark always goes. A
    /// resume point goes only if it is still news: not for something the
    /// server already has watched, not if another device played it since
    /// (the server's last-played time is later than ours, beyond clock skew),
    /// and not for the first few percent (Jellyfin's own minimum). A refusal
    /// of that one record (a 4xx other than 401/408/429, an item the server
    /// no longer has) drops it so it can't hold up the rest; connection
    /// trouble and server errors stop the flush and leave everything queued.
    /// Returns how many reached the server.
    @discardableResult
    public func flush(client: JellyfinClient, userId: String) async throws -> Int {
        var sent = 0
        let records = pending
        // One request for everything whose resume point is to be checked.
        var known: [String: Item] = [:]
        let toCheck = records.filter { !$0.played }.map(\.itemId)
        if !toCheck.isEmpty {
            do {
                known = Dictionary(try await client.items(ids: toCheck, userId: userId).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch let error as JellyfinError where error.isConnectivity || error == .unauthorized {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Not answered in a batch: each record asks for its own item below.
            }
        }
        for record in records {
            do {
                if record.played {
                    try await client.setPlayed(itemId: record.itemId, userId: userId)
                } else {
                    let server: Item
                    if let batched = known[record.itemId] { server = batched } else { server = try await client.item(record.itemId, userId: userId) }
                    if Self.isStale(record, server: server) { clear(record); continue }
                    try await client.setPlaybackPosition(ticks: record.positionTicks, itemId: record.itemId, userId: userId)
                }
                sent += 1
                clear(record)
            } catch JellyfinError.http(status: let status) where Self.refusesOnlyThisRecord(status) {
                clear(record)
            }
        }
        return sent
    }

    static let clockSkew: TimeInterval = 120

    static func isStale(_ record: ProgressRecord, server: Item) -> Bool {
        if server.userData?.played == true { return true }
        if let last = server.userData?.lastPlayedAt, last > record.at.addingTimeInterval(clockSkew) { return true }
        if let run = server.runTimeTicks, run > 0, Double(record.positionTicks) < Double(run) * DownloadStore.minResumeFraction { return true }
        return false
    }

    static func refusesOnlyThisRecord(_ status: Int) -> Bool {
        (400..<500).contains(status) && ![401, 408, 429].contains(status)
    }
}

extension JellyfinError {
    /// The URLError codes that mean "no usable connection". Anything else
    /// (a cancelled request above all, a bad certificate, a malformed URL) is not.
    static let connectivityCodes: Set<Int> = Set([
        URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff,
    ].map(\.rawValue))

    /// The server could not be reached or is not answering: the cue for the offline mirror.
    public var isConnectivity: Bool {
        switch self {
        case .transport(let code): Self.connectivityCodes.contains(code)
        case .http(let status): [0, 502, 503, 504].contains(status)
        default: false
        }
    }
}

/// What reconnecting does: send the progress made offline, then take the
/// server's current progress and pins for everything downloaded. A download
/// the server now refuses (removed, or hidden by a tightened rating or library
/// access: 403/404) is deleted from the device, and `removed` hears of it so
/// its transfer can stop.
public enum DownloadSync {
    @discardableResult
    public static func run(
        store: DownloadStore, queue: ProgressQueue, client: JellyfinClient, removed: @Sendable (String) -> Void = { _ in }
    ) async throws -> Int {
        let sent = try await queue.flush(client: client, userId: store.userId)
        // Skip anything still waiting (a failed send would be overwritten by older server state).
        let waiting = Set(queue.pending.map(\.itemId))
        let manifest = store.snapshot()
        let ids = Set(manifest.items.keys).union(manifest.parents.keys).subtracting(waiting).sorted()
        // A few batched requests; what the server leaves out is asked for one by
        // one, so a hiccup in the batch never deletes anything by itself.
        var fresh: [Item] = []
        var missing = ids
        do {
            fresh = try await client.items(ids: ids, userId: store.userId)
            let got = Set(fresh.map(\.id))
            missing = ids.filter { !got.contains($0) }
        } catch let error as JellyfinError where error.isConnectivity || error == .unauthorized {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The batch failed: fall back to one request per item.
        }
        for id in missing {
            do {
                fresh.append(try await client.item(id, userId: store.userId))
            } catch JellyfinError.http(status: let status) where [403, 404].contains(status) {
                if manifest.items[id] != nil {
                    removed(id)
                    store.remove(id)
                }
            } catch let error as JellyfinError where error.isConnectivity || error == .unauthorized {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        store.refresh(items: fresh)
        return sent
    }
}
