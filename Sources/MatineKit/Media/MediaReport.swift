import Foundation

/// What each file in the library needs before the Apple TV (and, later, an
/// offline copy on a phone) plays it as it is, read from what Jellyfin already
/// knows about the file plus a few bytes of its start. Read-only: it changes
/// nothing, on the server or the NAS. The converter acts on these verdicts.
///
/// The rule: never re-encode what already plays. A file is
/// - `fine`: plays as it is;
/// - `unchecked`: its streams play, but where its index sits wasn't read (a
///   failed read, or `--quick`); never counted as fine;
/// - `faststart`: an MP4 with its index (`moov`) after the media, so playback
///   and seeking wait on the end of the file; moving it is lossless;
/// - `remux`: compatible streams in the wrong box (MKV), or a tag AVPlayer
///   refuses (HEVC as `hev1`); copying the streams into MP4 is lossless;
/// - `reencode`: a stream the Apple TV can't decode; only that stream is
///   encoded again, the rest copied;
/// - `skip`: nothing to act on: a disc folder, a remote stream, or a file
///   Jellyfin hasn't read the streams of.
public enum MediaVerdict: String, Sendable, Codable, CaseIterable, Comparable {
    case fine, unchecked, faststart, remux, reencode, skip

    public static func < (a: Self, b: Self) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// One stream of a file, as Jellyfin's scan saw it.
public struct MediaStreamInfo: Decodable, Sendable, Hashable {
    public var index: Int?
    /// Jellyfin's stream type: Video, Audio, Subtitle, EmbeddedImage, Data, Lyric.
    public var type: String
    public var codec: String?
    public var codecTag: String?
    public var profile: String?
    public var bitDepth: Int?
    public var pixelFormat: String?
    public var width: Int?
    /// SDR, HDR10, HLG, DOVI, DOVIWithEL… (Jellyfin's `VideoRangeType`).
    public var videoRangeType: String?
    public var channels: Int?
    public var language: String?
    /// A sidecar file next to the video (`.srt`): not inside it, so a
    /// conversion leaves it alone.
    public var isExternal: Bool?

    public init(index: Int? = nil, type: String, codec: String?, codecTag: String? = nil, profile: String? = nil,
                bitDepth: Int? = nil, pixelFormat: String? = nil, width: Int? = nil, videoRangeType: String? = nil,
                channels: Int? = nil, language: String? = nil, isExternal: Bool? = nil) {
        self.index = index
        self.type = type
        self.codec = codec
        self.codecTag = codecTag
        self.profile = profile
        self.bitDepth = bitDepth
        self.pixelFormat = pixelFormat
        self.width = width
        self.videoRangeType = videoRangeType
        self.channels = channels
        self.language = language
        self.isExternal = isExternal
    }

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case codecTag = "CodecTag"
        case profile = "Profile"
        case bitDepth = "BitDepth"
        case pixelFormat = "PixelFormat"
        case width = "Width"
        case videoRangeType = "VideoRangeType"
        case channels = "Channels"
        case language = "Language"
        case isExternal = "IsExternal"
    }

    /// "audio 1 dts" for notes.
    var label: String { "\(type.lowercased()) \(index.map(String.init) ?? "?") \(codec ?? "?")" }
}

/// One file (a media source) of an item. An item with two versions has two.
public struct MediaFile: Sendable, Hashable {
    public var itemId: String
    public var sourceId: String
    /// "Series · T1 · E2 · Name" for an episode, else the name.
    public var title: String
    /// Jellyfin's container name, sometimes a list ("mov,mp4,m4a").
    public var container: String?
    /// The path on the server, for the converter (never sent anywhere).
    public var path: String?
    public var size: Int64?
    /// `File` for a file on disk; anything else is a stream or a disc.
    public var `protocol`: String?
    public var videoType: String?
    public var streams: [MediaStreamInfo]
    /// The profile's watched state, only when asked for (`mediaFiles(withUserData:)`).
    public var userData: UserData?

    public init(itemId: String, sourceId: String, title: String, container: String?, path: String? = nil, size: Int64? = nil,
                protocol: String? = "File", videoType: String? = "VideoFile", streams: [MediaStreamInfo], userData: UserData? = nil) {
        self.userData = userData
        self.itemId = itemId
        self.sourceId = sourceId
        self.title = title
        self.container = container
        self.path = path
        self.size = size
        self.protocol = `protocol`
        self.videoType = videoType
        self.streams = streams
    }

