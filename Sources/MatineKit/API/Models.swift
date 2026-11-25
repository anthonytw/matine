import Foundation

/// The kinds of item Matiné shows. Jellyfin has many more; anything else
/// decodes as `.other` and is left out of rows.
public enum ItemKind: Sendable, Hashable, Codable {
    case movie, series, season, episode, video, folder, collectionFolder, boxSet
    case other(String)

    init(raw: String) {
        switch raw {
        case "Movie": self = .movie
        case "Series": self = .series
        case "Season": self = .season
        case "Episode": self = .episode
        case "Video": self = .video
        case "Folder": self = .folder
        case "CollectionFolder": self = .collectionFolder
        case "BoxSet": self = .boxSet
        default: self = .other(raw)
        }
    }

    var raw: String {
        switch self {
        case .movie: "Movie"
        case .series: "Series"
        case .season: "Season"
        case .episode: "Episode"
        case .video: "Video"
        case .folder: "Folder"
        case .collectionFolder: "CollectionFolder"
        case .boxSet: "BoxSet"
        case .other(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// The per-user state Jellyfin keeps on an item.
public struct UserData: Codable, Sendable, Hashable {
    public var played: Bool?
    public var isFavorite: Bool?
    public var playedPercentage: Double?
    public var playbackPositionTicks: Int64?
    public var unplayedItemCount: Int?
    /// When this user last played it, as the server writes it (ISO 8601).
    public var lastPlayedDate: String?

    /// `lastPlayedDate` as a date, nil when absent or unreadable.
    public var lastPlayedAt: Date? {
        guard let lastPlayedDate else { return nil }
        return (try? Date(lastPlayedDate, strategy: Self.fractionalDate)) ?? (try? Date(lastPlayedDate, strategy: Self.wholeDate))
    }

    private static let fractionalDate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeDate = Date.ISO8601FormatStyle()

    public init(played: Bool? = nil, isFavorite: Bool? = nil, playedPercentage: Double? = nil,
                playbackPositionTicks: Int64? = nil, unplayedItemCount: Int? = nil, lastPlayedDate: String? = nil) {
        self.lastPlayedDate = lastPlayedDate
        self.played = played
        self.isFavorite = isFavorite
        self.playedPercentage = playedPercentage
        self.playbackPositionTicks = playbackPositionTicks
        self.unplayedItemCount = unplayedItemCount
    }

    enum CodingKeys: String, CodingKey {
        case played = "Played"
        case isFavorite = "IsFavorite"
        case playedPercentage = "PlayedPercentage"
        case playbackPositionTicks = "PlaybackPositionTicks"
        case unplayedItemCount = "UnplayedItemCount"
        case lastPlayedDate = "LastPlayedDate"
    }
}

/// A subset of Jellyfin's `BaseItemDto` (155 fields): only what the screens use.
public struct Item: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var kind: ItemKind
    public var seriesId: String?
    /// The item's parent on the server: an episode's season, a season's series.
    public var parentId: String?
    public var seriesName: String?
    public var seasonNumber: Int?
    public var episodeNumber: Int?
    public var productionYear: Int?
    public var overview: String?
    /// The title in its own language (an English film's English title) when
    /// the server's metadata language renamed it; Search matches both.
    public var originalTitle: String?
    public var genres: [String]?
    /// Free keywords set in Jellyfin's metadata editor: Search matches them,
    /// so a parent can add words in either language ("snake", "serpiente").
    public var tags: [String]?
    public var runTimeTicks: Int64?
    public var collectionType: String?
    public var primaryAspectRatio: Double?
    public var imageTags: [String: String]?
    public var backdropImageTags: [String]?
    public var seriesPrimaryImageTag: String?
    public var parentBackdropItemId: String?
    public var parentBackdropImageTags: [String]?
    public var parentLogoItemId: String?
    public var parentLogoImageTag: String?
    /// BlurHashes by image type, then by image tag (`Item.blurHash(for:)`).
    public var imageBlurHashes: [String: [String: String]]?
    public var userData: UserData?
    /// Credits, studio and ratings: only on a detail fetch and the Search
    /// catalog (`Item.people` there keeps just actors, directors and guest
    /// stars). Nil on a title with no metadata (homemade videos, YouTube).
    public var people: [Person]?
    /// The age rating as the library's country writes it ("ES-12", "PG").
    public var officialRating: String?
    /// The community's score out of 10.
    public var communityRating: Double?
    public var taglines: [String]?
    public var studios: [String]?

    public init(id: String, name: String, kind: ItemKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// The spec marks `Name` and every `ImageTags` value nullable; one null must
    /// not fail a whole page, so a missing name decodes as "" and null tags drop out.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decode(ItemKind.self, forKey: .kind)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        productionYear = try c.decodeIfPresent(Int.self, forKey: .productionYear)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        originalTitle = try c.decodeIfPresent(String.self, forKey: .originalTitle)
        // Search garnish: a malformed list must not fail the item.
        genres = (try? c.decodeIfPresent([String?].self, forKey: .genres))?.compactMap { $0 }
        tags = (try? c.decodeIfPresent([String?].self, forKey: .tags))?.compactMap { $0 }
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        collectionType = try c.decodeIfPresent(String.self, forKey: .collectionType)
        primaryAspectRatio = try c.decodeIfPresent(Double.self, forKey: .primaryAspectRatio)
        imageTags = try c.decodeIfPresent([String: String?].self, forKey: .imageTags)?.compactMapValues { $0 }
        backdropImageTags = try c.decodeIfPresent([String?].self, forKey: .backdropImageTags)?.compactMap { $0 }
        seriesPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: .seriesPrimaryImageTag)
        parentBackdropItemId = try c.decodeIfPresent(String.self, forKey: .parentBackdropItemId)
        parentBackdropImageTags = try c.decodeIfPresent([String?].self, forKey: .parentBackdropImageTags)?.compactMap { $0 }
        parentLogoItemId = try c.decodeIfPresent(String.self, forKey: .parentLogoItemId)
        parentLogoImageTag = try c.decodeIfPresent(String.self, forKey: .parentLogoImageTag)
        // Optional garnish: a malformed map must not fail the item.
        imageBlurHashes = (try? c.decodeIfPresent([String: [String: String?]].self, forKey: .imageBlurHashes))?
            .mapValues { $0.compactMapValues { $0 } }
        userData = try c.decodeIfPresent(UserData.self, forKey: .userData)
        // Credits are garnish too: one odd entry drops out, never the item.
        people = (try? c.decodeIfPresent([Lossy<Person>].self, forKey: .people))?.compactMap(\.value)
        officialRating = try? c.decodeIfPresent(String.self, forKey: .officialRating)
        communityRating = try? c.decodeIfPresent(Double.self, forKey: .communityRating)
        taglines = (try? c.decodeIfPresent([String?].self, forKey: .taglines))?.compactMap { $0 }
        studios = (try? c.decodeIfPresent([Lossy<NamedRef>].self, forKey: .studios))?.compactMap { $0.value?.name }
    }

    /// Writes what `init(from:)` reads (the offline mirror keeps items as
    /// JSON): studios go out as `{"Name": …}` objects, as the server sends them.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(seriesId, forKey: .seriesId)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encodeIfPresent(seriesName, forKey: .seriesName)
        try c.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try c.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try c.encodeIfPresent(productionYear, forKey: .productionYear)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(originalTitle, forKey: .originalTitle)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(runTimeTicks, forKey: .runTimeTicks)
        try c.encodeIfPresent(collectionType, forKey: .collectionType)
        try c.encodeIfPresent(primaryAspectRatio, forKey: .primaryAspectRatio)
        try c.encodeIfPresent(imageTags, forKey: .imageTags)
        try c.encodeIfPresent(backdropImageTags, forKey: .backdropImageTags)
        try c.encodeIfPresent(seriesPrimaryImageTag, forKey: .seriesPrimaryImageTag)
        try c.encodeIfPresent(parentBackdropItemId, forKey: .parentBackdropItemId)
        try c.encodeIfPresent(parentBackdropImageTags, forKey: .parentBackdropImageTags)
        try c.encodeIfPresent(parentLogoItemId, forKey: .parentLogoItemId)
        try c.encodeIfPresent(parentLogoImageTag, forKey: .parentLogoImageTag)
        try c.encodeIfPresent(imageBlurHashes, forKey: .imageBlurHashes)
        try c.encodeIfPresent(userData, forKey: .userData)
        try c.encodeIfPresent(people, forKey: .people)
        try c.encodeIfPresent(officialRating, forKey: .officialRating)
        try c.encodeIfPresent(communityRating, forKey: .communityRating)
        try c.encodeIfPresent(taglines, forKey: .taglines)
        try c.encodeIfPresent(studios?.map { ["Name": $0] }, forKey: .studios)
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case kind = "Type"
        case seriesId = "SeriesId"
        case parentId = "ParentId"
        case seriesName = "SeriesName"
        case seasonNumber = "ParentIndexNumber"
        case episodeNumber = "IndexNumber"
        case productionYear = "ProductionYear"
        case overview = "Overview"
        case originalTitle = "OriginalTitle"
        case genres = "Genres"
        case tags = "Tags"
        case runTimeTicks = "RunTimeTicks"
        case collectionType = "CollectionType"
        case primaryAspectRatio = "PrimaryImageAspectRatio"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemId = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case imageBlurHashes = "ImageBlurHashes"
        case userData = "UserData"
        case people = "People"
        case officialRating = "OfficialRating"
        case communityRating = "CommunityRating"
        case taglines = "Taglines"
        case studios = "Studios"
    }

    /// The image a poster tile shows: the item's own, else (for an episode
    /// without one) its series poster.
    public var posterImage: ImageRef? {
        if let tag = imageTags?["Primary"] { return ImageRef(itemId: id, kind: .primary, tag: tag) }
        if let seriesId, let tag = seriesPrimaryImageTag { return ImageRef(itemId: seriesId, kind: .primary, tag: tag) }
        return nil
    }

    /// The item's own Primary image only (an episode's still), never a borrowed poster.
    public var ownPrimaryImage: ImageRef? {
        imageTags?["Primary"].map { ImageRef(itemId: id, kind: .primary, tag: $0) }
    }

    /// Wide (16:9) art, such as a YouTube thumbnail or an episode still, gets
    /// a wide tile. A borrowed series poster is portrait.
    public var hasWidePoster: Bool {
        imageTags?["Primary"] != nil && (primaryAspectRatio ?? 0) > 1.2
    }

    /// "T1 · E2" for an episode in Spanish (temporada, episodio), "S1 · E2" in
    /// English, "E2" without a season; nil for anything else, or an episode with
    /// no number (a season alone, "T1", says nothing about which one).
    public func episodeLabel(_ language: AppLanguage) -> String? {
        guard kind == .episode, let episodeNumber else { return nil }
        return [seasonNumber.map { language.seasonLabel($0) }, "E\(episodeNumber)"].compactMap { $0 }.joined(separator: " · ")
    }

    /// The season's own number (Jellyfin stores it as the season's IndexNumber);
    /// for an episode, the season it belongs to. Nil for specials without one.
    public var seasonIndex: Int? { kind == .season ? episodeNumber : seasonNumber }

    /// The name without a leading file-name prefix: when it holds an
    /// `S<digits>E<digits>` marker followed by " - ", everything up to and
    /// including that " - " goes. Never empty (falls back to the name).
    public var displayName: String {
        guard let marker = name.range(of: #"S\d+E\d+ - "#, options: .regularExpression) else { return name }
        let rest = name[marker.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? name : rest
    }

    /// The " - …" tail most of these names share, as YouTube channels repeat
    /// theirs on every video ("Uno - cuentos - Canal
    /// Ejemplo"). Nil unless at least three names and 60% of them share one.
    public static func sharedSuffix(_ names: [String]) -> String? {
        guard names.count >= 3 else { return nil }
        var counts: [String: Int] = [:]
        for name in names {
            // Every tail starting at a " - ", except one that is the whole name.
            var searchStart = name.startIndex
            while let range = name.range(of: " - ", range: searchStart..<name.endIndex) {
                if range.lowerBound > name.startIndex { counts[String(name[range.lowerBound...]), default: 0] += 1 }
                searchStart = range.upperBound
            }
        }
        let needed = Int((Double(names.count) * 0.6).rounded(.up))
        // The longest tail common enough: it drops the most noise.
        return counts.filter { $0.value >= needed }.keys.max { $0.count < $1.count }
    }

    /// `displayName` without `suffix` (from `sharedSuffix`) when it ends with it.
    public func displayName(dropping suffix: String?) -> String {
        guard let suffix, displayName.hasSuffix(suffix), displayName.count > suffix.count else { return displayName }
        return String(displayName.dropLast(suffix.count))
    }

    /// "T1 · E3 · Name" for an episode ("S1 · E3 · Name" in English), else the name (as `displayName`).
    public func episodeTitle(_ language: AppLanguage) -> String { [episodeLabel(language), displayName].compactMap { $0 }.joined(separator: " · ") }

    /// Search's caption on the TV: what was found comes first, so an episode reads
    /// "Name · Series" (the episode is the match, not the series). The phone's
    /// narrower tiles use `displayName` over `searchSubtitle` instead.
    public var searchCaption: String {
        guard kind == .episode, let seriesName else { return displayName }
        return [displayName, seriesName].joined(separator: " · ")
    }

    /// Search's second line for an episode: where it is from, "T1 · E3 · Series",
    /// the number first so a long series name cuts off only itself (the first
    /// line, `displayName`, is the episode's own name). Nil otherwise.
    public func searchSubtitle(_ language: AppLanguage) -> String? {
        guard kind == .episode else { return nil }
        let parts = [episodeLabel(language), seriesName].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The caption under a tile's image: an episode of a known series reads
    /// "Series · T1 · E3" (English "Series · S1 · E3"; "Series · Name" without a
    /// number); anything else is its display name.
    public func tileCaption(_ language: AppLanguage) -> String {
        guard kind == .episode, let seriesName else { return displayName }
        return [seriesName, episodeLabel(language) ?? displayName].joined(separator: " · ")
    }

    /// How far a progress bar fills (0–100), or nil when none shows: nothing
    /// watched yet, or already watched to the end.
    public var progressPercent: Double? {
        guard userData?.played != true, let percent = userData?.playedPercentage, percent > 0 else { return nil }
        return min(percent, 100)
    }

    /// The season a series page shows first: the one holding the episode Play
    /// would start, else the first real season (Specials, number 0, only when
    /// it is all there is).
    public static func defaultSeason(_ seasons: [Item], next: Item?) -> Item? {
        if let index = next?.seasonNumber, let match = seasons.first(where: { $0.seasonIndex == index }) { return match }
        return seasons.first { ($0.seasonIndex ?? 1) >= 1 } ?? seasons.first
    }

    /// Where Play resumes this item from (0 = the start).
    public var resumeTicks: Int64 { userData?.playbackPositionTicks ?? 0 }

    /// Whether a detail page offers to pin it (Jellyfin favorites).
    public var isPinnable: Bool { [.movie, .series, .video].contains(kind) }

    /// A wide image for a shelf tile: an episode still or other wide art of
    /// the item's own, else its backdrop. Nil when it has neither.
    public var wideImage: ImageRef? {
        if hasWidePoster, let tag = imageTags?["Primary"] { return ImageRef(itemId: id, kind: .primary, tag: tag) }
        if kind == .episode, let tag = imageTags?["Primary"] { return ImageRef(itemId: id, kind: .primary, tag: tag) }
        return backdropImage
    }

    /// The title as artwork (a show's logo), its own or its series'; nil when there's none.
    public var logoImage: ImageRef? {
        if let tag = imageTags?["Logo"] { return ImageRef(itemId: id, kind: .logo, tag: tag) }
        if let parent = parentLogoItemId, let tag = parentLogoImageTag { return ImageRef(itemId: parent, kind: .logo, tag: tag) }
        return nil
    }

    /// The wide image behind a detail page: the item's backdrop, else its parent's.
    public var backdropImage: ImageRef? {
        if let tag = backdropImageTags?.first { return ImageRef(itemId: id, kind: .backdrop, tag: tag) }
        if let parent = parentBackdropItemId, let tag = parentBackdropImageTags?.first {
            return ImageRef(itemId: parent, kind: .backdrop, tag: tag)
        }
        return nil
    }
}

/// One element of a list that decodes to nil instead of failing the list.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) throws { value = try? T(from: decoder) }
}

/// Jellyfin's `NameGuidPair` (a studio).
struct NamedRef: Decodable {
    let name: String
    enum CodingKeys: String, CodingKey { case name = "Name" }
}

/// What someone did on a title.
public enum PersonKind: Sendable, Hashable, Codable {
    case actor, guestStar, director, writer
    case other(String)

    init(raw: String) {
        switch raw {
        case "Actor": self = .actor
        case "GuestStar": self = .guestStar
        case "Director": self = .director
        case "Writer": self = .writer
        default: self = .other(raw)
        }
    }

    var raw: String {
        switch self {
        case .actor: "Actor"
        case .guestStar: "GuestStar"
        case .director: "Director"
        case .writer: "Writer"
        case .other(let raw): raw
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// A credit: a person on one title. Their id is a Jellyfin item too, so
/// `client.personItems` finds what else they are in and their photo is
/// served like any poster.
public struct Person: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// The character, for an actor.
    public var role: String?
    public var kind: PersonKind
    public var primaryImageTag: String?

    public init(id: String, name: String, role: String? = nil, kind: PersonKind, primaryImageTag: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.kind = kind
        self.primaryImageTag = primaryImageTag
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        let role = try c.decodeIfPresent(String.self, forKey: .role)
        self.role = role?.isEmpty == false ? role : nil
        kind = (try? c.decodeIfPresent(PersonKind.self, forKey: .kind)) ?? .other("")
        primaryImageTag = try c.decodeIfPresent(String.self, forKey: .primaryImageTag)
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case kind = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }

    /// The credits Search indexes (and the catalog keeps).
    public var isSearched: Bool { [.actor, .director, .guestStar].contains(kind) }

    /// Their photo, if they have one.
    public var image: ImageRef? {
        primaryImageTag.map { ImageRef(itemId: id, kind: .primary, tag: $0) }
    }

    /// "NV" for "Nico Varela": the placeholder in a round tile with no photo.
    public var initials: String {
        let letters = name.split(separator: " ").compactMap(\.first)
        let picked = letters.count > 2 ? [letters[0], letters[letters.count - 1]] : letters
        return String(picked).uppercased()
    }
}

extension Item {
    /// The main cast, billing order as the server lists it.
    public var cast: [Person] { (people ?? []).filter { $0.kind == .actor } }
    public var guestStars: [Person] { (people ?? []).filter { $0.kind == .guestStar } }
    public var directors: [Person] { (people ?? []).filter { $0.kind == .director } }
    public var writers: [Person] { (people ?? []).filter { $0.kind == .writer } }

    /// Whether a title page has a cast row at all.
    public var hasCredits: Bool { !cast.isEmpty || !guestStars.isEmpty }

    /// What someone appears in, from a search of the library by person:
    /// films and videos as they are; each episode folded into its series
    /// (once, at the series' own entry when the list has it), so a long
    /// sitcom is one tile, not forty.
    public static func grouped(byPerson items: [Item]) -> [Item] {
        var result: [Item] = []
        var seen = Set<String>()
        let seriesPresent = Set(items.filter { $0.kind == .series }.map(\.id))
        for item in items {
            switch item.kind {
            case .episode:
                guard let seriesId = item.seriesId, let name = item.seriesName else {
                    if seen.insert(item.id).inserted { result.append(item) }
                    continue
                }
                if seriesPresent.contains(seriesId) || !seen.insert(seriesId).inserted { continue }
                var series = Item(id: seriesId, name: name, kind: .series)
                if let tag = item.seriesPrimaryImageTag { series.imageTags = ["Primary": tag] }
                series.parentBackdropItemId = item.parentBackdropItemId
                series.parentBackdropImageTags = item.parentBackdropImageTags
                result.append(series)
            default:
                if seen.insert(item.id).inserted { result.append(item) }
            }
        }
        return result.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// "★ 8.5" for the facts row; nil without a score.
    public var ratingText: String? {
        guard let rating = communityRating, rating > 0 else { return nil }
        let tenths = Int((rating * 10).rounded())
        return "★ \(tenths / 10).\(tenths % 10)"
    }
}

/// Points at one server image; `tag` changes whenever the image does, so the
/// URL doubles as a cache key.
public struct ImageRef: Sendable, Hashable {
    public enum Kind: String, Sendable { case primary = "Primary", backdrop = "Backdrop", logo = "Logo" }
    public var itemId: String
    public var kind: Kind
    public var tag: String
}

struct ItemsPage: Decodable {
    var items: [Item]
    var totalRecordCount: Int?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decode([Item].self, forKey: .items)
        #if DEBUG
        items = DebugItemFilter.apply(decoded)   // -MatineDevOnlyItems (screenshots)
        #else
        items = decoded
        #endif
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: .totalRecordCount)
    }

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

/// One page of a longer list. `total` comes with the first page only.
public struct ItemPage: Sendable, Hashable {
    public var items: [Item]
    public var total: Int?
    public var start: Int
    public var limit: Int
}

/// A library grid's contents, built from pages. A page for an older sort, or
/// one that doesn't continue where the list ends (a duplicate or a late
/// answer), is ignored, so changing the sort mid-load can't mix two orders.
public struct LibraryListing: Sendable, Hashable {
    public private(set) var sort: LibrarySort
    public private(set) var items: [Item] = []
    public private(set) var total: Int?
    public private(set) var exhausted = false

    public init(sort: LibrarySort) { self.sort = sort }

    public mutating func reset(sort: LibrarySort) { self = LibraryListing(sort: sort) }

    /// Where the next page starts, or nil when everything is loaded.
    public var nextStart: Int? { exhausted ? nil : items.count }

    /// Takes the page if it belongs here; returns whether it did.
    @discardableResult
    public mutating func accept(_ page: ItemPage, for sort: LibrarySort) -> Bool {
        guard sort == self.sort, page.start == items.count, !exhausted else { return false }
        // Paging by offset can repeat an item when the server gained one between pages.
        let listed = Set(items.map(\.id))
        items += page.items.filter { !listed.contains($0.id) }
        if let total = page.total { self.total = total }
        exhausted = page.items.count < page.limit || (total.map { items.count >= $0 } ?? false)
        return true
    }

    /// Swaps in a fresh read of everything listed so far (a page that starts at 0 and
    /// is at least as long as the list), keeping how far it goes: a grid refreshes
    /// after a playback without losing the scroll position. False if it doesn't belong.
    @discardableResult
    public mutating func refresh(with page: ItemPage, for sort: LibrarySort) -> Bool {
        guard sort == self.sort, page.start == 0, page.limit >= items.count else { return false }
        var listed = Set<String>()
        items = page.items.filter { listed.insert($0.id).inserted }
        if let total = page.total { self.total = total }
        exhausted = page.items.count < page.limit || (total.map { items.count >= $0 } ?? false)
        return true
    }
}

public struct User: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var serverId: String?
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
    }
}

struct AuthenticationResult: Decodable {
    var user: User
    var accessToken: String
    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
    }
}

public struct PublicServerInfo: Codable, Sendable, Hashable {
    public var id: String
    public var serverName: String
    public var version: String
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
    }
}
