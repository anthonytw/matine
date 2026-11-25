import Foundation

/// What the Apple TV home screen shows above Matiné when it sits in the top
/// row: Continue watching and Pinned, for one profile WITHOUT a PIN (a kids'
/// profile, typically). A PIN profile's viewing never reaches the home screen,
/// where anyone with the remote can see it.
///
/// It holds no token or password: titles, tokenless image URLs and app links.
/// The app writes it to a keychain group shared with the Top Shelf extension.
public struct TopShelfSnapshot: Codable, Sendable, Hashable {
    public struct Tile: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var title: String
        public var image: URL?
        /// The image is 16:9 (else a 2:3 poster).
        public var wide: Bool
        /// Opens the item's page (select).
        public var display: URL
        /// Starts it (Play on the remote).
        public var play: URL
    }

    public struct Section: Codable, Sendable, Hashable {
        public var title: String
        public var tiles: [Tile]
    }

    public var accountId: String
    public var sections: [Section]

    public static let key = "topshelf.snapshot"
    /// The shared keychain group's suffix; the full group is "<Team ID>.<this>".
    public static let accessGroupSuffix = "io.github.anthonytw.matine.shared"
    /// At most this many tiles per section: the shelf shows few, each tile's
    /// image is fetched by the system.
    public static let tilesPerSection = 12

    /// The shelf for one profile's home rows, or nil if there is nothing to
    /// show. Section titles come in the profile's language.
    public static func make(account: Account, client: JellyfinClient, rows: [HomeRow]) -> TopShelfSnapshot? {
        func tiles(_ kind: HomeRow.Kind) -> [Tile] {
            (rows.first { $0.kind == kind }?.items ?? []).prefix(tilesPerSection).map { item in
                Tile(
                    id: item.id,
                    title: item.kind == .episode ? [item.seriesName, item.episodeTitle(account.language)].compactMap { $0 }.joined(separator: " · ") : item.name,
                    image: (item.wideImage ?? item.posterImage).map { client.imageURL($0, maxHeight: 720) },
                    wide: item.wideImage != nil,
                    display: AppLink.item(item.id, account: account.id).url,
                    play: AppLink.play(item.id, account: account.id).url
                )
            }
        }
        // Resume first, then what's next, then pins: what a person most likely wants now.
        let watching = tiles(.continueWatching)
        let english = account.language == .english
        var sections: [Section] = []
        if !watching.isEmpty { sections.append(Section(title: english ? "Continue watching" : "Seguir viendo", tiles: watching)) }
        let pinned = tiles(.pinned)
        if !pinned.isEmpty { sections.append(Section(title: english ? "Pinned" : "Fijados", tiles: pinned)) }
        return sections.isEmpty ? nil : TopShelfSnapshot(accountId: account.id, sections: sections)
    }

    /// Whether the shelf may show `accountId`'s rows at all: the profile exists, has
    /// no PIN, and is not an adult a kid could walk into (in a house with kids).
    /// Checked when the shelf is written and again whenever the profiles, roles
    /// or PINs change, so a rule that changes later does not leave old rows up.
    public static func mayShow(accountId: String, rules: HouseRules) -> Bool {
        guard rules.accounts.contains(where: { $0.id == accountId }), !rules.isPinned(accountId) else { return false }
        return !rules.unguardedAdults.contains { $0.id == accountId }
    }

    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) -> TopShelfSnapshot? { try? JSONDecoder().decode(TopShelfSnapshot.self, from: data) }
}

/// `matine://` links: what Top Shelf tiles open. Only these two shapes are
/// accepted; anything else is ignored.
public enum AppLink: Sendable, Hashable {
    case item(String, account: String)
    case play(String, account: String)

    public static let scheme = "matine"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .item(let id, let account): c.host = "item"; c.path = "/" + id; c.queryItems = [URLQueryItem(name: "account", value: account)]
        case .play(let id, let account): c.host = "play"; c.path = "/" + id; c.queryItems = [URLQueryItem(name: "account", value: account)]
        }
        return c.url!
    }

    public init?(_ url: URL) {
        guard url.scheme == Self.scheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let account = c.queryItems?.first(where: { $0.name == "account" })?.value, !account.isEmpty
        else { return nil }
        let id = String(c.path.dropFirst())
        guard !id.isEmpty, !id.contains("/"), id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        switch c.host {
        case "item": self = .item(id, account: account)
        case "play": self = .play(id, account: account)
        default: return nil
        }
    }

    public var itemId: String { switch self { case .item(let id, _), .play(let id, _): id } }
    public var accountId: String { switch self { case .item(_, let a), .play(_, let a): a } }
}
