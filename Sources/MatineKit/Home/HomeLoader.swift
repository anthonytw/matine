import Foundation

public struct HomeRow: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        /// Fijados: the profile's pinned series and movies.
        case pinned
        /// Seguir viendo: what's half watched, then the next episode of each
        /// series under way (as the TV app's Up Next merges the two).
        case continueWatching
        /// Recently added in one library.
        case latest(libraryId: String, libraryName: String)
    }

    public var kind: Kind
    public var items: [Item]

    /// A library's recently added row (as opposed to the viewer's own rows).
    public var isLatest: Bool { if case .latest = kind { true } else { false } }

    public var id: String {
        switch kind {
        case .pinned: "pinned"
        case .continueWatching: "resume"
        case .latest(let libraryId, _): "latest.\(libraryId)"
        }
    }
}

/// The home screen: its rows, and the libraries the app's sidebar lists
/// (the same filtered list the rows came from).
public struct HomeContent: Sendable, Hashable {
    public var rows: [HomeRow]
    public var libraries: [Item]
}

/// Builds the home screen: Seguir viendo, Fijados, then one
/// "recently added" row per library in the user's Jellyfin order. Rows with
/// nothing in them are left out, and so is a row whose call fails: one bad
/// library mustn't blank the screen. Only an expired session (or failing to
/// list the libraries at all) fails the load. Every call runs at once.
/// If every row call fails, the first error is thrown rather than an empty
/// home that claims there is nothing to watch.
public struct HomeLoader: Sendable {
    let client: JellyfinClient
    let userId: String

    /// Libraries that hold watchable things. Music, books, photos and the like
    /// have no row on a TV home screen.
    static let videoLibraryTypes: Set<String?> = ["movies", "tvshows", "homevideos", nil]

    public init(client: JellyfinClient, userId: String) {
        self.client = client
        self.userId = userId
    }

    /// The row's items, or the error if its call failed for any reason but an
    /// expired session (which throws).
    static func row(_ call: () async throws -> [Item]) async throws -> Result<[Item], any Error> {
        do { return .success(try await call()) } catch JellyfinError.unauthorized { throw JellyfinError.unauthorized } catch { return .failure(error) }
    }

    /// Half-watched first; then each next-up episode, unless its series
    /// already has an episode in progress there (or it's the same item).
    static func watching(resume: [Item], nextUp: [Item]) -> [Item] {
        let ids = Set(resume.map(\.id))
        let series = Set(resume.compactMap(\.seriesId))
        return resume + nextUp.filter { !ids.contains($0.id) && !($0.seriesId.map(series.contains) ?? false) }
    }

    public func load() async throws -> HomeContent {
        let client = client, userId = userId
        async let pinned = Self.row { try await client.pinned(userId: userId) }
        async let resume = Self.row { try await client.resume(userId: userId) }
        async let nextUp = Self.row { try await client.nextUp(userId: userId) }
        async let libraries = client.libraries(userId: userId)

        let videoLibraries = try await libraries.filter {
            $0.kind == .collectionFolder && Self.videoLibraryTypes.contains($0.collectionType)
        }
        let latest = try await withThrowingTaskGroup(of: (Int, Result<[Item], any Error>).self) { group in
            for (index, library) in videoLibraries.enumerated() {
                group.addTask { (index, try await Self.row { try await client.latest(userId: userId, libraryId: library.id) }) }
            }
            var byIndex: [Int: Result<[Item], any Error>] = [:]
            for try await (index, result) in group { byIndex[index] = result }
            return byIndex
        }

        var results = [try await pinned, try await resume, try await nextUp]
        results += videoLibraries.indices.map { latest[$0] ?? .success([]) }
        // Every row failing means the server is unwell, not that there is
        // nothing to watch.
        let failures = results.compactMap { result -> (any Error)? in
            if case .failure(let error) = result { return error }
            return nil
        }
        if failures.count == results.count, let first = failures.first { throw first }

        func items(_ result: Result<[Item], any Error>) -> [Item] { (try? result.get()) ?? [] }
        var rows = [
            HomeRow(kind: .continueWatching, items: Self.watching(resume: items(results[1]), nextUp: items(results[2]))),
            HomeRow(kind: .pinned, items: items(results[0])),
        ]
        for (index, library) in videoLibraries.enumerated() {
            rows.append(HomeRow(kind: .latest(libraryId: library.id, libraryName: library.name), items: items(results[3 + index])))
        }
        return HomeContent(rows: rows.filter { !$0.items.isEmpty }, libraries: videoLibraries)
    }
}
