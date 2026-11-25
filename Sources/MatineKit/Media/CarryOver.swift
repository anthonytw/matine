import Foundation

/// A remux changes a file's extension (`.mkv` to `.mp4`), so after the rescan
/// Jellyfin lists a NEW item: no watched mark, no progress, no favorite. This
/// saves that state per profile before the swap and writes it onto the new
/// item after the rescan. Each profile has its own state, so each runs it
/// with its own token.
public struct CarryOverSnapshot: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var oldPath: String
        public var newPath: String
        public var title: String
        public var played: Bool
        public var positionTicks: Int64
        public var favorite: Bool
        /// The new path was already a library item when the snapshot was taken: a file
        /// that isn't ours, so its state is not ours to overwrite.
        public var newPathExisted: Bool
    }

    public var version = 1
    /// The profile it was taken for (a reminder; restore uses the token it runs with).
    public var profile: String?
    /// How many of the profile's files will change name, including those with nothing to carry.
    public var renamed: Int
    public var entries: [Entry]
}

/// One write the restore would make.
public struct CarryOverAction: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case played
        case position(ticks: Int64)
        case favorite
    }

    public var itemId: String
    public var title: String
    public var kind: Kind

    public var summary: String {
        switch kind {
        case .played: "mark as watched"
        case .position(let ticks): "resume at \(ticks / 10_000_000) s"
        case .favorite: "mark as favorite"
        }
    }
}

public struct CarryOverRestore: Sendable {
    public var actions: [CarryOverAction]
    /// Entries whose new path isn't in the library (yet): the rescan isn't done, or the file wasn't converted.
    public var missing: [CarryOverSnapshot.Entry]
    /// Entries whose new item already has that state (or newer progress).
    public var alreadyDone: Int
    /// Entries restore won't touch: the new path existed before the conversion, or the old file is still listed.
    public var unsafe: [CarryOverSnapshot.Entry] = []
}

public enum CarryOver {
    /// What the profile has on the files that a conversion would rename.
    /// Needs `files` read with `withUserData: true`.
    public static func snapshot(files: [MediaFile], profile: String?, mediaRoot: String = ConversionPlan.defaultMediaRoot) -> CarryOverSnapshot {
        let checks = files.map { MediaCheck(file: $0, layout: nil) }
        let renames = ConversionPlan(checks: checks, mediaRoot: mediaRoot).steps.filter(\.isRename)
        var entries: [CarryOverSnapshot.Entry] = []
        let existing = Set(files.compactMap { $0.path?.lowercased() })
        for step in renames {
            let data = step.check.file.userData
            let entry = CarryOverSnapshot.Entry(
                oldPath: step.sourcePath, newPath: step.outputPath, title: step.check.file.title,
                played: data?.played == true, positionTicks: data?.playbackPositionTicks ?? 0, favorite: data?.isFavorite == true,
                newPathExisted: existing.contains(step.outputPath.lowercased())
            )
            if entry.played || entry.positionTicks > 0 || entry.favorite { entries.append(entry) }
        }
        return CarryOverSnapshot(profile: profile, renamed: renames.count, entries: entries)
    }

    /// Matches each entry to the item at its new path and works out what to
    /// write. Never overwrites: a mark already there stays, and progress is
    /// only written onto an item with none (the user may have watched it since).
    public static func restore(_ snapshot: CarryOverSnapshot, files: [MediaFile]) -> CarryOverRestore {
        var byPath: [String: MediaFile] = [:]
        for file in files { if let path = file.path { byPath[path] = file } }
        var result = CarryOverRestore(actions: [], missing: [], alreadyDone: 0)
        for entry in snapshot.entries {
            // A new path that was already a library item isn't ours; an old path still listed means
            // the rescan hasn't dropped it (or it was never swapped): don't write onto a stranger.
            if entry.newPathExisted || byPath[entry.oldPath] != nil {
                result.unsafe.append(entry)
                continue
            }
            guard let file = byPath[entry.newPath] else {
                result.missing.append(entry)
                continue
            }
            let current = file.userData
            var wanted: [CarryOverAction.Kind] = []
            if entry.played {
                if current?.played != true { wanted.append(.played) }
            } else if entry.positionTicks > 0, current?.played != true, (current?.playbackPositionTicks ?? 0) == 0 {
                wanted.append(.position(ticks: entry.positionTicks))
            }
            if entry.favorite, current?.isFavorite != true { wanted.append(.favorite) }
            if wanted.isEmpty { result.alreadyDone += 1 }
            result.actions += wanted.map { CarryOverAction(itemId: file.itemId, title: entry.title, kind: $0) }
        }
        return result
    }
}

extension JellyfinClient {
    /// Performs the restore's writes, one at a time (per-user endpoints only).
    public func apply(_ actions: [CarryOverAction], userId: String) async throws {
        for action in actions {
            switch action.kind {
            case .played: try await setPlayed(itemId: action.itemId, userId: userId)
            case .position(let ticks): try await setPlaybackPosition(ticks: ticks, itemId: action.itemId, userId: userId)
            case .favorite: try await setPinned(true, itemId: action.itemId, userId: userId)
            }
        }
    }
}
