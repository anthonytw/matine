import Foundation

/// Where a signed-in profile's library comes from. Every screen of the phone
/// and tablet app reads through this and nothing else, so the same menus,
/// rows, artwork and search can later be served from a store on the device
/// (the offline mirror: only what was downloaded) instead of the server.
///
/// Today's one implementation is `ServerLibrarySource`. A local one answers
/// the same questions from its own files: `home()` rows built from what is
/// downloaded, `imageURL` returning `file://` URLs, `playbackPlan` pointing
/// at the downloaded file (with `streamHeaders` empty), and `catalog()` being
/// only the downloaded titles, so Search needs no change at all.
public protocol LibrarySource: PlaybackReporting {
    /// The profile this source answers for (Jellyfin's user id).
    var userId: String { get }

    /// The home screen: its rows, and the libraries the app's sidebar lists.
    func home() async throws -> HomeContent
    /// The video libraries, in the user's order.
    func libraries() async throws -> [Item]
    /// One page of a library's top level (movies or series), sorted.
    func libraryPage(libraryId: String, sort: LibrarySort, start: Int, limit: Int, countTotal: Bool) async throws -> ItemPage
    /// One item, for a detail page or a deep link.
    func item(_ itemId: String) async throws -> Item
    /// The seasons of a series, without images.
    func seasons(seriesId: String) async throws -> [Item]
    /// One season's episodes as tiles.
    func episodes(seriesId: String, seasonId: String) async throws -> [Item]
    /// What Play on a series plays: next up, else the first unwatched, else the first.
    func episodeToPlay(seriesId: String) async throws -> Item?
    /// Everything the profile can watch here, for Search's index on the device.
    func catalog() async throws -> [Item]
    /// Pins or unpins an item (Jellyfin's favorite flag).
    func setPinned(_ pinned: Bool, itemId: String) async throws

    /// A ready-to-play stream for `itemId`. `allowDirectPlay: false` asks for
    /// the server's HLS (the retry when the player refused the file).
    /// `constrained` (a metered connection) asks for a lighter stream.
    func playbackPlan(itemId: String, startTicks: Int64, allowDirectPlay: Bool, constrained: Bool) async throws -> PlaybackPlan
    /// Headers the player sends on every request for a plan's URL. The token
    /// travels here, never in the URL. Empty for a local file.
    var streamHeaders: [String: String] { get }

    /// Artwork. Carries no token: safe for an image loader and its cache.
    func imageURL(_ ref: ImageRef, maxHeight: Int) -> URL
}

extension LibrarySource {
    public func playbackPlan(itemId: String, startTicks: Int64, allowDirectPlay: Bool) async throws -> PlaybackPlan {
        try await playbackPlan(itemId: itemId, startTicks: startTicks, allowDirectPlay: allowDirectPlay, constrained: false)
    }
}

/// Tells wherever playback is tracked how far it got (the server, now).
public protocol PlaybackReporting: Sendable {
    func reportStart(_ report: PlaybackReport) async throws
    func reportProgress(_ report: PlaybackReport) async throws
    func reportStopped(_ report: PlaybackReport) async throws
}

extension JellyfinClient: PlaybackReporting {}

/// The Jellyfin server as a `LibrarySource`: each question is one of
/// `JellyfinClient`'s calls, for one user.
public struct ServerLibrarySource: LibrarySource {
    public let client: JellyfinClient
    public let userId: String
    /// "iPhone" or "iPad": the device a phone's profile is named for, and
    /// lighter than the TV's. Nil is the Apple TV's profile.
    public let device: String?

    public init(client: JellyfinClient, userId: String, device: String? = nil) {
        self.client = client
        self.userId = userId
        self.device = device
    }

    public func home() async throws -> HomeContent {
        try await HomeLoader(client: client, userId: userId).load()
    }

    public func libraries() async throws -> [Item] {
        try await client.libraries(userId: userId).filter {
            $0.kind == .collectionFolder && HomeLoader.videoLibraryTypes.contains($0.collectionType)
        }
    }

    public func libraryPage(libraryId: String, sort: LibrarySort, start: Int, limit: Int, countTotal: Bool) async throws -> ItemPage {
        try await client.libraryPage(userId: userId, libraryId: libraryId, sort: sort, start: start, limit: limit, countTotal: countTotal)
    }

    public func item(_ itemId: String) async throws -> Item {
        try await client.item(itemId, userId: userId)
    }

    public func seasons(seriesId: String) async throws -> [Item] {
        try await client.seasons(seriesId: seriesId, userId: userId)
    }

    public func episodes(seriesId: String, seasonId: String) async throws -> [Item] {
        try await client.seasonEpisodes(seriesId: seriesId, seasonId: seasonId, userId: userId)
    }

    public func episodeToPlay(seriesId: String) async throws -> Item? {
        try await client.episodeToPlay(seriesId: seriesId, userId: userId)
    }

    public func catalog() async throws -> [Item] {
        try await client.catalog(userId: userId)
    }

    public func setPinned(_ pinned: Bool, itemId: String) async throws {
        try await client.setPinned(pinned, itemId: itemId, userId: userId)
    }

    public func playbackPlan(itemId: String, startTicks: Int64, allowDirectPlay: Bool, constrained: Bool) async throws -> PlaybackPlan {
        let profile = device.map { PlaybackProfile.phone(device: $0, constrained: constrained) } ?? .appleTV
        return try await client.playbackPlan(itemId: itemId, userId: userId, startTicks: startTicks, allowDirectPlay: allowDirectPlay, profile: profile)
    }

    public var streamHeaders: [String: String] { client.streamHeaders }

    public func imageURL(_ ref: ImageRef, maxHeight: Int) -> URL {
        client.imageURL(ref, maxHeight: maxHeight)
    }

    public func reportStart(_ report: PlaybackReport) async throws { try await client.reportStart(report) }
    public func reportProgress(_ report: PlaybackReport) async throws { try await client.reportProgress(report) }
    public func reportStopped(_ report: PlaybackReport) async throws { try await client.reportStopped(report) }
}
