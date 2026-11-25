import Foundation

/// Every call and field MatineKit relies on, so `matine api-check` can compare
/// them with a server's live OpenAPI spec after a Jellyfin upgrade. A unit test
/// keeps this list in step with what the client actually sends.
public enum APIManifest {
    public struct Call: Sendable, Hashable {
        public let method: String
        public let path: String
        public let query: [String]
    }

    public static let calls: [Call] = [
        Call(method: "GET", path: "/System/Info/Public", query: []),
        Call(method: "POST", path: "/Users/AuthenticateByName", query: []),
        Call(method: "POST", path: "/Sessions/Logout", query: []),
        Call(method: "GET", path: "/QuickConnect/Enabled", query: []),
        Call(method: "POST", path: "/QuickConnect/Initiate", query: []),
        Call(method: "GET", path: "/QuickConnect/Connect", query: ["secret"]),
        Call(method: "POST", path: "/QuickConnect/Authorize", query: ["code"]),
        Call(method: "POST", path: "/Users/AuthenticateWithQuickConnect", query: []),
        Call(method: "GET", path: "/UserViews", query: ["userId"]),
        Call(method: "GET", path: "/UserItems/Resume", query: ["userId", "mediaTypes", "parentId"] + tileQuery),
        Call(method: "GET", path: "/Shows/NextUp", query: ["userId", "seriesId"] + tileQuery),
        Call(method: "GET", path: "/Items/Latest", query: ["userId", "parentId"] + tileQuery),
        Call(method: "GET", path: "/Items", query: [
            "userId", "filters", "recursive", "includeItemTypes", "sortBy", "sortOrder", "parentId", "startIndex",
            "enableTotalRecordCount", "isMissing", "enableImages", "personIds", "ids",
        ] + tileQuery),
        Call(method: "GET", path: "/Shows/{seriesId}/Episodes", query: ["userId", "enableUserData", "enableImages", "isMissing", "seasonId"] + tileQuery),
        Call(method: "GET", path: "/Shows/{seriesId}/Seasons", query: ["userId", "enableUserData", "enableImages", "isMissing"]),
        Call(method: "POST", path: "/Items/{itemId}/PlaybackInfo", query: ["userId"]),
        Call(method: "GET", path: "/Videos/{itemId}/stream", query: ["static", "mediaSourceId", "playSessionId", "tag"]),
        Call(method: "POST", path: "/Sessions/Playing", query: []),
        Call(method: "POST", path: "/Sessions/Playing/Progress", query: []),
        Call(method: "POST", path: "/Sessions/Playing/Stopped", query: []),
        Call(method: "POST", path: "/UserFavoriteItems/{itemId}", query: ["userId"]),
        Call(method: "DELETE", path: "/UserFavoriteItems/{itemId}", query: ["userId"]),
        Call(method: "POST", path: "/UserPlayedItems/{itemId}", query: ["userId"]),
        Call(method: "POST", path: "/UserItems/{itemId}/UserData", query: ["userId"]),
        Call(method: "GET", path: "/Items/{itemId}", query: ["userId"]),
        Call(method: "GET", path: "/Items/{itemId}/Ancestors", query: ["userId"]),
        Call(method: "GET", path: "/Items/{itemId}/Download", query: []),
        Call(method: "GET", path: "/Videos/{itemId}/stream.{container}", query: [
            "mediaSourceId", "static", "videoCodec", "audioCodec", "allowVideoStreamCopy", "allowAudioStreamCopy", "deviceId",
        ]),
        Call(method: "POST", path: "/Sessions/Capabilities/Full", query: []),
        Call(method: "GET", path: "/Sessions", query: ["controllableByUserId", "activeWithinSeconds"]),
        Call(method: "POST", path: "/Sessions/{sessionId}/Playing", query: ["playCommand", "itemIds", "startPositionTicks"]),
        Call(method: "POST", path: "/Sessions/{sessionId}/Playing/{command}", query: ["seekPositionTicks"]),
        Call(method: "GET", path: "/Items/{itemId}/Images/{imageType}", query: ["tag", "maxHeight", "quality"]),
    ]

    static let tileQuery = ["fields", "enableImageTypes", "imageTypeLimit", "enableUserData", "limit"]

