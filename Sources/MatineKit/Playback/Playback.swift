import Foundation

/// What a device tells the server it can play, and how much it should be sent.
/// The containers and codecs are AVPlayer's own on every Apple device; what
/// differs is the name the server's dashboard shows and the ceiling on bitrate
/// and picture width (a phone on a metered connection asks for less).
public struct PlaybackProfile: Sendable, Hashable {
    public var name: String
    public var maxBitrate: Int
    /// A picture wider than this is transcoded down (nil: no cap).
    public var maxWidth: Int?

    public init(name: String, maxBitrate: Int, maxWidth: Int? = nil) {
        self.name = name
        self.maxBitrate = maxBitrate
        self.maxWidth = maxWidth
    }

    /// The Apple TV's, unchanged: a living-room screen on the home network.
    public static let appleTV = PlaybackProfile(name: "Matine Apple TV", maxBitrate: 120_000_000)

    /// An iPhone or iPad ("iPhone", "iPad"). On a metered (cellular or
    /// Personal Hotspot) path: 6 Mbit/s and 1280 px wide at most; otherwise 40
    /// Mbit/s and no size cap: a 4K file the device plays as it is must not
    /// cost the NAS a transcode just to shrink it.
    public static func phone(device: String, constrained: Bool) -> PlaybackProfile {
        constrained
            ? PlaybackProfile(name: "Matine \(device)", maxBitrate: 6_000_000, maxWidth: 1280)
            : PlaybackProfile(name: "Matine \(device)", maxBitrate: 40_000_000)
    }
}

/// The Apple devices' shared containers and codecs. Everything else the
/// server remuxes or transcodes to HLS (fMP4 segments). Kept in step with the
/// device-profile list Sashimi (MIT) settled on; see THIRD_PARTY.md. The
/// profile is ours, not copied code.
public enum AppleTVProfile {
    static let directContainers = "mp4,m4v,mov"
    static let videoCodecs = "h264,hevc"
    static let audioCodecs = "aac,ac3,eac3,mp3,alac,flac"

    struct DeviceProfile: Encodable, Sendable {
        let Name: String
        let MaxStreamingBitrate: Int
        let MaxStaticBitrate: Int
        let DirectPlayProfiles = [
            DirectPlay(Container: directContainers, VideoCodec: videoCodecs, AudioCodec: audioCodecs),
        ]
        let TranscodingProfiles = [
            Transcoding(),
        ]
        /// A wider picture is not played as it is: the server transcodes it down.
        let CodecProfiles: [Codec]
        /// Text subtitles as WebVTT inside the HLS stream, so they appear in
        /// the system player's own subtitle menu. (A file that plays directly
        /// keeps only the subtitle tracks it carries.)
        let SubtitleProfiles = [
            Subtitle(Format: "vtt", Method: "Hls"),
        ]

        init(_ profile: PlaybackProfile = .appleTV) {
            Name = profile.name
            MaxStreamingBitrate = profile.maxBitrate
            MaxStaticBitrate = profile.maxBitrate
            CodecProfiles = profile.maxWidth.map { width in
                [Codec(Conditions: [Condition(Value: String(width))])]
            } ?? []
        }
    }

    struct Codec: Encodable, Sendable {
        let `Type` = "Video"
        let Conditions: [Condition]
    }

    struct Condition: Encodable, Sendable {
        let Condition = "LessThanEqual"
        let Property = "Width"
        let Value: String
        let IsRequired = false
    }

    struct DirectPlay: Encodable, Sendable {
        let Container: String
        let `Type` = "Video"
        let VideoCodec: String
        let AudioCodec: String
    }

    struct Transcoding: Encodable, Sendable {
        let Container = "mp4"
        let `Type` = "Video"
        let VideoCodec = videoCodecs
        let AudioCodec = "aac,ac3,eac3"
        let `Protocol` = "hls"
        let Context = "Streaming"
        let MinSegments = 2
        let BreakOnNonKeyFrames = true
    }

    struct Subtitle: Encodable, Sendable {
        let Format: String
        let Method: String
    }
}

/// How the stream reaches the player, as reported back to the server: the
/// file itself, or the server's HLS (a remux or a transcode; the server knows
/// which, and reports it the same way the web app does).
public enum PlayMethod: String, Codable, Sendable {
    case directPlay = "DirectPlay"
    case transcode = "Transcode"
}

/// One ready-to-play stream for an item, as the server agreed to it.
public struct PlaybackPlan: Sendable, Hashable {
    public let itemId: String
    public let mediaSourceId: String
    public let playSessionId: String?
    public let method: PlayMethod
    /// Fetch with `JellyfinClient.streamHeaders`; it carries no token.
    public let url: URL
    public let startTicks: Int64
}

struct MediaSource: Decodable {
    let id: String
    let supportsDirectPlay: Bool?
    let transcodingURL: String?
    let eTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case supportsDirectPlay = "SupportsDirectPlay"
        case transcodingURL = "TranscodingUrl"
        case eTag = "ETag"
    }
}

struct PlaybackInfoResponse: Decodable {
    let mediaSources: [MediaSource]?
    let playSessionId: String?
    let errorCode: String?
    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
        case errorCode = "ErrorCode"
    }
}

public enum PlaybackError: Error, Equatable, Sendable {
    /// The server can't offer this item in any form the Apple TV plays.
    case unplayable(String?)
}

