import Foundation
import MatineKit
import Observation

/// The Apple TV can't run the on-device models, so it only reads the search
/// keywords a phone made, from the owner's private iCloud database. The
/// keywords are cached in Caches (the system may clear them: the next sync
/// fetches them again). Signed out of iCloud, or on another Apple ID than the
/// phone: no keywords, and search works as before.
@MainActor @Observable
final class KeywordsModel {
    /// Bumped when iCloud brought something: search rebuilds its index.
    private(set) var version = 0

    @ObservationIgnored private let sync: KeywordSync
    @ObservationIgnored private let settings: any KeyValueStore
    @ObservationIgnored private var running = false

    init(settings: any KeyValueStore = UserDefaults.standard) {
        self.settings = settings
        let base = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory).appending(path: "Keywords")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let files = KeywordFiles.prepare(in: base)
        // Built now: it registers with the shared engine before the household does (see PrivateCloudEngine).
        let cloud = CloudKitKeywordCloud(stateURL: files.state, writer: false)
        // A share accepted on this Apple ID's iPhone shows up in its shared database too: read it (read-only,
        // as ever). The TV can't accept a share link itself.
        let shared = CloudKitSharedKeywordCloud(stateURL: files.sharedState, writer: false)
        sync = KeywordSync(cloud: cloud, role: .reader, localFile: files.local, remoteFile: files.remote, shared: shared, sharedFile: files.shared)
    }

    /// What search uses for `items`: the cached keywords, no network.
    func store(for items: [Item], account: Account, profiles: Profiles) async -> KeywordStore {
        guard let serverId = await KeywordFiles.serverId(for: account.server, profiles: profiles, settings: settings) else { return KeywordStore() }
        return await sync.resolved(items: items, serverId: serverId)
    }

    /// Fetches what changed in iCloud.
    func refresh(account: Account, items: [Item], profiles: Profiles) async {
        guard !running, let serverId = await KeywordFiles.serverId(for: account.server, profiles: profiles, settings: settings) else { return }
        running = true
        defer { running = false }
        let report = await sync.sync(items: items, serverId: serverId)
        // A reset or a sign-out changes what search shows even when nothing arrived.
        if report.changed { version += 1 }
    }
}