    /// An MP4-family box (what the Apple TV plays directly), where the
    /// `moov` position matters.
    public var isMP4: Bool {
        (container ?? "").lowercased().split(separator: ",").contains { MediaCheck.mp4Containers.contains(String($0)) }
    }
}

/// Where an MP4's index sits, read from its top-level boxes.
public enum MP4Layout: Sendable, Hashable {
    /// `moov` before `mdat`: playback starts after the first few kilobytes.
    case moovFirst
    /// `mdat` first: the player has to fetch the end of the file before it starts.
    case moovLast
    case unknown(String)
}

/// What to do with one stream in a conversion.
public enum StreamAction: Sendable, Hashable {
    case copy
    /// Copy, but mark it with the tag AVPlayer wants (`hvc1`).
    case retag(String)
    /// Encode again in this codec (`hevc`, `h264`, `flac`, `eac3`, `aac`).
    case encode(String)
    /// Text subtitles carried into MP4 as `mov_text` (styling is lost).
    case toMovText
    /// Can't go into MP4 (picture subtitles, cover art, data tracks): the
    /// converter keeps it outside the MP4 (a sidecar) or in the original.
    case leaveOut(String)

    /// The action's name and its target, for `--json`.
    public var parts: (name: String, target: String?) {
        switch self {
        case .copy: ("copy", nil)
        case .retag(let tag): ("retag", tag)
        case .encode(let codec): ("encode", codec)
        case .toMovText: ("mov_text", nil)
        case .leaveOut(let why): ("leave_out", why)
        }
    }
}

public struct StreamPlan: Sendable, Hashable {
    public var stream: MediaStreamInfo
    public var action: StreamAction
}

/// One file's verdict, with what happens to each of its streams.
public struct MediaCheck: Sendable, Hashable {
    public var file: MediaFile
    public var layout: MP4Layout?
    public var verdict: MediaVerdict
    public var streams: [StreamPlan]
    /// Plain words for the CLI: why the verdict, and anything lost.
    public var notes: [String]

