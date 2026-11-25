import MatineKit
import TVServices

/// The tiles above Matiné on the Apple TV home screen. Reads the snapshot the
/// app keeps in the shared keychain group (titles, tokenless image URLs and
/// matine:// links; no token) and shows it; with no snapshot the system shows
/// the static Top Shelf image instead.
final class ContentProvider: TVTopShelfContentProvider {
    // The completion-handler form: the work is a Keychain read, nothing to
    // await, and the system's content types aren't Sendable.
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        completionHandler(Self.content())
    }

    static func content() -> (any TVTopShelfContent)? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MatineKeychainGroup") as? String,
              let data = try? KeychainSecretStore(accessGroup: group).read(TopShelfSnapshot.key),
              let shelf = TopShelfSnapshot.decode(data)
        else { return nil }
        let sections = shelf.sections.map { section in
            let collection = TVTopShelfItemCollection(items: section.tiles.map(item))
            collection.title = section.title
            return collection
        }
        return TVTopShelfSectionedContent(sections: sections)
    }

    private static func item(_ tile: TopShelfSnapshot.Tile) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: tile.id)
        item.title = tile.title
        item.imageShape = tile.wide ? .hdtv : .poster
        if let image = tile.image { item.setImageURL(image, for: [.screenScale1x, .screenScale2x]) }
        item.displayAction = TVTopShelfAction(url: tile.display)
        item.playAction = TVTopShelfAction(url: tile.play)
        return item
    }
}
