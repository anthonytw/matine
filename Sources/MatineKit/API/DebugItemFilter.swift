#if DEBUG
import Foundation

/// `-MatineDevOnlyItems ID,ID,...` (a launch argument, debug builds only: the file is compiled
/// out of Release): the app sees only these films, videos and series, and the episodes and
/// seasons of these series. For store screenshots from a shared demo server, where only
/// freely licensed titles may appear in any row, hero, search result or library grid.
/// Libraries, people and other kinds pass untouched.
enum DebugItemFilter {
    static let allowed: Set<String>? = {
        guard let raw = UserDefaults.standard.string(forKey: "MatineDevOnlyItems") else { return nil }
        let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ids.isEmpty ? nil : Set(ids)
    }()

    static func apply(_ items: [Item]) -> [Item] {
        guard let allowed else { return items }
        return items.filter { item in
            switch item.kind {
            case .movie, .video, .series: allowed.contains(item.id)
            case .episode, .season: item.seriesId.map(allowed.contains) ?? allowed.contains(item.id)
            default: true
            }
        }
    }
}
#endif
