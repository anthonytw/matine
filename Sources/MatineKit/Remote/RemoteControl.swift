import Foundation

/// What a phone (or any Jellyfin controller) can ask this Apple TV to do,
/// from Jellyfin's session remote control. Only what Matiné implements is
/// decoded; every other message is ignored.
public enum RemoteCommand: Sendable, Equatable {
    /// Play one of `itemIds` (PlayNow): the one at `startIndex`, else the
    /// first. Matiné has no queue and never plays on by itself, so the rest
    /// of the list is dropped. See `JellyfinClient.remotePlayTarget`.
    case play(itemIds: [String], startIndex: Int?, startTicks: Int64)
    case pause
    case unpause
    case playPause
    case stop
    case seek(ticks: Int64)
}

/// One message from the server's WebSocket, as far as Matiné cares.
public enum RemoteMessage: Sendable, Equatable {
    case command(RemoteCommand)
    /// The server wants a KeepAlive from us every `seconds / 2`.
    case forceKeepAlive(seconds: Int)
    case ignored

    /// Decodes `{"MessageType": "...", "Data": ...}`. Never throws: anything
    /// unknown, malformed or unsupported (PlayNext, Rewind, GeneralCommand...)
    /// is `.ignored`.
    public static func decode(_ data: Data) -> RemoteMessage {
        struct Envelope: Decodable {
            let MessageType: String
            let Data: Payload?
        }
        struct Payload: Decodable {
            var ItemIds: [String]?
            var StartPositionTicks: Int64?
            var StartIndex: Int?
            var PlayCommand: String?
            var Command: String?
            var SeekPositionTicks: Int64?
            var seconds: Int?

            enum Keys: String, CodingKey {
                case ItemIds, StartPositionTicks, StartIndex, PlayCommand, Command, SeekPositionTicks
            }

            init(from decoder: any Decoder) throws {
                // ForceKeepAlive's Data is a bare number.
                if let single = try? decoder.singleValueContainer(), let number = try? single.decode(Int.self) {
                    seconds = number
                    return
                }
                let c = try decoder.container(keyedBy: Keys.self)
                ItemIds = try? c.decodeIfPresent([String].self, forKey: .ItemIds)
                StartPositionTicks = try? c.decodeIfPresent(Int64.self, forKey: .StartPositionTicks)
                StartIndex = try? c.decodeIfPresent(Int.self, forKey: .StartIndex)
                PlayCommand = try? c.decodeIfPresent(String.self, forKey: .PlayCommand)
                Command = try? c.decodeIfPresent(String.self, forKey: .Command)
                SeekPositionTicks = try? c.decodeIfPresent(Int64.self, forKey: .SeekPositionTicks)
            }
        }
        guard let message = try? JSONDecoder().decode(Envelope.self, from: data) else { return .ignored }
        switch message.MessageType {
        case "ForceKeepAlive":
            guard let seconds = message.Data?.seconds, seconds > 0 else { return .ignored }
            return .forceKeepAlive(seconds: seconds)
        case "Play":
            guard let payload = message.Data, payload.PlayCommand == "PlayNow",
                  let ids = payload.ItemIds, !ids.isEmpty else { return .ignored }
            return .command(.play(itemIds: ids, startIndex: payload.StartIndex, startTicks: max(0, payload.StartPositionTicks ?? 0)))
        case "Playstate":
            switch message.Data?.Command {
            case "Pause": return .command(.pause)
            case "Unpause": return .command(.unpause)
            case "PlayPause": return .command(.playPause)
            case "Stop": return .command(.stop)
            case "Seek":
                guard let ticks = message.Data?.SeekPositionTicks else { return .ignored }
                return .command(.seek(ticks: max(0, ticks)))
            default: return .ignored
            }
        default:
            return .ignored
        }
    }
}

/// How long to wait before reconnecting: 1 s, doubling, at most a minute,
/// with up to 20% either way so a room of Apple TVs doesn't reconnect in step.
public enum ReconnectBackoff {
    public static let cap: TimeInterval = 60

    /// `failures` is how many attempts in a row have failed (1 after the first).
    /// `jitter` is a random number in 0...1.
    public static func delay(afterFailures failures: Int, jitter: Double = 0.5) -> TimeInterval {
        let exponent = min(max(failures - 1, 0), 10)
        let base = min(cap, pow(2, Double(exponent)))
        return base * (0.8 + 0.4 * min(max(jitter, 0), 1))
    }
}

