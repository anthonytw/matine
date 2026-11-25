import CryptoKit
import Foundation

/// Keywords between devices through iCloud. The phone makes them (Apple's
/// model), the TV only reads. One record per item in the owner's private
/// database; a record holds the words, the text hash, the generator and when
/// it was made, and nothing about who watched what.

/// A record's name: a hash of the server's id and the item's id, so no title
/// or user name ever appears in CloudKit's names. Keywords belong to the
/// server's item, not to a profile.
public enum KeywordRecordName {
    public static func make(serverId: String, itemId: String) -> String {
        let digest = SHA256.hash(data: Data((serverId + "\u{0}" + itemId).utf8))
        return "k" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public struct KeywordCloudRecord: Sendable, Equatable {
    public var name: String
    public var keywords: ItemKeywords
    public init(name: String, keywords: ItemKeywords) {
        self.name = name
        self.keywords = keywords
    }
}

public struct KeywordCloudChanges: Sendable, Equatable {
    public var saved: [KeywordCloudRecord]
    public var deleted: [String]
    /// The cloud's copy was started over (zone deleted, another Apple ID):
    /// forget everything held from it before applying `saved`.
    public var reset: Bool
    /// It was another Apple ID (signed out, switched): what this device made
    /// under the old one is not sent to the new one.
    public var accountChanged: Bool
    public init(saved: [KeywordCloudRecord] = [], deleted: [String] = [], reset: Bool = false, accountChanged: Bool = false) {
        self.saved = saved
        self.deleted = deleted
        self.reset = reset || accountChanged
        self.accountChanged = accountChanged
    }
}

public enum KeywordCloudAccount: Sendable, Equatable {
    case available
    /// Signed out of iCloud: nothing of the old account is shown or kept.
    case noAccount
    /// Restricted or temporarily unreachable: what is cached stays.
    case unavailable(String)
}

/// What the sync needs from CloudKit; the real one is `CloudKitKeywordCloud`,
/// tests use a fake.
public protocol KeywordCloud: Sendable {
    func account() async -> KeywordCloudAccount
    /// Fetches what changed since last time (the cloud object keeps its own
    /// change tokens) and returns it.
    func fetchChanges() async throws -> KeywordCloudChanges
    /// Sends the records and returns the names CloudKit confirmed. Records it
    /// refused (schema not deployed, quota, zone missing, a conflict) are
    /// simply absent, to be sent again by a later sync; a record changed
    /// elsewhere meanwhile comes back through the next `fetchChanges`.
    func save(_ records: [KeywordCloudRecord]) async throws -> [String]
    /// Forgets the change tokens and anything waiting: the next fetch starts over.
    func reset() async
    /// Who is signed in (the iCloud user record's name), nil if unknown. Local
    /// words are stamped with it, so another Apple ID never receives them.
    func accountId() async -> String?
}

/// Whether this Apple ID has accepted a share of someone else's keywords.
public enum KeywordShareState: Sendable, Equatable {
    /// No shared Keywords zone in this Apple ID's shared database (never accepted, or the owner stopped).
    case none
    /// A shared Keywords zone is there: its words are read, and what this device makes goes into it.
    case participant
}

/// The shared database's side of the keywords: the owner's "Keywords" zone as a
/// participant sees it. Records are named and shaped as in the private zone, so
/// `fetchChanges`/`save` mean the same; a `reset` in the changes means the
/// zone went (the owner stopped sharing, or this person left).
public protocol SharedKeywordCloud: KeywordCloud {
    /// Throws when it can't be told (no network): the sync then changes nothing about sharing.
    func shareState() async throws -> KeywordShareState
}

/// A keyword store on disk: owner-only, and for the phone not readable
/// before first unlock.
public struct KeywordStoreFile: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() -> KeywordStore {
        (try? Data(contentsOf: url)).flatMap { try? KeywordStore(data: $0) } ?? KeywordStore()
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    public func save(_ store: KeywordStore) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try store.data().write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Merges what the cloud holds with what this device made, and sends what
/// the cloud lacks. `reader` (the TV) never sends.
///
/// With a `shared` cloud there are up to three sources per title: this
/// device's own, the private zone's and a shared zone's; the best entry wins
/// (`ItemKeywords.wins`). While a share is accepted a writer sends only to the
/// shared zone (the owner's devices get it from their own private database, so
/// one copy serves both households) and no longer to its own private zone,
/// which it still reads. When the share goes, the words it had brought are
/// folded into the device's own and travel to the private zone from then on.
public actor KeywordSync {
    public enum Role: Sendable { case writer, reader }

    public struct Report: Sendable, Equatable {
        public var received = 0
        public var sent = 0
        public var unavailable: String?
        /// What search shows may differ now (cloud entries arrived, went or were cleared).
        public var changed = false
        /// A share was accepted during this sync (words were read from, and sent to, the shared zone).
        public var participating = false
        /// The share went away during this sync; its words were kept (a writer) as this device's own.
        public var shareEnded = false
    }

    private let cloud: any KeywordCloud
    private let role: Role
    private let localFile: KeywordStoreFile
    private let remoteFile: KeywordStoreFile
    private let shared: (any SharedKeywordCloud)?
    private let sharedFile: KeywordStoreFile?
    /// Made on this device, by item id.
    private var local: KeywordStore
    /// What the cloud holds, by record name.
    private var remote: KeywordStore
    /// What the shared zone holds, by record name (empty without a share).
    private var sharedRemote: KeywordStore

    /// `localFile` is the phone's own store (by item id); `remoteFile` caches
    /// the cloud's (by record name) so the TV needs no network to search.
    public init(
        cloud: any KeywordCloud, role: Role, localFile: KeywordStoreFile, remoteFile: KeywordStoreFile,
        shared: (any SharedKeywordCloud)? = nil, sharedFile: KeywordStoreFile? = nil
    ) {
        self.cloud = cloud
        self.role = role
        self.localFile = localFile
        self.remoteFile = remoteFile
        self.shared = sharedFile == nil ? nil : shared
        self.sharedFile = sharedFile
        local = role == .writer ? localFile.load() : KeywordStore()
        remote = remoteFile.load()
        sharedRemote = sharedFile?.load() ?? KeywordStore()
    }

    /// Both stores for `items` as one by item id, the better entry of each
    /// pair winning (`ItemKeywords.wins`).
    public func resolved(items: [Item], serverId: String) -> KeywordStore {
        var out = KeywordStore()
        for item in items where KeywordBuilder.wantsKeywords(item) {
            let current = KeywordSource(item: item).hash
            let name = KeywordRecordName.make(serverId: serverId, itemId: item.id)
            // This device's first: on a tie it stays.
            var best = local.keywords(for: item.id)
            for challenger in [remote.keywords(for: name), sharedRemote.keywords(for: name)] {
                guard let challenger else { continue }
                if let held = best, !challenger.wins(over: held, currentHash: current) { continue }
                best = challenger
            }
            if let best { out.set(item.id, best) }
        }
        return out
    }

    /// How many of `items` that want keywords have them made from their
    /// current text.
    public func progress(items: [Item], serverId: String) -> (have: Int, of: Int) {
        let wanted = items.filter(KeywordBuilder.wantsKeywords)
        let view = resolved(items: wanted, serverId: serverId)
        return (wanted.filter { view.isFresh($0) }.count, wanted.count)
    }

    /// Takes the cloud's changes, then (writer) sends what is better here
    /// than there, repeating while a conflict brings something back.
    public func sync(items: [Item], serverId: String) async -> Report {
        var report = Report()
        switch await cloud.account() {
        case .available:
            if let id = await cloud.accountId(), claim(account: id) { report.changed = true }
        case .noAccount:
            // Signed out: the old account's words must not keep feeding search, and the
            // engine must fetch everything again for whoever signs in next.
            await cloud.reset()
            if let shared { await shared.reset() }
            if remote.count > 0 || sharedRemote.count > 0 {
                remote = KeywordStore()
                sharedRemote = KeywordStore()
                try? remoteFile.save(remote)
                try? sharedFile?.save(sharedRemote)
                report.changed = true
            }
            report.unavailable = "signed out of iCloud"
            return report
        case .unavailable(let why):
            report.unavailable = why
            return report
        }
        // Is a share accepted? nil: can't be told now, so nothing is written anywhere
        // (a participant must not start writing to her own zone because of a bad connection).
        var sharing: Bool? = false
        if let shared {
            do { sharing = try await shared.shareState() == .participant } catch { sharing = sharedRemote.count > 0 ? nil : false }
            if sharing == false, sharedRemote.count > 0 {
                // The owner stopped sharing (or she left): keep what came, as this device's own.
                await shared.reset()
                endShare(items: items, serverId: serverId)
                report.changed = true
                report.shareEnded = true
            }
        }
        report.participating = sharing == true
        do {
            for _ in 0..<3 {
                let changes = try await cloud.fetchChanges()
                if apply(changes) { report.changed = true }
                report.received += changes.saved.count
                if sharing == true, let shared {
                    do {
                        let changes = try await shared.fetchChanges()
                        let ended = changes.reset && !changes.accountChanged
                        if applyShared(changes, items: items, serverId: serverId) { report.changed = true }
                        if ended { await shared.reset(); sharing = false; report.shareEnded = true; report.participating = false }
                        report.received += changes.saved.count
                    } catch {
                        report.unavailable = "\(error)"
                        sharing = nil
                    }
                }
                guard role == .writer, !Task.isCancelled, let sharing else { break }
                // Where this device's words go: the shared zone while a share is accepted, else its own.
                let target = sharing ? sharedRemote : remote
                let outgoing = outgoing(items: items, serverId: serverId, against: target)
                if outgoing.isEmpty { break }
                // Only what CloudKit confirmed counts as sent: the rest goes again next time.
                let destination: any KeywordCloud = sharing ? shared ?? cloud : cloud
                let confirmed = Set(try await destination.save(outgoing))
                for record in outgoing where confirmed.contains(record.name) {
                    if sharing { sharedRemote.set(record.name, record.keywords) } else { remote.set(record.name, record.keywords) }
                }
                report.sent += confirmed.count
                if confirmed.isEmpty { break }
            }
        } catch {
            report.unavailable = "\(error)"
        }
        try? remoteFile.save(remote)
        if shared != nil { try? sharedFile?.save(sharedRemote) }
        return report
    }

    /// The share is over: a writer keeps the words it brought (for the titles in `items`) as its own,
    /// so they reach the private zone; a reader (the TV) just forgets them.
    private func endShare(items: [Item], serverId: String) {
        guard sharedRemote.count > 0 else { return }
        if role == .writer {
            var changed = false
            for item in items {
                guard let theirs = sharedRemote.keywords(for: KeywordRecordName.make(serverId: serverId, itemId: item.id)) else { continue }
                if let held = local.keywords(for: item.id), !theirs.wins(over: held, currentHash: KeywordSource(item: item).hash) { continue }
                local.set(item.id, theirs)
                changed = true
            }
            if changed { try? localFile.save(local) }
        }
        sharedRemote = KeywordStore()
        try? sharedFile?.save(sharedRemote)
    }

    /// True when the cache changed.
    func applyShared(_ changes: KeywordCloudChanges, items: [Item], serverId: String) -> Bool {
        let before = sharedRemote
        if changes.accountChanged {
            sharedRemote = KeywordStore()
        } else if changes.reset {
            endShare(items: items, serverId: serverId)
        }
        for record in changes.saved { sharedRemote.set(record.name, record.keywords) }
        if !changes.deleted.isEmpty {
            let gone = Set(changes.deleted)
            sharedRemote.prune(keeping: Set(sharedRemote.entries.keys).subtracting(gone))
        }
        return sharedRemote != before
    }

    /// Adopts a store a generator filled (the resolved view, plus new
    /// entries); saved at once, sent by the next `sync`.
    public func adopt(_ store: KeywordStore) {
        guard role == .writer else { return }
        for (id, entry) in store.entries {
            if let held = local.keywords(for: id), !entry.wins(over: held) { continue }
            local.set(id, entry)
        }
        try? localFile.save(local)
    }

    /// Adopts just the entries a run made (not the whole resolved view, which
    /// would copy every cloud entry into the phone's own file); saved once.
    public func adopt(_ made: [(id: String, keywords: ItemKeywords)]) {
        guard role == .writer, !made.isEmpty else { return }
        for (id, entry) in made {
            if let held = local.keywords(for: id), !entry.wins(over: held) { continue }
            local.set(id, entry)
        }
        try? localFile.save(local)
    }

    /// Where the signed-in account's id is kept next to the local store.
    private var stampURL: URL { localFile.url.appendingPathExtension("account") }

    /// Notes whose iCloud this device's words were made under. A different
    /// account than last time (signing out, opening the app and signing in as
    /// someone else raises no switch event) drops the phone's own words and the
    /// old cache: they are never sent to the new account. The same account
    /// signing out and in again keeps them. True when the cache was cleared.
    func claim(account id: String) -> Bool {
        let known = (try? String(contentsOf: stampURL, encoding: .utf8))
        guard known != id else { return false }
        try? FileManager.default.createDirectory(at: stampURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.write(to: stampURL, atomically: true, encoding: .utf8)
        // First run with a stamp: the words so far are this account's.
        guard known != nil else { return false }
        let hadCache = remote.count > 0 || sharedRemote.count > 0
        remote = KeywordStore()
        try? remoteFile.save(remote)
        if sharedRemote.count > 0 {
            sharedRemote = KeywordStore()
            try? sharedFile?.save(sharedRemote)
        }
        if role == .writer, local.count > 0 {
            local = KeywordStore()
            try? localFile.save(local)
        }
        return hadCache
    }

    /// True when the cache changed.
    @discardableResult
    func apply(_ changes: KeywordCloudChanges) -> Bool {
        let before = remote
        if changes.reset { remote = KeywordStore() }
        // Another Apple ID: what this phone made under the old one stays out of the new
        // one (it is made again, a little at a time). A zone someone deleted is different:
        // the phone's own entries are sent again.
        if changes.accountChanged, role == .writer, local.count > 0 {
            local = KeywordStore()
            try? localFile.save(local)
        }
        for record in changes.saved { remote.set(record.name, record.keywords) }
        if !changes.deleted.isEmpty {
            let gone = Set(changes.deleted)
            remote.prune(keeping: Set(remote.entries.keys).subtracting(gone))
        }
        return remote != before
    }

    func outgoing(items: [Item], serverId: String, against store: KeywordStore? = nil) -> [KeywordCloudRecord] {
        let remote = store ?? self.remote
        var out: [KeywordCloudRecord] = []
        for item in items {
            guard let mine = local.keywords(for: item.id) else { continue }
            let name = KeywordRecordName.make(serverId: serverId, itemId: item.id)
            if let theirs = remote.keywords(for: name), !mine.wins(over: theirs, currentHash: KeywordSource(item: item).hash) { continue }
            out.append(KeywordCloudRecord(name: name, keywords: mine))
        }
        return out
    }
}