/// Where the player is, sent to the server so resume and watched state match
/// the web app. Ticks are 100 ns.
public struct PlaybackReport: Encodable, Sendable, Equatable {
    public var ItemId: String
    public var MediaSourceId: String
    public var PlaySessionId: String?
    public var PositionTicks: Int64
    public var IsPaused: Bool
    public var PlayMethod: String
    public var CanSeek = true

    public init(plan: PlaybackPlan, positionTicks: Int64, isPaused: Bool) {
        ItemId = plan.itemId
        MediaSourceId = plan.mediaSourceId
        PlaySessionId = plan.playSessionId
        PositionTicks = positionTicks
        IsPaused = isPaused
        PlayMethod = plan.method.rawValue
    }
}

public enum Ticks {
    public static let perSecond: Int64 = 10_000_000
    /// 0 for a time the player doesn't know yet (NaN, infinite) or a negative
    /// one, rather than trapping on the conversion.
    public static func from(seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((min(seconds, 1e9) * Double(perSecond)).rounded())
    }
    public static func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(perSecond) }
}

/// Removes access tokens from text before it is shown: Jellyfin writes the
/// caller's token into the HLS playlists it serves (`ApiKey=…`, `api_key=…`).
public enum Redaction {
    public static func tokens(in text: String) -> String {
        text.replacingOccurrences(of: #"(?i)(api_?key=)[^&"\s]+"#, with: "$1REDACTED", options: .regularExpression)
    }
}

extension JellyfinClient {
    /// Headers the player must send on every stream request (the playlist,
    /// its segments, a static file). The token travels here, never in the URL.
    public var streamHeaders: [String: String] {
        ["Authorization": authorizationHeader]
    }

    /// Asks the server how to play `itemId` on this Apple TV and returns the
    /// stream: the file itself when it plays as-is, else the server's HLS.
    /// `allowDirectPlay: false` forces HLS: the retry for a file the server
    /// thought playable that AVPlayer refused (an HEVC track tagged `hev1`,
    /// say), since the server's remux fixes the tagging.
    public func playbackPlan(
        itemId: String, userId: String, startTicks: Int64 = 0, allowDirectPlay: Bool = true,
        profile: PlaybackProfile = .appleTV
    ) async throws -> PlaybackPlan {
        struct Body: Encodable, Sendable {
            let UserId: String
            let StartTimeTicks: Int64
            let EnableDirectPlay: Bool
            let MaxStreamingBitrate: Int
            let DeviceProfile: AppleTVProfile.DeviceProfile
        }
        let data = try await send("POST", "/Items/\(itemId)/PlaybackInfo", query: [
            URLQueryItem(name: "userId", value: userId),
        ], body: Body(UserId: userId, StartTimeTicks: startTicks, EnableDirectPlay: allowDirectPlay,
                   MaxStreamingBitrate: profile.maxBitrate, DeviceProfile: AppleTVProfile.DeviceProfile(profile)))
        let info: PlaybackInfoResponse
        do {
            info = try JSONDecoder().decode(PlaybackInfoResponse.self, from: data)
        } catch {
            throw JellyfinError.decoding("/Items/{itemId}/PlaybackInfo: \(error)")
        }
        guard let source = info.mediaSources?.first else { throw PlaybackError.unplayable(info.errorCode) }
        return try plan(for: source, itemId: itemId, playSessionId: info.playSessionId, startTicks: startTicks)
    }

    func plan(for source: MediaSource, itemId: String, playSessionId: String?, startTicks: Int64) throws -> PlaybackPlan {
        if source.supportsDirectPlay == true {
            var query = [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "mediaSourceId", value: source.id),
            ]
            if let playSessionId { query.append(URLQueryItem(name: "playSessionId", value: playSessionId)) }
            if let tag = source.eTag { query.append(URLQueryItem(name: "tag", value: tag)) }
            return PlaybackPlan(
                itemId: itemId, mediaSourceId: source.id, playSessionId: playSessionId, method: .directPlay,
                url: url("/Videos/\(itemId)/stream", query: query), startTicks: startTicks
            )
        }
        guard let transcoding = source.transcodingURL, let hls = hlsURL(transcoding) else {
            throw PlaybackError.unplayable(nil)
        }
        return PlaybackPlan(
            itemId: itemId, mediaSourceId: source.id, playSessionId: playSessionId, method: .transcode,
            url: hls, startTicks: startTicks
        )
    }

    /// The server's HLS URL (relative to the server), with any token it put in
    /// the query removed: the player sends `streamHeaders` instead.
    func hlsURL(_ relative: String) -> URL? {
        guard var components = URLComponents(string: relative) else { return nil }
        components.queryItems = components.queryItems?.filter {
            !["api_key", "apikey"].contains($0.name.lowercased())
        }
        let base = url("")
        guard let path = components.url?.absoluteString else { return nil }
        return URL(string: base.absoluteString + (path.hasPrefix("/") ? path : "/" + path))
    }

    public func reportStart(_ report: PlaybackReport) async throws {
        _ = try await send("POST", "/Sessions/Playing", body: report)
    }

    public func reportProgress(_ report: PlaybackReport) async throws {
        _ = try await send("POST", "/Sessions/Playing/Progress", body: report)
    }

    public func reportStopped(_ report: PlaybackReport) async throws {
        _ = try await send("POST", "/Sessions/Playing/Stopped", body: report)
    }
}