    static let mp4Containers = Set(AppleTVProfile.directContainers.split(separator: ",").map(String.init))
    static let videoCodecs = Set(AppleTVProfile.videoCodecs.split(separator: ",").map(String.init))
    static let audioCodecs = Set(AppleTVProfile.audioCodecs.split(separator: ",").map(String.init))
    static let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "text"]

    public init(file: MediaFile, layout: MP4Layout?) {
        self.file = file
        self.layout = layout
        let streams = file.streams.filter { $0.isExternal != true }
        guard file.protocol == nil || file.protocol == "File", file.videoType == nil || file.videoType == "VideoFile" else {
            (verdict, self.streams, notes) = (.skip, [], ["not a plain file (\(file.videoType ?? file.protocol ?? "?"))"])
            return
        }
        // A file Jellyfin hasn't probed (still copying, or unreadable) says nothing about itself.
        guard streams.contains(where: { $0.type == "Video" }) else {
            (verdict, self.streams, notes) = (.skip, [], ["no video stream info from Jellyfin"])
            return
        }
        let inMP4 = file.isMP4
        let hasMovie = streams.contains { $0.type == "Video" && !Self.isPicture($0) }
        let plans = streams.map { StreamPlan(stream: $0, action: Self.action(for: $0, inMP4: inMP4, hasMovie: hasMovie)) }
        self.streams = plans
        var notes: [String] = []
        for plan in plans {
            let s = plan.stream
            switch plan.action {
            case .copy: break
            case .retag(let tag): notes.append("\(s.label): tagged \(s.codecTag ?? "?"), needs \(tag)")
            case .encode(let codec):
                let detail = [s.profile, s.channels.map { "\($0) ch" }].compactMap { $0 }.joined(separator: ", ")
                notes.append("\(s.label)\(detail.isEmpty ? "" : " (\(detail))"): Apple TV can't decode it → \(codec)")
            case .toMovText:
                if ["ass", "ssa"].contains((s.codec ?? "").lowercased()) { notes.append("\(s.label) → mov_text (styling lost)") }
                else { notes.append("\(s.label) → mov_text") }
            case .leaveOut(let why): notes.append("\(s.label): \(why), kept outside the MP4")
            }
            if let range = s.videoRangeType, range.hasPrefix("DOVIWithEL") {
                notes.append("\(s.label): Dolby Vision with an enhancement layer (profile 7); the Apple TV shows only its HDR10 base layer")
            }
        }
        let actions = plans.map(\.action)
        if actions.contains(where: { if case .encode = $0 { true } else { false } }) {
            verdict = .reencode
        } else if !inMP4 || actions.contains(where: { if case .retag = $0 { true } else { false } }) {
            verdict = .remux
            if !inMP4 { notes.insert("\(file.container ?? "unknown container") → mp4", at: 0) }
        } else {
            switch layout {
            case .moovFirst:
                verdict = .fine
            case .moovLast:
                verdict = .faststart
                notes.append("index (moov) at the end of the file")
            case .unknown(let why):
                verdict = .unchecked
                notes.append("layout not read: \(why)")
            case nil:
                verdict = .unchecked
                notes.append("layout not read")
            }
        }
        self.notes = notes
    }

    /// Cover art carried as a video stream (when Jellyfin doesn't already call it EmbeddedImage).
    static func isPicture(_ stream: MediaStreamInfo) -> Bool {
        ["mjpeg", "png", "bmp", "gif"].contains((stream.codec ?? "").lowercased())
    }

    /// The Apple TV's decoders, in AppleTVProfile's terms, plus what its
    /// hardware refuses inside those codecs: H.264 beyond 8-bit 4:2:0
    /// (High 10, 4:2:2, 4:4:4), HEVC beyond Main 10. Targets keep what the
    /// source has: HEVC Main 10 for deep color, HDR or beyond 1080p; lossless
    /// audio stays lossless (FLAC); surround stays surround (E-AC-3).
    static func action(for stream: MediaStreamInfo, inMP4: Bool, hasMovie: Bool = true) -> StreamAction {
        let codec = (stream.codec ?? "").lowercased()
        switch stream.type {
        case "Video":
            let profile = (stream.profile ?? "").lowercased()
            // A picture beside the movie is its cover; alone, it is the movie (an old camera's Motion-JPEG).
            if isPicture(stream) { return !hasMovie ? .encode(videoTarget(stream)) : inMP4 ? .copy : .leaveOut("cover picture") }
            switch codec {
            case "h264":
                let pixel = (stream.pixelFormat ?? "").lowercased()
                let deep = (stream.bitDepth ?? 8) > 8 || profile.contains("10") || profile.contains("4:2:2") || profile.contains("4:4:4")
                    || (!pixel.isEmpty && !["yuv420p", "yuvj420p", "nv12"].contains(pixel))
                return deep ? .encode(videoTarget(stream)) : .copy
            case "hevc":
                if profile.contains("rext") || profile.contains("4:4:4") || profile.contains("4:2:2") || (stream.bitDepth ?? 8) > 10 {
                    return .encode("hevc")
                }
                // Dolby Vision (profiles 5 and 8) plays only under its own tag;
                // as hvc1, profile 5 shows purple and green. Profile 7 (with
                // an enhancement layer) plays as its HDR10 base: plain hvc1.
                // A file already tagged dvh1/dvhe is Dolby Vision even when
                // Jellyfin didn't say so: never downgrade its tag.
                let range = stream.videoRangeType ?? ""
                let current = (stream.codecTag ?? "").lowercased()
                let unknown = range.isEmpty || range.lowercased() == "unknown"
                let dolby = range.hasPrefix("DOVI") || (unknown && ["dvh1", "dvhe"].contains(current))
                let tag = dolby && !range.hasPrefix("DOVIWithEL") ? "dvh1" : "hvc1"
                return current == tag ? .copy : .retag(tag)
            default:
                return .encode(videoTarget(stream))
            }
        case "Audio":
            if audioCodecs.contains(codec) { return .copy }
            let profile = (stream.profile ?? "").lowercased()
            let lossless = codec == "truehd" || codec.hasPrefix("pcm_") || codec == "wavpack" || codec == "ape"
                || (codec == "dts" && profile.contains("ma"))
            if lossless { return .encode("flac") }
            // E-AC-3 keeps 5.1 for a receiver; ffmpeg's encoder stops at 6
            // channels, so 7.1 goes to AAC, which keeps all eight.
            let channels = stream.channels ?? 2
            return channels > 2 && channels <= 6 ? .encode("eac3") : .encode("aac")
        case "Subtitle":
            if codec == "mov_text" { return .copy }
            if textSubtitles.contains(codec) { return inMP4 ? .copy : .toMovText }
            // Already in the MP4: a faststart rewrite carries it over as it is.
            return inMP4 ? .copy : .leaveOut("picture subtitles can't go into MP4")
        case "EmbeddedImage":
            return inMP4 ? .copy : .leaveOut("cover picture")
        default:
            // Data and font tracks.
            return inMP4 ? .copy : .leaveOut("\(stream.type.lowercased()) track")
        }
    }

    /// HEVC (Main 10) when H.264 would lose something: more than 8 bits,
    /// HDR, or more than 1080p. Else H.264, which every device plays.
    static func videoTarget(_ stream: MediaStreamInfo) -> String {
        let hdr = !["", "sdr", "unknown"].contains((stream.videoRangeType ?? "").lowercased())
        return (stream.bitDepth ?? 8) > 8 || hdr || (stream.width ?? 0) > 1920 ? "hevc" : "h264"
    }

    /// Reads an MP4's top-level boxes until `moov` or `mdat` turns up.
    /// `read(offset, count)` returns up to `count` bytes from `offset`; a
    /// handful of 16-byte reads, never the media itself.
    public static func layout(size: Int64?, read: (Int64, Int) async throws -> Data) async throws -> MP4Layout {
        var offset: Int64 = 0
        for _ in 0..<32 {
            if let size, offset >= size { return .unknown("no moov or mdat") }
            let header = try await read(offset, 16)
            guard header.count >= 8 else { return .unknown("file ends inside a box header") }
            let bytes = [UInt8](header)
            var boxSize = Int64(bytes[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            if boxSize == 1 {
                guard bytes.count >= 16 else { return .unknown("short 64-bit box header") }
                let large = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard large >= 16, large <= UInt64(Int64.max) else { return .unknown("bad box size") }
                boxSize = Int64(large)
            }
            switch type {
            case "moov": return .moovFirst
            case "mdat": return .moovLast
            default: break
            }
            // Size 0 means "to the end of the file": nothing follows it.
            guard boxSize >= 8 else { return .unknown(boxSize == 0 ? "\(type) box runs to the end" : "bad box size") }
            if let size, boxSize > size - offset { return .unknown("\(type) box runs past the end") }
            let (next, overflow) = offset.addingReportingOverflow(boxSize)
            if overflow { return .unknown("bad box size") }
            offset = next
        }
        return .unknown("too many boxes before the media")
    }
}

/// The whole library's checks, counted the way the CLI reports them.
public struct MediaReport: Sendable {
    public var checks: [MediaCheck]

    public init(checks: [MediaCheck]) {
        // The most work first; titles in order within each.
        self.checks = checks.sorted { $0.verdict != $1.verdict ? $0.verdict > $1.verdict : $0.file.title < $1.file.title }
    }

    public func count(_ verdict: MediaVerdict) -> Int { checks.count { $0.verdict == verdict } }

    public func bytes(_ verdict: MediaVerdict) -> Int64 {
        checks.filter { $0.verdict == verdict }.reduce(0) { $0 + ($1.file.size ?? 0) }
    }
}

struct MediaItemDTO: Decodable {
    let item: Item
    let sources: [SourceDTO]

    struct SourceDTO: Decodable {
        let id: String
        let container: String?
        let path: String?
        let size: Int64?
        let `protocol`: String?
        let videoType: String?
        let mediaStreams: [MediaStreamInfo]?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case container = "Container"
            case path = "Path"
            case size = "Size"
            case `protocol` = "Protocol"
            case videoType = "VideoType"
            case mediaStreams = "MediaStreams"
        }
    }

    enum CodingKeys: String, CodingKey { case sources = "MediaSources" }

    init(from decoder: any Decoder) throws {
        item = try Item(from: decoder)
        sources = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([SourceDTO].self, forKey: .sources) ?? []
    }

    var files: [MediaFile] {
        let title = item.kind == .episode ? [item.seriesName, item.episodeTitle(.default)].compactMap { $0 }.joined(separator: " · ") : item.displayName
        return sources.map {
            MediaFile(itemId: item.id, sourceId: $0.id, title: title, container: $0.container, path: $0.path, size: $0.size,
                      protocol: $0.protocol, videoType: $0.videoType, streams: $0.mediaStreams ?? [], userData: item.userData)
        }
    }
}