extension ReconnectBackoff {
    /// The failure count after a connection that lasted `connectionLasted`
    /// seconds: a connection that held for half a minute starts over.
    public static func failures(after previous: Int, connectionLasted: TimeInterval) -> Int {
        connectionLasted > 30 ? 1 : previous + 1
    }
}

/// A session the signed-in user may control (the TV's, from a phone).
public struct RemoteSession: Sendable, Decodable, Equatable {
    public let id: String
    public let deviceName: String?
    public let client: String?
    public let userName: String?
    public let deviceId: String?
    public let supportsRemoteControl: Bool
    /// What the session is playing now; nil when it is idle.
    public let nowPlayingItemId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", deviceName = "DeviceName", client = "Client", userName = "UserName", deviceId = "DeviceId"
        case supportsRemoteControl = "SupportsRemoteControl", nowPlaying = "NowPlayingItem"
    }

    private struct NowPlaying: Decodable {
        let Id: String?
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        userName = try c.decodeIfPresent(String.self, forKey: .userName)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        supportsRemoteControl = try c.decode(Bool.self, forKey: .supportsRemoteControl)
        nowPlayingItemId = try? c.decodeIfPresent(NowPlaying.self, forKey: .nowPlaying)?.Id
    }
}

/// A television a phone can send a video to.
public struct TVTarget: Sendable, Equatable, Identifiable {
    public let id: String
    /// What a menu or message calls it: the device name, with the profile
    /// name added ("Apple TV · luz") or a number when several TVs share it.
    public let name: String
    /// Whether something is playing on it right now.
    public let isPlaying: Bool

    /// How far back a session counts as alive (Jellyfin's own default is
    /// 960 seconds in its dashboard).
    public static let activeWithinSeconds = 960

    /// The TVs among `sessions`, for the phone whose device id is
    /// `ownDeviceId`: sessions that take remote control, are not this phone
    /// (by device id) and are not another phone or tablet running Matiné, and
    /// are Matiné on an Apple TV or another TV app (its client name says
    /// "TV", as Jellyfin for Android TV or tvOS do). Browsers and the like
    /// are left out. Matiné first, then by name.
    public static func tvs(in sessions: [RemoteSession], ownDeviceId: String) -> [TVTarget] {
        let candidates = sessions.filter { session in
            guard session.supportsRemoteControl, session.deviceId != ownDeviceId else { return false }
            let client = session.client ?? ""
            let device = session.deviceName ?? ""
            if client == "Matine" { return !["iPhone", "iPad"].contains(device) }
            return client.range(of: "tv", options: .caseInsensitive) != nil
        }
        let ordered = candidates.sorted { a, b in
            let aOurs = a.client == "Matine", bOurs = b.client == "Matine"
            if aOurs != bOurs { return aOurs }
            let byName = (a.deviceName ?? "").localizedStandardCompare(b.deviceName ?? "")
            if byName != .orderedSame { return byName == .orderedAscending }
            return (a.userName ?? "").localizedStandardCompare(b.userName ?? "") == .orderedAscending
        }
        let names = ordered.map { $0.deviceName?.isEmpty == false ? $0.deviceName! : "TV" }
        let groups = Dictionary(grouping: ordered.indices, by: { names[$0] })
        var shown = names
        for (name, indices) in groups where indices.count > 1 {
            let users = indices.map { ordered[$0].userName ?? "" }
            if !users.contains(""), Set(users).count == users.count {
                for (index, user) in zip(indices, users) { shown[index] = "\(name) · \(user)" }
            } else {
                for (number, index) in indices.enumerated() { shown[index] = "\(name) \(number + 1)" }
            }
        }
        return zip(ordered, shown).map { TVTarget(id: $0.id, name: $1, isPlaying: $0.nowPlayingItemId != nil) }
    }
}

public enum RemotePlaystate: String, Sendable {
    case pause = "Pause", unpause = "Unpause", stop = "Stop", playPause = "PlayPause", seek = "Seek"
}

extension JellyfinClient {
    /// The commands the TV implements, by Jellyfin's names: Play (PlayNow) and PlayState.
    static let remoteCommands = ["Play", "PlayState"]