    /// Response fields decoded, by the spec's schema name.
    public static let fields: [String: [String]] = [
        "BaseItemDto": [
            "Id", "Name", "Type", "SeriesId", "ParentId", "SeriesName", "ParentIndexNumber", "IndexNumber", "ProductionYear",
            "Overview", "OriginalTitle", "Genres", "Tags", "RunTimeTicks", "CollectionType", "PrimaryImageAspectRatio", "ImageTags", "BackdropImageTags",
            "SeriesPrimaryImageTag", "ParentBackdropItemId", "ParentBackdropImageTags", "ParentLogoItemId", "ParentLogoImageTag", "ImageBlurHashes", "UserData",
            "People", "OfficialRating", "CommunityRating", "Taglines", "Studios",
        ],
        "BaseItemPerson": ["Id", "Name", "Role", "Type", "PrimaryImageTag"],
        "NameGuidPair": ["Name"],
        "UserItemDataDto": ["Played", "IsFavorite", "PlayedPercentage", "PlaybackPositionTicks", "UnplayedItemCount", "LastPlayedDate"],
        "UpdateUserItemDataDto": ["PlaybackPositionTicks"],
        "UserDto": ["Id", "Name", "ServerId"],
        "AuthenticationResult": ["User", "AccessToken"],
        "QuickConnectResult": ["Authenticated", "Secret", "Code"],
        "QuickConnectDto": ["Secret"],
        "AuthenticateUserByName": ["Username", "Pw"],
        "PublicSystemInfo": ["Id", "ServerName", "Version"],
        "BaseItemDtoQueryResult": ["Items", "TotalRecordCount"],
        "PlaybackInfoDto": ["UserId", "StartTimeTicks", "MaxStreamingBitrate", "DeviceProfile", "EnableDirectPlay"],
        "PlaybackInfoResponse": ["MediaSources", "PlaySessionId", "ErrorCode"],
        "MediaSourceInfo": ["Id", "SupportsDirectPlay", "TranscodingUrl", "ETag", "Container", "Path", "Size", "Protocol", "VideoType", "MediaStreams"],
        "MediaStream": ["Index", "Type", "Codec", "CodecTag", "Profile", "BitDepth", "PixelFormat", "Width", "VideoRangeType", "Channels", "Language", "IsExternal"],
        "DeviceProfile": ["Name", "MaxStreamingBitrate", "MaxStaticBitrate", "DirectPlayProfiles", "TranscodingProfiles", "CodecProfiles", "SubtitleProfiles"],
        "CodecProfile": ["Type", "Conditions"],
        "ProfileCondition": ["Condition", "Property", "Value", "IsRequired"],
        "DirectPlayProfile": ["Container", "Type", "VideoCodec", "AudioCodec"],
        "TranscodingProfile": ["Container", "Type", "VideoCodec", "AudioCodec", "Protocol", "Context", "MinSegments", "BreakOnNonKeyFrames"],
        "SubtitleProfile": ["Format", "Method"],
        "PlaybackStartInfo": ["ItemId", "MediaSourceId", "PlaySessionId", "PositionTicks", "IsPaused", "PlayMethod", "CanSeek"],
        "PlaybackProgressInfo": ["ItemId", "MediaSourceId", "PlaySessionId", "PositionTicks", "IsPaused", "PlayMethod", "CanSeek"],
        "ClientCapabilitiesDto": ["PlayableMediaTypes", "SupportedCommands", "SupportsMediaControl"],
        "SessionInfoDto": ["Id", "DeviceName", "Client", "UserName", "DeviceId", "SupportsRemoteControl", "NowPlayingItem"],
        // The WebSocket messages (the spec lists them, though not /socket itself).
        "PlayRequest": ["ItemIds", "StartPositionTicks", "PlayCommand"],
        "PlaystateRequest": ["Command", "SeekPositionTicks"],
        "ForceKeepAliveMessage": ["Data", "MessageType"],
        "PlayMessage": ["Data", "MessageType"],
        "PlaystateMessage": ["Data", "MessageType"],
        "PlaybackStopInfo": ["ItemId", "MediaSourceId", "PlaySessionId", "PositionTicks"],
    ]

    /// What `spec` (a server's `/api-docs/openapi.json`) no longer has that we use.
    /// Empty means every call, parameter and field is still there.
    public static func problems(in spec: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: spec) as? [String: Any],
              let paths = root["paths"] as? [String: Any],
              let schemas = (root["components"] as? [String: Any])?["schemas"] as? [String: Any]
        else { return ["not an OpenAPI document"] }

        var found: [String] = []
        for call in calls {
            guard let operation = (paths[call.path] as? [String: Any])?[call.method.lowercased()] as? [String: Any] else {
                found.append("\(call.method) \(call.path): gone")
                continue
            }
            let parameters = Set(((operation["parameters"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String })
            for name in call.query where !parameters.contains(name) {
                found.append("\(call.method) \(call.path): no query parameter \(name)")
            }
        }
        for (schema, names) in fields.sorted(by: { $0.key < $1.key }) {
            guard let properties = (schemas[schema] as? [String: Any])?["properties"] as? [String: Any] else {
                found.append("schema \(schema): gone")
                continue
            }
            for name in names where properties[name] == nil {
                found.append("schema \(schema): no field \(name)")
            }
        }
        return found
    }
}
