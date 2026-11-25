import Foundation

/// One item on the device: its metadata as the server sent it, where its
/// file is, and how far the download got.
public struct DownloadedItem: Codable, Sendable, Hashable {
    public enum State: String, Codable, Sendable { case downloading, complete, failed }
    /// How the file was fetched: the original (the library's files are
    /// pre-converted to direct-play MP4), or a Jellyfin remux for anything
    /// the server said would not direct-play.
    public enum Method: String, Codable, Sendable { case original, remux }

    public var item: Item
    public var state: State
    public var method: Method
    /// The server's media source id, so progress reports name a real source.
    public var mediaSourceId: String
    /// File name inside the profile's `files/` folder, once the download is complete.
    public var fileName: String?
    public var bytes: Int64
    public var addedAt: Date
    /// When progress was last changed here (Seguir viendo orders by it).
    public var touchedAt: Date?
    /// The library (collection folder) the item sits in, if the server told us.
    public var libraryId: String?
    /// The size the server announced, so a file found on disk after a
    /// relaunch can be told from a partial one.
    public var expectedBytes: Int64?
    /// Why a failed download stopped: a lost connection is retried by
    /// itself, a refusal waits for the owner's "Reintentar".
    public var failure: Failure?

    public enum Failure: String, Codable, Sendable { case connection, refused }
}

/// Everything a profile has on the device. Parents (series, season, library)
/// are kept only while some downloaded item still sits under them.
struct DownloadManifest: Codable, Sendable {
    var version = 1
    var items: [String: DownloadedItem] = [:]
    var parents: [String: Item] = [:]

    var complete: [DownloadedItem] { items.values.filter { $0.state == .complete } }

    /// The parent ids some entry (in any state) still needs.
    var referencedParents: Set<String> {
        var ids: Set<String> = []
        for entry in items.values {
            if let id = entry.item.seriesId { ids.insert(id) }
            if entry.item.kind == .episode, let id = entry.item.parentId { ids.insert(id) }
            if let id = entry.libraryId { ids.insert(id) }
        }
        return ids
    }

    /// Every artwork file the entries and their parents show.
    var referencedArt: Set<String> {
        var names: Set<String> = []
        let shown = items.values.map(\.item) + parents.values
        for item in shown {
            for ref in DownloadStore.artwork(of: item) { names.insert(DownloadStore.artName(ref)) }
        }
        return names
    }
}

public enum DownloadError: Error, Equatable, Sendable {
    /// Only films, videos and episodes download (a series downloads by its episodes).
    case notDownloadable
    case notDownloaded
    case offline
}

/// A profile's downloads on disk, in Application Support (never iCloud
/// backup, readable after the first unlock): a manifest of items and parents,
/// artwork, and the media files. One folder per profile, so a kid profile
/// can only ever see its own. Every change is saved at once, atomically.
public final class DownloadStore: @unchecked Sendable {
    public let userId: String
    public let directory: URL
    private let lock = NSLock()
    private var cache: DownloadManifest?