struct MediaItemsPage: Decodable {
    let items: [MediaItemDTO]
    let totalRecordCount: Int?
    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

public enum MediaReportError: Error, Equatable, Sendable {
    /// Fewer items came back than the server counted: the library changed
    /// while it was read (or pages shifted). Run it again.
    case incomplete(read: Int, total: Int)
}

extension JellyfinClient {
    /// Every video file the profile can see (or one library's), with its
    /// streams, in pages until an empty one (a server may cap the page size).
    /// The server counts the items once; a read that comes back short of
    /// that count (items moved between pages) throws rather than report a
    /// library with a gap. Read-only, and a regular user's view: no admin.
    public func mediaFiles(userId: String, libraryId: String? = nil, pageSize: Int = 200, withUserData: Bool = false) async throws -> [MediaFile] {
        var files: [MediaFile] = []
        var seen: Set<String> = []
        var items: Set<String> = []
        var total: Int?
        var start = 0
        while true {
            var query = [
                URLQueryItem(name: "userId", value: userId),
                URLQueryItem(name: "recursive", value: "true"),
                URLQueryItem(name: "includeItemTypes", value: "Movie,Episode,Video"),
                URLQueryItem(name: "isMissing", value: "false"),
                URLQueryItem(name: "fields", value: "MediaSources"),
                URLQueryItem(name: "enableImages", value: "false"),
                URLQueryItem(name: "enableUserData", value: withUserData ? "true" : "false"),
                URLQueryItem(name: "sortBy", value: "SortName"),
                URLQueryItem(name: "startIndex", value: String(start)),
                URLQueryItem(name: "limit", value: String(pageSize)),
                URLQueryItem(name: "enableTotalRecordCount", value: start == 0 ? "true" : "false"),
            ]
            if let libraryId { query.append(URLQueryItem(name: "parentId", value: libraryId)) }
            let page: MediaItemsPage = try await get("/Items", query: query)
            if start == 0 { total = page.totalRecordCount }
            items.formUnion(page.items.map(\.item.id))
            if page.items.isEmpty {
                if let total, items.count < total { throw MediaReportError.incomplete(read: items.count, total: total) }
                return files
            }
            for file in page.items.flatMap(\.files) where seen.insert(file.sourceId).inserted { files.append(file) }
            start += page.items.count
            // The server said how many there are: no extra request for an empty page.
            if let total, items.count >= total { return files }
        }
    }

