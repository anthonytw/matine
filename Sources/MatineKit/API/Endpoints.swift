import Foundation

/// Every server call Matiné makes, checked against Jellyfin 12.4's OpenAPI spec.
extension JellyfinClient {
    /// Fields asked for on list calls: enough for a tile, nothing more.
    static let tileFields = "PrimaryImageAspectRatio,Overview"
    /// The poster, and the backdrop and logo Home shows for the focused tile.
    static let tileImages = "Primary,Backdrop,Logo"

    static func tileQuery(limit: Int, fields: String = tileFields) -> [URLQueryItem] {
        [
            URLQueryItem(name: "fields", value: fields),
            URLQueryItem(name: "enableImageTypes", value: tileImages),
            URLQueryItem(name: "imageTypeLimit", value: "1"),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }

    /// The server's OpenAPI document, for `matine api-check`. Needs no sign-in.
    public func openAPISpec() async throws -> Data {
        try await send("GET", "/api-docs/openapi.json")
    }

    public func publicInfo() async throws -> PublicServerInfo {
        try await get("/System/Info/Public")
    }

    /// Signs in and returns the user plus a fresh access token. The password
    /// is sent once (encrypted only over https) and never stored.
    public func authenticate(username: String, password: String) async throws -> (User, String) {
        struct Body: Encodable, Sendable {
            let Username: String
            let Pw: String
        }
        let data: Data
        do {
            data = try await withToken(nil).send("POST", "/Users/AuthenticateByName", body: Body(Username: username, Pw: password))
        } catch JellyfinError.unauthorized {
            throw JellyfinError.badCredentials
        }
        let result: AuthenticationResult
        do {
            result = try JSONDecoder().decode(AuthenticationResult.self, from: data)
        } catch {
            throw JellyfinError.decoding("/Users/AuthenticateByName: \(error)")
        }
        return (result.user, result.accessToken)
    }

    /// Ends this device's session on the server, so the token stops working.
    public func logout() async throws {
        _ = try await send("POST", "/Sessions/Logout")
    }

    /// The user's libraries, in the order they set in Jellyfin.
    public func libraries(userId: String) async throws -> [Item] {
        let page: ItemsPage = try await get("/UserViews", query: [URLQueryItem(name: "userId", value: userId)])
        return page.items
    }

    /// What the user is partway through: everywhere, or in one library.
    public func resume(userId: String, libraryId: String? = nil, limit: Int = 20) async throws -> [Item] {
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "mediaTypes", value: "Video"),
        ] + Self.tileQuery(limit: limit)
        if let libraryId { query.append(URLQueryItem(name: "parentId", value: libraryId)) }
        let page: ItemsPage = try await get("/UserItems/Resume", query: query)
        return page.items
    }

    /// A random handful of what a library holds, at the watchable level
    /// (episodes, not their series), shuffled by the server: something new
    /// on each visit.
    public func shuffled(userId: String, libraryId: String, limit: Int = 20) async throws -> [Item] {
        let page: ItemsPage = try await get("/Items", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "parentId", value: libraryId),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Episode,Video"),
            URLQueryItem(name: "isMissing", value: "false"),
            URLQueryItem(name: "sortBy", value: "Random"),
        ] + Self.tileQuery(limit: limit))
        return page.items
    }

    public func nextUp(userId: String, seriesId: String? = nil, limit: Int = 20) async throws -> [Item] {
        var query = [URLQueryItem(name: "userId", value: userId)] + Self.tileQuery(limit: limit)
        if let seriesId { query.append(URLQueryItem(name: "seriesId", value: seriesId)) }
        let page: ItemsPage = try await get("/Shows/NextUp", query: query)
        return page.items
    }

    /// Recently added in one library. Jellyfin returns a bare array here, not a page.
    public func latest(userId: String, libraryId: String, limit: Int = 20) async throws -> [Item] {
        let items: [Item] = try await get("/Items/Latest", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "parentId", value: libraryId),
        ] + Self.tileQuery(limit: limit))
        #if DEBUG
        return DebugItemFilter.apply(items)   // -MatineDevOnlyItems (screenshots)
        #else
        return items
        #endif
    }

    /// Pinned items: the user's favorite movies, series and videos, by name.
    public func pinned(userId: String, limit: Int = 50) async throws -> [Item] {
        let page: ItemsPage = try await get("/Items", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "filters", value: "IsFavorite"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Video"),
            URLQueryItem(name: "sortBy", value: "SortName"),
        ] + Self.tileQuery(limit: limit))
        return page.items
    }

    /// Marks an item watched for this user. Only that: no unwatching, no other fields.
    public func setPlayed(itemId: String, userId: String) async throws {
        _ = try await send("POST", "/UserPlayedItems/\(itemId)", query: [URLQueryItem(name: "userId", value: userId)])
    }

    /// Sets where this user resumes. The server updates only the fields sent.
    public func setPlaybackPosition(ticks: Int64, itemId: String, userId: String) async throws {
        _ = try await send("POST", "/UserItems/\(itemId)/UserData", query: [URLQueryItem(name: "userId", value: userId)],
                           body: PlaybackPositionBody(playbackPositionTicks: ticks))
    }

    /// Pins or unpins an item (Jellyfin's favorite flag), per user.
    public func setPinned(_ pinned: Bool, itemId: String, userId: String) async throws {
        _ = try await send(pinned ? "POST" : "DELETE", "/UserFavoriteItems/\(itemId)", query: [
            URLQueryItem(name: "userId", value: userId),
        ])
    }

    /// One page of a library's top level (movies, or series), sorted. The
    /// total is a count query on the server, so it comes only when asked for
    /// (`countTotal`); a short page is what marks the end otherwise.
    public func libraryPage(
        userId: String, libraryId: String, sort: LibrarySort = .title, start: Int = 0, limit: Int = 60,
        countTotal: Bool = false
    ) async throws -> ItemPage {
        let page: ItemsPage = try await get("/Items", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "parentId", value: libraryId),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Video"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: sort.rawValue),
            URLQueryItem(name: "sortOrder", value: sort == .title ? "Ascending" : "Descending"),
            URLQueryItem(name: "startIndex", value: String(start)),
            URLQueryItem(name: "enableTotalRecordCount", value: countTotal ? "true" : "false"),
        ] + Self.tileQuery(limit: limit))
        return ItemPage(items: page.items, total: page.totalRecordCount, start: start, limit: limit)
    }

    /// Everything the profile can watch, for Search's index on the device:
    /// movies, series, episodes and videos, with the text Search matches
    /// (titles in both languages, synopsis, genres, tags, and with
    /// `credits` (slower: the server looks every title's people up) the actors, directors, guest stars and studios) and the
    /// tile fields.
    public func catalog(userId: String, libraryId: String? = nil, limit: Int = 20_000, credits: Bool = false) async throws -> [Item] {
        try Self.decodeCatalog(try await catalogData(userId: userId, libraryId: libraryId, limit: limit, credits: credits))
    }

    /// The catalog's raw answer (the CLI measures it).
    public func catalogData(userId: String, libraryId: String? = nil, limit: Int = 20_000, credits: Bool = false) async throws -> Data {
        let fields = Self.tileFields + ",OriginalTitle,Genres,Tags" + (credits ? ",People,Studios" : "")
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Episode,Video"),
            URLQueryItem(name: "isMissing", value: "false"),
        ] + Self.tileQuery(limit: limit, fields: fields)
        if let libraryId { query.append(URLQueryItem(name: "parentId", value: libraryId)) }
        return try await send("GET", "/Items", query: query)
    }

    /// Items from a catalog answer. Only the credits Search matches are kept
    /// (actors, directors, guest stars), without photos' worth of detail.
    public static func decodeCatalog(_ data: Data) throws -> [Item] {
        do {
            var items = try JSONDecoder().decode(ItemsPage.self, from: data).items
            for index in items.indices {
                items[index].people = items[index].people?.filter(\.isSearched)
            }
            return items
        } catch {
            throw JellyfinError.decoding("/Items: \(error)")
        }
    }

    /// Everything in the library a person is credited on (films, videos,
    /// series and episodes; `Item.grouped(byPerson:)` folds episodes into
    /// their series).
    public func personItems(personId: String, userId: String, limit: Int = 500) async throws -> [Item] {
        let page: ItemsPage = try await get("/Items", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "personIds", value: personId),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series,Episode,Video"),
            URLQueryItem(name: "isMissing", value: "false"),
            URLQueryItem(name: "sortBy", value: "SortName"),
        ] + Self.tileQuery(limit: limit))
        return page.items
    }

    /// Episodes of a series in airing order (no images: just what's needed
    /// to pick one).
    public func episodes(seriesId: String, userId: String, limit: Int? = nil) async throws -> [Item] {
        var query = [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableImages", value: "false"),
            URLQueryItem(name: "isMissing", value: "false"),
        ]
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        let page: ItemsPage = try await get("/Shows/\(seriesId)/Episodes", query: query)
        return page.items
    }

    /// The seasons of a series (specials included, as Jellyfin lists them),
    /// without images: a picker needs only names, numbers and unwatched counts.
    public func seasons(seriesId: String, userId: String) async throws -> [Item] {
        let page: ItemsPage = try await get("/Shows/\(seriesId)/Seasons", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "enableImages", value: "false"),
            URLQueryItem(name: "isMissing", value: "false"),
        ])
        return page.items
    }

    /// One season's episodes as tiles (still image, progress, watched).
    public func seasonEpisodes(seriesId: String, seasonId: String, userId: String, limit: Int = 2_000) async throws -> [Item] {
        let page: ItemsPage = try await get("/Shows/\(seriesId)/Episodes", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "seasonId", value: seasonId),
            URLQueryItem(name: "isMissing", value: "false"),
        ] + Self.tileQuery(limit: limit))
        return page.items
    }

    /// The first unwatched episode of a series, in airing order. Specials
    /// (season 0) sort first, so one is returned only when no episode of a
    /// real season is left unwatched.
    public func firstUnwatchedEpisode(seriesId: String, userId: String) async throws -> Item? {
        let first = try await unwatchedEpisodes(seriesId: seriesId, userId: userId, limit: 1)
        guard let head = first.first, head.seasonNumber == 0 else { return first.first }
        // Specials come first; look past them (a bounded page, never the whole list).
        let more = try await unwatchedEpisodes(seriesId: seriesId, userId: userId, limit: 200)
        return more.first { $0.seasonNumber != 0 } ?? head
    }

    private func unwatchedEpisodes(seriesId: String, userId: String, limit: Int) async throws -> [Item] {
        let page: ItemsPage = try await get("/Items", query: [
            URLQueryItem(name: "userId", value: userId),
            URLQueryItem(name: "parentId", value: seriesId),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "includeItemTypes", value: "Episode"),
            URLQueryItem(name: "filters", value: "IsUnplayed"),
            URLQueryItem(name: "isMissing", value: "false"),
            URLQueryItem(name: "sortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
            URLQueryItem(name: "enableUserData", value: "true"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return page.items
    }

    /// What pressing Play on a series plays: Jellyfin's Next up for it, else
    /// the first unwatched episode, else the first episode. One small call
    /// each, never the whole episode list.
    public func episodeToPlay(seriesId: String, userId: String) async throws -> Item? {
        if let next = try await nextUp(userId: userId, seriesId: seriesId, limit: 1).first { return next }
        if let unwatched = try await firstUnwatchedEpisode(seriesId: seriesId, userId: userId) { return unwatched }
        return try await episodes(seriesId: seriesId, userId: userId, limit: 1).first
    }

    public func item(_ itemId: String, userId: String) async throws -> Item {
        try await get("/Items/\(itemId)", query: [URLQueryItem(name: "userId", value: userId)])
    }

    /// Ids per `/Items?ids=` request: keeps the URL short.
    static let idsBatch = 100

    /// Many items in a few requests (in chunks of `idsBatch`), with the
    /// user's data. An id the server will not show this user is simply absent
    /// from the answer, not an error. Only the tile fields come back: enough
    /// for user data and runtimes, not a whole detail page.
    public func items(ids: [String], userId: String) async throws -> [Item] {
        var found: [Item] = []
        var start = 0
        while start < ids.count {
            let chunk = ids[start..<min(start + Self.idsBatch, ids.count)]
            let page: ItemsPage = try await get("/Items", query: [
                URLQueryItem(name: "userId", value: userId),
                URLQueryItem(name: "ids", value: chunk.joined(separator: ",")),
            ] + Self.tileQuery(limit: chunk.count))
            found += page.items
            start += Self.idsBatch
        }
        return found
    }
}

struct PlaybackPositionBody: Encodable, Sendable {
    let playbackPositionTicks: Int64
    enum CodingKeys: String, CodingKey { case playbackPositionTicks = "PlaybackPositionTicks" }
}

public enum LibrarySort: String, Sendable, CaseIterable {
    case title = "SortName"
    case dateAdded = "DateCreated,SortName"
}