    struct Capabilities: Encodable, Sendable, Equatable {
        let PlayableMediaTypes = ["Video"]
        let SupportedCommands = JellyfinClient.remoteCommands
        let SupportsMediaControl = true
    }

    /// Tells the server this session can be remote controlled. Sent on every
    /// connect: the server forgets capabilities with the session.
    public func reportCapabilities() async throws {
        _ = try await send("POST", "/Sessions/Capabilities/Full", body: Capabilities())
    }

    /// Sessions `userId` may control, those that support remote control first.
    /// `activeWithinSeconds` leaves out sessions idle for longer.
    public func controllableSessions(userId: String, activeWithinSeconds: Int? = nil) async throws -> [RemoteSession] {
        var query = [URLQueryItem(name: "controllableByUserId", value: userId)]
        if let activeWithinSeconds { query.append(URLQueryItem(name: "activeWithinSeconds", value: String(activeWithinSeconds))) }
        let sessions: [RemoteSession] = try await get("/Sessions", query: query)
        return sessions.filter(\.supportsRemoteControl) + sessions.filter { !$0.supportsRemoteControl }
    }

    /// The TVs `userId` can send videos to right now, from this phone or
    /// tablet's point of view (its own session is never one of them).
    public func tvs(userId: String) async throws -> [TVTarget] {
        TVTarget.tvs(in: try await controllableSessions(userId: userId, activeWithinSeconds: TVTarget.activeWithinSeconds), ownDeviceId: identity.deviceId)
    }

    /// Asks `sessionId` to play an item now.
    public func sendPlay(sessionId: String, itemId: String, startTicks: Int64 = 0) async throws {
        var query = [
            URLQueryItem(name: "playCommand", value: "PlayNow"),
            URLQueryItem(name: "itemIds", value: itemId),
        ]
        if startTicks > 0 { query.append(URLQueryItem(name: "startPositionTicks", value: String(startTicks))) }
        _ = try await send("POST", "/Sessions/\(sessionId)/Playing", query: query)
    }

    public func sendPlaystate(sessionId: String, _ state: RemotePlaystate, seekTicks: Int64? = nil) async throws {
        var query: [URLQueryItem] = []
        if let seekTicks { query.append(URLQueryItem(name: "seekPositionTicks", value: String(seekTicks))) }
        _ = try await send("POST", "/Sessions/\(sessionId)/Playing/\(state.rawValue)", query: query)
    }

    /// The WebSocket upgrade request. The token goes in the Authorization
    /// header, never in the URL (Jellyfin also takes `?api_key=`; we don't use it).
    func socketRequest() -> URLRequest? {
        guard var components = URLComponents(url: url("/socket"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        return request
    }
}


/// What the TV decided to play for a Play command.
public struct RemotePlayTarget: Sendable {
    public let item: Item
    public let startTicks: Int64
}

extension RemoteCommand {
    /// Jellyfin ids: 32 hex digits, or the dashed GUID form. Anything else is
    /// never put in a request path.
    static func isJellyfinId(_ text: String) -> Bool {
        text.range(of: #"^([0-9a-fA-F]{32}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})$"#, options: .regularExpression) != nil
    }

    /// The id a Play names: `itemIds[startIndex]` when in range, else the
    /// first. Nil for another command or a malformed id.
    public var playItemId: String? {
        guard case .play(let ids, let index, _) = self else { return nil }
        let id = index.flatMap { ids.indices.contains($0) ? ids[$0] : nil } ?? ids.first
        return id.flatMap { Self.isJellyfinId($0) ? $0 : nil }
    }
}

extension JellyfinClient {
    /// What a Play command plays for `userId`, or nil when it can't: the named
    /// item (fetched as that user, so anything their account may not see
    /// fails), a series becoming its own next episode (resuming where it
    /// is), and only a movie, episode or video. Never more than one item.
    public func remotePlayTarget(_ command: RemoteCommand, userId: String) async -> RemotePlayTarget? {
        guard let id = command.playItemId, case .play(_, _, let startTicks) = command,
              var found = try? await item(id, userId: userId) else { return nil }
        var start = startTicks
        if found.kind == .series {
            guard let episode = try? await episodeToPlay(seriesId: found.id, userId: userId) else { return nil }
            found = episode
            start = episode.resumeTicks
        }
        guard [.movie, .episode, .video].contains(found.kind) else { return nil }
        return RemotePlayTarget(item: found, startTicks: start)
    }
}
