import Foundation
import Testing
@testable import MatineKit

@Suite struct RemoteTests {
    private func decode(_ json: String) -> RemoteMessage { RemoteMessage.decode(Data(json.utf8)) }

    @Test func playNowBecomesAPlayCommandWithItsFirstItem() {
        let json = #"{"MessageType":"Play","MessageId":"m","Data":{"ItemIds":["item-a","item-b"],"StartPositionTicks":900000000,"PlayCommand":"PlayNow","ControllingUserId":"u"}}"#
        #expect(decode(json) == .command(.play(itemIds: ["item-a", "item-b"], startIndex: nil, startTicks: 900_000_000)))
    }

    @Test func playWithoutAStartPositionStartsAtZero() {
        #expect(decode(#"{"MessageType":"Play","Data":{"ItemIds":["x"],"PlayCommand":"PlayNow"}}"#) == .command(.play(itemIds: ["x"], startIndex: nil, startTicks: 0)))
    }

    private static let a = "0123456789abcdef0123456789abcdef"
    private static let b = "11111111-2222-3333-4444-555555555555"

    @Test func startIndexPicksTheItemInTheList() {
        let json = #"{"MessageType":"Play","Data":{"ItemIds":["\#(Self.a)","\#(Self.b)"],"StartIndex":1,"PlayCommand":"PlayNow"}}"#
        guard case .command(let command) = decode(json) else { Issue.record("not a command"); return }
        #expect(command.playItemId == Self.b)
    }

    @Test func aStartIndexOutOfRangeFallsBackToTheFirst() {
        for index in [-1, 2, 99] {
            let command = RemoteCommand.play(itemIds: [Self.a, Self.b], startIndex: index, startTicks: 0)
            #expect(command.playItemId == Self.a)
        }
        #expect(RemoteCommand.play(itemIds: [Self.a], startIndex: nil, startTicks: 0).playItemId == Self.a)
    }

    @Test func onlyJellyfinIdsAreUsed() {
        for bad in ["../Users", "x", "", "0123456789abcdef0123456789abcde", Self.a + "0", "g123456789abcdef0123456789abcdef", Self.a + "/Images"] {
            #expect(RemoteCommand.play(itemIds: [bad], startIndex: nil, startTicks: 0).playItemId == nil, "\(bad)")
        }
        #expect(RemoteCommand.pause.playItemId == nil)
    }