    /// Application Support/Downloads: where the app keeps every profile's folder.
    public static func defaultRoot() -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// Ids are the server's GUIDs; anything else is flattened so an id can never leave the folder.
    static func safe(_ id: String) -> String {
        String(id.unicodeScalars.map { $0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-" ? Character($0) : "_" })
    }

    public init(root: URL, userId: String) {
        self.userId = userId
        directory = root.appendingPathComponent(Self.safe(userId), isDirectory: true)
        for folder in [filesDirectory, artDirectory, resumeDirectory] {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folder = directory
        try? folder.setResourceValues(excluded)
        // Resume data holds the request, token included: out of backups on its own account.
        var resume = resumeDirectory
        try? resume.setResourceValues(excluded)
        // Set on the folder, and again on each media file as it is moved in (see `protect`).
        Self.protect(directory)
    }

    /// Readable after the first unlock, not before.
    static func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    }

    var filesDirectory: URL { directory.appendingPathComponent("files", isDirectory: true) }
    var artDirectory: URL { directory.appendingPathComponent("art", isDirectory: true) }
    var resumeDirectory: URL { directory.appendingPathComponent("resume", isDirectory: true) }
    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    var progressURL: URL { directory.appendingPathComponent("progress.json") }

    public func fileURL(itemId: String) -> URL { Self.fileURL(directory: directory, itemId: itemId) }
    static func fileURL(directory: URL, itemId: String) -> URL {
        directory.appendingPathComponent("files", isDirectory: true).appendingPathComponent(safe(itemId) + ".mp4")
    }
    func resumeURL(itemId: String) -> URL { resumeDirectory.appendingPathComponent(Self.safe(itemId)) }

    // MARK: Artwork

    /// What a tile or page shows for an item: poster, still, backdrop, logo.
    static func artwork(of item: Item) -> [ImageRef] {
        var refs: [ImageRef] = []
        for ref in [item.posterImage, item.ownPrimaryImage, item.wideImage, item.backdropImage, item.logoImage] {
            if let ref, !refs.contains(ref) { refs.append(ref) }
        }
        return refs
    }

    static func artName(_ ref: ImageRef) -> String { "\(safe(ref.itemId))_\(ref.kind.rawValue)_\(safe(ref.tag)).jpg" }
    func artURL(_ ref: ImageRef) -> URL { artDirectory.appendingPathComponent(Self.artName(ref)) }
    /// The artwork names on disk, read once: views ask for every tile on every redraw.
    private var artNames: Set<String>?
    private let artLock = NSLock()

    private func withArtNames<T>(_ body: (inout Set<String>) -> T) -> T {
        artLock.withLock {
            var names = artNames ?? Set(((try? FileManager.default.contentsOfDirectory(at: artDirectory, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent))
            defer { artNames = names }
            return body(&names)
        }
    }

    public func hasArt(_ ref: ImageRef) -> Bool {
        let name = Self.artName(ref)
        return withArtNames { $0.contains(name) }
    }

    func saveArt(_ data: Data, for ref: ImageRef) throws {
        try data.write(to: artURL(ref), options: .atomic)
        let name = Self.artName(ref)
        withArtNames { _ = $0.insert(name) }
    }

    /// Deletes artwork files and forgets their names.
    private func deleteArt(_ urls: [URL]) {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        let names = Set(urls.map(\.lastPathComponent))
        withArtNames { $0.subtract(names) }
    }

    // MARK: Manifest

    func snapshot() -> DownloadManifest {
        lock.withLock { load() }
    }

    private func load() -> DownloadManifest {
        if let cache { return cache }
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? Self.decoder.decode(DownloadManifest.self, from: $0) } ?? DownloadManifest()
        cache = manifest
        return manifest
    }

    // Built once; the encoder and decoder are only used to encode and decode.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// Changes the manifest and saves it before returning. When the save
    /// fails (a full disk), the change is undone in memory too and the error
    /// thrown, so memory and disk never disagree.
    @discardableResult
    func update<T>(_ change: (inout DownloadManifest) -> T) throws -> T {
        try lock.withLock {
            let previous = load()
            var manifest = previous
            let result = change(&manifest)
            do {
                try Self.encoder.encode(manifest).write(to: manifestURL, options: .atomic)
            } catch {
                cache = previous
                throw error
            }
            cache = manifest
            return result
        }
    }

    // MARK: Queries

    public func entry(_ itemId: String) -> DownloadedItem? { snapshot().items[itemId] }

    /// The item's file, when its download is complete.
    public func playableFile(_ itemId: String) -> URL? {
        guard let entry = entry(itemId), entry.state == .complete else { return nil }
        let url = fileURL(itemId: itemId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Every item here, newest first, whatever its state.
    public func entries() -> [DownloadedItem] {
        snapshot().items.values.sorted { $0.addedAt > $1.addedAt }
    }

    /// Bytes on disk: media files, artwork and manifests.
    public func bytesUsed() -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    // MARK: Changes

    /// Records an item (and its parents) as downloading.
    func begin(_ entry: DownloadedItem, parents: [Item]) throws {
        try update { manifest in
            manifest.items[entry.item.id] = entry
            for parent in parents { manifest.parents[parent.id] = parent }
        }
    }

    func markComplete(_ itemId: String, bytes: Int64) {
        try? update { manifest in
            guard var entry = manifest.items[itemId] else { return }
            entry.state = .complete
            entry.bytes = bytes
            entry.fileName = Self.safe(itemId) + ".mp4"
            entry.failure = nil
            manifest.items[itemId] = entry
        }
    }

    func markFailed(_ itemId: String, _ failure: DownloadedItem.Failure) {
        try? update { manifest in
            guard var entry = manifest.items[itemId], entry.state != .complete else { return }
            entry.state = .failed
            entry.failure = failure
            manifest.items[itemId] = entry
        }
    }

    func markDownloading(_ itemId: String) {
        try? update { manifest in
            guard var entry = manifest.items[itemId], entry.state == .failed else { return }
            entry.state = .downloading
            entry.failure = nil
            manifest.items[itemId] = entry
        }
    }

    /// Updates what the server says about the watcher's progress and pins
    /// (called after sync): items, series, seasons and libraries alike.
    func refresh(items: [Item]) {
        try? update { manifest in
            for item in items {
                if manifest.items[item.id] != nil { manifest.items[item.id]?.item.userData = item.userData }
                if manifest.parents[item.id] != nil { manifest.parents[item.id]?.userData = item.userData }
            }
        }
    }

    /// Notes progress made on the device: the position, and watched once past
    /// 90% (as Jellyfin counts it). Never clears a watched mark.
    @discardableResult
    func applyProgress(itemId: String, positionTicks: Int64, at: Date = Date()) -> Bool {
        (try? update { manifest in
            guard var entry = manifest.items[itemId] else { return false }
            var data = entry.item.userData ?? UserData()
            let run = entry.item.runTimeTicks ?? 0
            let finished = run > 0 && Double(positionTicks) >= Double(run) * Self.watchedFraction
            if finished {
                data.played = true
                data.playbackPositionTicks = 0
                data.playedPercentage = nil
            } else if run > 0, Double(positionTicks) < Double(run) * Self.minResumeFraction {
                // Too early to resume from (Jellyfin's own minimum): no resume point.
                data.playbackPositionTicks = 0
                data.playedPercentage = nil
            } else {
                data.playbackPositionTicks = positionTicks
                data.playedPercentage = run > 0 ? Double(positionTicks) / Double(run) * 100 : nil
            }
            entry.item.userData = data
            entry.touchedAt = at
            manifest.items[itemId] = entry
            return finished
        }) ?? false
    }

    static let watchedFraction = 0.9
    /// Below this share of the runtime there is nothing to resume.
    static let minResumeFraction = 0.05

    /// Notes the size the server announced for the download.
    func setExpectedBytes(_ itemId: String, _ bytes: Int64) {
        guard entry(itemId)?.expectedBytes == nil else { return }
        try? update { manifest in manifest.items[itemId]?.expectedBytes = bytes }
    }

    /// Deletes one item: its file, then any parent and artwork nothing else uses.
    public func remove(_ itemId: String) {
        // Artwork goes only once the manifest without it is saved.
        if let strays = try? update({ manifest -> [URL] in
            manifest.items[itemId] = nil
            return prune(&manifest)
        }) { deleteArt(strays) }
        for url in [fileURL(itemId: itemId), resumeURL(itemId: itemId)] { try? FileManager.default.removeItem(at: url) }
    }

    /// Deletes every download of the profile (not its queued progress: that
    /// still has to reach the server).
    public func removeAll() {
        try? update { manifest in manifest = DownloadManifest() }
        for folder in [filesDirectory, artDirectory, resumeDirectory] {
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                try? FileManager.default.removeItem(at: url)
            }
        }
        withArtNames { $0 = [] }
    }

    /// Drops parents no entry needs; returns the artwork files no one shows
    /// any more, for the caller to delete once the manifest is saved.
    private func prune(_ manifest: inout DownloadManifest) -> [URL] {
        let needed = manifest.referencedParents
        for id in manifest.parents.keys where !needed.contains(id) { manifest.parents[id] = nil }
        let keep = manifest.referencedArt
        return ((try? FileManager.default.contentsOfDirectory(at: artDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { !keep.contains($0.lastPathComponent) }
    }

    /// Forgets every saved resume point. Resume data carries the request it
    /// was made with, token included: after a new sign-in it would be refused.
    public func clearResumeData() {
        for url in (try? FileManager.default.contentsOfDirectory(at: resumeDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes the profile's whole folder: media, artwork, resume data, the
    /// manifest and the progress queue (sign-out). This store is unusable
    /// afterwards; ask for a new one.
    public func destroy() {
        lock.withLock {
            cache = DownloadManifest()
            try? FileManager.default.removeItem(at: directory)
        }
        withArtNames { $0 = [] }
    }
}
