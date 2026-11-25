import Foundation

/// A cloud made on first use: building a CloudKit container needs the app's
/// iCloud entitlement, so nothing is touched until a sync is asked for.
public final class LazyKeywordCloud: KeywordCloud, @unchecked Sendable {
    private let make: @Sendable () -> any KeywordCloud
    private let lock = NSLock()
    private var made: (any KeywordCloud)?

    public init(_ make: @escaping @Sendable () -> any KeywordCloud) { self.make = make }

    private var cloud: any KeywordCloud {
        lock.withLock {
            if let made { return made }
            let new = make()
            made = new
            return new
        }
    }

    public func account() async -> KeywordCloudAccount { await cloud.account() }
    public func fetchChanges() async throws -> KeywordCloudChanges { try await cloud.fetchChanges() }
    public func save(_ records: [KeywordCloudRecord]) async throws -> [String] { try await cloud.save(records) }
    public func reset() async { await cloud.reset() }
    public func accountId() async -> String? { await cloud.accountId() }
}

/// Where the keyword files live, and the server's id (asked once, then
/// remembered by the server's address).
public enum KeywordFiles {
    /// The local store, the cloud cache and the engine's change tokens in
    /// `directory`. The tokens are dropped when the cache is gone (the
    /// system cleared Caches on a TV), so the next sync fetches everything.
    public static func prepare(in directory: URL) -> (local: KeywordStoreFile, remote: KeywordStoreFile, state: URL, shared: KeywordStoreFile, sharedState: URL) {
        // Rebuilt from iCloud, or made again: neither belongs in a device backup.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var directory = directory
        try? directory.setResourceValues(excluded)
        let remote = KeywordStoreFile(url: directory.appending(path: "cloud.json"))
        let state = directory.appending(path: "engine-state.json")
        if !remote.exists { try? FileManager.default.removeItem(at: state) }
        // The shared zone's words and the shared engine's own tokens (a second engine, another database).
        let shared = KeywordStoreFile(url: directory.appending(path: "shared.json"))
        let sharedState = directory.appending(path: "shared-engine-state.json")
        if !shared.exists { try? FileManager.default.removeItem(at: sharedState) }
        return (KeywordStoreFile(url: directory.appending(path: "local.json")), remote, state, shared, sharedState)
    }

    public static func serverId(for server: URL, profiles: Profiles, settings: any KeyValueStore) async -> String? {
        let key = "matine.keywords.server." + server.absoluteString
        if let data = settings.data(forKey: key), let id = String(data: data, encoding: .utf8) { return id }
        guard let info = try? await profiles.anonymousClient(server: server).publicInfo() else { return nil }
        settings.set(Data(info.id.utf8), forKey: key)
        return info.id
    }
}