    /// `count` bytes of a file from `offset` (a Range request on the static
    /// stream, token in the header). Only a partial answer (206) starting at
    /// `offset` is read; anything else is refused before its body is fetched,
    /// so a server that ignores the range never sends the whole file.
    public func fileBytes(itemId: String, sourceId: String, offset: Int64, count: Int) async throws -> Data {
        var request = URLRequest(url: url("/Videos/\(itemId)/stream", query: [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: sourceId),
        ]))
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let (data, status, contentRange) = try await transport.performRange(request, maxBytes: count)
        if status == 401 { throw JellyfinError.unauthorized }
        guard status == 206 else { throw JellyfinError.http(status: status) }
        // "bytes 100-115/5000": the part asked for, not some other one.
        guard contentRange?.hasPrefix("bytes \(offset)-") == true else { throw JellyfinError.decoding("Content-Range \(contentRange ?? "missing")") }
        return data.prefix(count)
    }

    /// Checks every file: streams from the scan, plus the box layout of each
    /// MP4 that plays as it is otherwise (a few small reads each, `parallel`
    /// files at a time).
    public func mediaReport(userId: String, libraryId: String? = nil, readLayout: Bool = true, parallel: Int = 4) async throws -> MediaReport {
        let files = try await mediaFiles(userId: userId, libraryId: libraryId)
        let checks = try await withThrowingTaskGroup(of: MediaCheck.self) { group in
            var checks: [MediaCheck] = []
            var pending = files[...]
            func add(_ file: MediaFile) {
                group.addTask {
                    // Only a file whose streams already play needs its start read.
                    let unread = MediaCheck(file: file, layout: nil)
                    guard readLayout, unread.verdict == .unchecked else { return unread }
                    let layout: MP4Layout
                    do {
                        layout = try await MediaCheck.layout(size: file.size) { offset, count in
                            try await fileBytes(itemId: file.itemId, sourceId: file.sourceId, offset: offset, count: count)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch JellyfinError.unauthorized {
                        // Signed out: every read after this fails too; no half report.
                        throw JellyfinError.unauthorized
                    } catch {
                        layout = .unknown("read failed: \(error)")
                    }
                    return MediaCheck(file: file, layout: layout)
                }
            }
            for _ in 0..<max(1, parallel) { if let next = pending.popFirst() { add(next) } }
            for try await check in group {
                checks.append(check)
                if let next = pending.popFirst() { add(next) }
            }
            return checks
        }
        return MediaReport(checks: checks)
    }
}