    @Test func remotePlayTargetFetchesTheChosenItemAsTheProfile() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items/\(Self.b)", body: #"{"Id":"\#(Self.b)","Name":"Peli","Type":"Movie"}"#)
        let command = RemoteCommand.play(itemIds: [Self.a, Self.b], startIndex: 1, startTicks: 50)
        let target = try #require(await makeClient(transport).remotePlayTarget(command, userId: "u"))
        #expect(target.item.id == Self.b)
        #expect(target.startTicks == 50)
        #expect(transport.requests.map(\.url!.path) == ["/Items/\(Self.b)"])
        #expect(transport.requests[0].query("userId") == "u")
    }

    @Test func remotePlayTargetRefusesWhatTheProfileCannotFetchOrPlay() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items/\(Self.a)", status: 404)
        transport.on("GET", "/Items/\(Self.b)", body: #"{"Id":"\#(Self.b)","Name":"Carpeta","Type":"Folder"}"#)
        let client = makeClient(transport)
        #expect(await client.remotePlayTarget(.play(itemIds: [Self.a], startIndex: nil, startTicks: 0), userId: "u") == nil)
        #expect(await client.remotePlayTarget(.play(itemIds: [Self.b], startIndex: nil, startTicks: 0), userId: "u") == nil)
        #expect(await client.remotePlayTarget(.play(itemIds: ["../x"], startIndex: nil, startTicks: 0), userId: "u") == nil)
        #expect(await client.remotePlayTarget(.pause, userId: "u") == nil)
        // The malformed id never reached the server.
        #expect(transport.requests.count == 2)
    }

    @Test func aSeriesPlaysItsOwnNextEpisode() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Items/\(Self.a)", body: #"{"Id":"\#(Self.a)","Name":"Serie","Type":"Series"}"#)
        transport.on("GET", "/Shows/NextUp", body: #"{"Items":[{"Id":"ep-9","Name":"E9","Type":"Episode","UserData":{"PlaybackPositionTicks":777}}]}"#)
        let target = try #require(await makeClient(transport).remotePlayTarget(.play(itemIds: [Self.a], startIndex: nil, startTicks: 0), userId: "u"))
        #expect(target.item.id == "ep-9")
        #expect(target.startTicks == 777)
    }

    @Test func queueingAndEmptyPlayRequestsAreIgnored() {
        #expect(decode(#"{"MessageType":"Play","Data":{"ItemIds":["x"],"PlayCommand":"PlayNext"}}"#) == .ignored)
        #expect(decode(#"{"MessageType":"Play","Data":{"ItemIds":[],"PlayCommand":"PlayNow"}}"#) == .ignored)
        #expect(decode(#"{"MessageType":"Play","Data":null}"#) == .ignored)
    }

    @Test func playstateCommands() {
        func state(_ command: String, _ extra: String = "") -> RemoteMessage {
            decode(#"{"MessageType":"Playstate","Data":{"Command":"\#(command)"\#(extra)}}"#)
        }
        #expect(state("Pause") == .command(.pause))
        #expect(state("Unpause") == .command(.unpause))
        #expect(state("PlayPause") == .command(.playPause))
        #expect(state("Stop") == .command(.stop))
        #expect(state("Seek", #","SeekPositionTicks":300000000"#) == .command(.seek(ticks: 300_000_000)))
        #expect(state("Seek") == .ignored)
        #expect(state("NextTrack") == .ignored)
        #expect(state("Rewind") == .ignored)
    }

    @Test func keepAliveAndEverythingElse() {
        #expect(decode(#"{"MessageType":"ForceKeepAlive","Data":60}"#) == .forceKeepAlive(seconds: 60))
        #expect(decode(#"{"MessageType":"KeepAlive"}"#) == .ignored)
        #expect(decode(#"{"MessageType":"GeneralCommand","Data":{"Name":"DisplayMessage"}}"#) == .ignored)
        #expect(decode(#"{"MessageType":"Sessions","Data":[{"Id":"s"}]}"#) == .ignored)
        #expect(decode("not json") == .ignored)
        #expect(decode("") == .ignored)
    }

    @Test func backoffDoublesAndCaps() {
        let delays = (1...9).map { ReconnectBackoff.delay(afterFailures: $0, jitter: 0.5) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(abs(ReconnectBackoff.delay(afterFailures: 3, jitter: 0) - 3.2) < 0.0001)
        #expect(abs(ReconnectBackoff.delay(afterFailures: 3, jitter: 1) - 4.8) < 0.0001)
        #expect(ReconnectBackoff.delay(afterFailures: 0, jitter: 0.5) == 1)
        #expect(ReconnectBackoff.delay(afterFailures: 10_000, jitter: 1) <= 60 * 1.2 + 0.001)
    }

    @Test func aLongConnectionResetsTheBackoff() {
        #expect(ReconnectBackoff.failures(after: 5, connectionLasted: 31) == 1)
        #expect(ReconnectBackoff.failures(after: 5, connectionLasted: 2) == 6)
        #expect(ReconnectBackoff.failures(after: 0, connectionLasted: 0) == 1)
    }

    @Test func anHttpServerGetsAPlainSocketAndHttpsAGoodOne() throws {
        let plain = JellyfinClient(server: URL(string: "http://tv.example.test:8096")!, identity: testIdentity, token: "t")
        #expect(plain.socketRequest()?.url?.scheme == "ws")
        #expect(makeClient(FakeTransport()).socketRequest()?.url?.scheme == "wss")
    }

    @Test func capabilitiesBodyClaimsOnlyWhatTheTVImplements() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/Sessions/Capabilities/Full")
        try await makeClient(transport).reportCapabilities()
        let request = try #require(transport.requests.first)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["PlayableMediaTypes"] as? [String] == ["Video"])
        #expect(json["SupportedCommands"] as? [String] == ["Play", "PlayState"])
        #expect(json["SupportsMediaControl"] as? Bool == true)
        #expect(Set(json.keys) == ["PlayableMediaTypes", "SupportedCommands", "SupportsMediaControl"])
    }

    @Test func theSocketRequestCarriesTheTokenOnlyInAHeader() throws {
        let request = try #require(makeClient(FakeTransport(), token: "tok-secret").socketRequest())
        #expect(request.url?.scheme == "wss")
        #expect(request.url?.host == "tv.example.test")
        #expect(request.url?.path == "/socket")
        #expect(request.url?.query == nil)
        #expect(!request.url!.absoluteString.contains("tok-secret"))
        let header = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(header.contains(#"Token="tok-secret""#))
        #expect(header.contains(#"DeviceId="device-1""#))
    }

    @Test func sendingPlayAndPlaystateUsesTheSessionsEndpoints() async throws {
        let transport = FakeTransport()
        transport.on("POST", "/Sessions/SID/Playing")
        transport.on("POST", "/Sessions/SID/Playing/Seek")
        let client = makeClient(transport)
        try await client.sendPlay(sessionId: "SID", itemId: "ITEM", startTicks: 70)
        try await client.sendPlaystate(sessionId: "SID", .seek, seekTicks: 9)
        let play = transport.requests[0], seek = transport.requests[1]
        #expect(play.query("playCommand") == "PlayNow")
        #expect(play.query("itemIds") == "ITEM")
        #expect(play.query("startPositionTicks") == "70")
        #expect(seek.query("seekPositionTicks") == "9")
        #expect(!play.url!.absoluteString.contains("tok-123"))
    }

    @Test func sessionsListRemoteControllableOnesFirst() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Sessions", body: #"[{"Id":"a","SupportsRemoteControl":false},{"Id":"b","DeviceName":"TV","SupportsRemoteControl":true}]"#)
        let sessions = try await makeClient(transport).controllableSessions(userId: "u")
        #expect(sessions.map(\.id) == ["b", "a"])
        #expect(transport.requests[0].query("controllableByUserId") == "u")
    }

    private func sessions(_ json: String) throws -> [RemoteSession] {
        try JSONDecoder().decode([RemoteSession].self, from: Data(json.utf8))
    }

    @Test func tvsAreAppleTVsAndTVAppsNeverThePhoneItself() throws {
        let list = try sessions("""
        [{"Id":"phone","DeviceId":"me","DeviceName":"iPhone","Client":"Matine","SupportsRemoteControl":true},
         {"Id":"ipad","DeviceId":"other","DeviceName":"iPad","Client":"Matine","SupportsRemoteControl":true},
         {"Id":"web","DeviceId":"w","DeviceName":"Firefox","Client":"Jellyfin Web","SupportsRemoteControl":true},
         {"Id":"android","DeviceId":"a","DeviceName":"Sala","Client":"Jellyfin Android TV","SupportsRemoteControl":true},
         {"Id":"off","DeviceId":"o","DeviceName":"Cocina","Client":"Matine","SupportsRemoteControl":false},
         {"Id":"tv","DeviceId":"t","DeviceName":"Apple TV","Client":"Matine","SupportsRemoteControl":true}]
        """)
        let tvs = TVTarget.tvs(in: list, ownDeviceId: "me")
        #expect(tvs.map(\.id) == ["tv", "android"])
        #expect(tvs.map(\.name) == ["Apple TV", "Sala"])
    }

    @Test func sameNamedTVsAreNumbered() throws {
        let list = try sessions("""
        [{"Id":"b","DeviceId":"2","DeviceName":"Apple TV","Client":"Matine","SupportsRemoteControl":true},
         {"Id":"a","DeviceId":"1","DeviceName":"Apple TV","Client":"Matine","SupportsRemoteControl":true}]
        """)
        #expect(TVTarget.tvs(in: list, ownDeviceId: "me").map(\.name) == ["Apple TV 1", "Apple TV 2"])
        #expect(TVTarget.tvs(in: [], ownDeviceId: "me").isEmpty)
    }

    @Test func sameNamedTVsOfDifferentProfilesAreToldApartByProfile() throws {
        let list = try sessions("""
        [{"Id":"b","DeviceId":"2","DeviceName":"Apple TV","UserName":"luz","Client":"Matine","SupportsRemoteControl":true},
         {"Id":"a","DeviceId":"1","DeviceName":"Apple TV","UserName":"ana","Client":"Matine","SupportsRemoteControl":true},
         {"Id":"c","DeviceId":"3","DeviceName":"Sala","UserName":"ana","Client":"Matine","SupportsRemoteControl":true}]
        """)
        let tvs = TVTarget.tvs(in: list, ownDeviceId: "me")
        #expect(tvs.map(\.id) == ["a", "b", "c"])
        #expect(tvs.map(\.name) == ["Apple TV · ana", "Apple TV · luz", "Sala"])
    }

    @Test func sameNamedTVsOfOneProfileAreNumbered() throws {
        let list = try sessions("""
        [{"Id":"a","DeviceId":"1","DeviceName":"Apple TV","UserName":"ana","Client":"Matine","SupportsRemoteControl":true},
         {"Id":"b","DeviceId":"2","DeviceName":"Apple TV","UserName":"ana","Client":"Matine","SupportsRemoteControl":true}]
        """)
        #expect(TVTarget.tvs(in: list, ownDeviceId: "me").map(\.name) == ["Apple TV 1", "Apple TV 2"])
    }

    @Test func aSessionKnowsWhatItIsPlaying() throws {
        let list = try sessions("""
        [{"Id":"a","DeviceId":"1","DeviceName":"Sala","Client":"Matine","SupportsRemoteControl":true,"NowPlayingItem":{"Id":"item","Name":"x"}},
         {"Id":"b","DeviceId":"2","DeviceName":"Cocina","Client":"Matine","SupportsRemoteControl":true}]
        """)
        #expect(list.map(\.nowPlayingItemId) == ["item", nil])
        #expect(TVTarget.tvs(in: list, ownDeviceId: "me").map(\.isPlaying) == [false, true])
    }

    @Test func activeWithinSecondsIsAskedOnlyWhenGiven() async throws {
        let transport = FakeTransport()
        transport.on("GET", "/Sessions", body: "[]")
        let client = makeClient(transport)
        _ = try await client.controllableSessions(userId: "u")
        _ = try await client.tvs(userId: "u")
        #expect(transport.requests[0].query("activeWithinSeconds") == nil)
        #expect(transport.requests[1].query("activeWithinSeconds") == "960")
        #expect(transport.requests[1].query("controllableByUserId") == "u")
    }
}
