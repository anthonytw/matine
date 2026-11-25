import Foundation
import Testing
@testable import MatineKit

private let server = URL(string: "https://media.example.test")!

private func join(_ code: String, _ kind: NearbyJoin.Kind = .iPhone) -> NearbyJoin { NearbyJoin(kind: kind, code: code)! }

@Suite struct NearbyTests {
    @Test func roundTripsThroughTheTextRecord() throws {
        let sent = join("482913", .iPad)
        #expect(NearbyJoin(txt: sent.txt) == sent)
        #expect(sent.spacedCode == "482 913")
        // Nothing but version, kind and code goes on the air: no free text.
        #expect(Set(sent.txt.keys) == ["v", "kind", "code"])
    }

    @Test func ignoresWhatIsNotACode() {
        for code in ["", "12345", "1234567", "12345a", "١٢٣٤٥٦", "123 456", " 12345"] {
            #expect(NearbyJoin(kind: .iPhone, code: code) == nil, "\(code)")
            #expect(NearbyJoin(txt: ["v": "1", "kind": "iphone", "code": code]) == nil, "\(code)")
        }
        #expect(NearbyJoin(txt: ["v": "1", "kind": "iphone"]) == nil)
        #expect(NearbyJoin(txt: ["v": "2", "kind": "iphone", "code": "123456"]) == nil)
        #expect(NearbyJoin(txt: ["kind": "iphone", "code": "123456"]) == nil)
    }

    @Test func aKindFromTheNetworkIsOneOfOursOrOther() {
        #expect(NearbyJoin(txt: ["v": "1", "kind": "iphone", "code": "123456"])?.kind == .iPhone)
        #expect(NearbyJoin(txt: ["v": "1", "kind": "ipad", "code": "123456"])?.kind == .iPad)
        // A name, a spoof or anything else collapses: nothing it says is shown.
        for text in ["Alex's iPhone", "iPhone 482913", "", "IPHONE", "other"] {
            #expect(NearbyJoin(txt: ["v": "1", "kind": text, "code": "123456"])?.kind == .other, "\(text)")
        }
        // An old announcement that carried a name is still read, name dropped.
        #expect(NearbyJoin(txt: ["v": "1", "name": "Ana", "code": "123456"])?.kind == .other)
        #expect(NearbyJoin.Kind(model: "iPhone") == .iPhone)
        #expect(NearbyJoin.Kind(model: "iPad") == .iPad)
        #expect(NearbyJoin.Kind(model: "iPod touch") == .other)
    }

    // MARK: Roster

    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test func rosterShowsAnnouncementsAndDropsVanishedOnes() {
        var roster = NearbyRoster()
        roster.update(seen: [join("111111")], now: t0)
        #expect(roster.offer(now: t0)?.joins.map(\.code) == ["111111"])
        roster.update(seen: [], now: t0.addingTimeInterval(1))
        #expect(roster.offer(now: t0) == nil)
    }

    @Test func answeredCodesDoNotComeBack() {
        var roster = NearbyRoster()
        roster.update(seen: [join("111111"), join("222222")], now: t0)
        roster.finish(join("111111"), .approved, now: t0)
        roster.update(seen: [join("111111"), join("222222")], now: t0.addingTimeInterval(5))
        #expect(roster.live.map(\.code) == ["222222"])
        roster.finish(join("222222"), .declined, now: t0.addingTimeInterval(6))
        roster.update(seen: [join("111111"), join("222222")], now: t0.addingTimeInterval(10))
        #expect(roster.live.isEmpty)
    }

    @Test func aFloodOfCodesIsRateLimited() {
        var roster = NearbyRoster(maxArrivals: 3, window: 60, maxShown: 10, declineLimit: 100)
        var now = t0
        for n in 0..<10 {
            roster.update(seen: [join(String(format: "%06d", n))], now: now)
            if let current = roster.live.first { roster.finish(current, .approved, now: now) }
            now.addTimeInterval(1)
        }
        roster.update(seen: [join("999999")], now: now)
        #expect(roster.live.isEmpty)
        now.addTimeInterval(61)
        roster.update(seen: [join("999999")], now: now)
        #expect(roster.live.map(\.code) == ["999999"])
    }

    @Test func fewAreLiveAtOnce() {
        var roster = NearbyRoster(maxArrivals: 100, window: 60, maxShown: 2)
        roster.update(seen: ["111111", "222222", "333333"].map { join($0) }, now: t0)
        #expect(roster.live.count == 2)
        roster.finish(roster.live[0], .approved, now: t0)
        // The third was never taken in; it is offered once there is room.
        roster.update(seen: ["222222", "333333"].map { join($0) }, now: t0.addingTimeInterval(1))
        #expect(roster.live.map(\.code) == ["222222", "333333"])
    }

    @Test func resultsAreCapped() {
        var roster = NearbyRoster(maxArrivals: 1000, window: 60, maxShown: 1000)
        roster.update(seen: (0..<50).map { join(String(format: "%06d", $0)) }, now: t0)
        #expect(roster.live.count == NearbyJoin.resultCap)
    }

    @Test func severalDevicesAreFlaggedAndNeverQuietlyQueued() {
        var roster = NearbyRoster()
        roster.update(seen: [join("111111")], now: t0)
        #expect(roster.offer(now: t0)?.isCrowded == false)
        roster.update(seen: [join("111111"), join("222222", .iPad)], now: t0.addingTimeInterval(1))
        let offer = roster.offer(now: t0.addingTimeInterval(1))
        #expect(offer?.isCrowded == true)
        #expect(offer?.joins.map(\.code) == ["111111", "222222"])
    }

    @Test func anAnnouncementSoonAfterAnAnswerIsFlagged() {
        var roster = NearbyRoster()
        roster.update(seen: [join("111111")], now: t0)
        roster.finish(join("111111"), .approved, now: t0)
        roster.update(seen: [join("222222")], now: t0.addingTimeInterval(10))
        #expect(roster.offer(now: t0.addingTimeInterval(10))?.isCrowded == true)
        // Long after, it is an ordinary single offer.
        roster.update(seen: [join("222222"), join("333333")], now: t0.addingTimeInterval(100))
        #expect(roster.offer(now: t0.addingTimeInterval(100))?.isCrowded == true) // 222222 and 333333 both live
        roster.finish(join("222222"), .approved, now: t0.addingTimeInterval(101))
        roster.update(seen: [join("333333")], now: t0.addingTimeInterval(200))
        #expect(roster.offer(now: t0.addingTimeInterval(200))?.isCrowded == false)
    }

    @Test func threeDeclinesInTenMinutesPauseOffersForThirtyMinutes() {
        var roster = NearbyRoster(maxArrivals: 100)
        for (n, code) in ["111111", "222222", "333333"].enumerated() {
            let now = t0.addingTimeInterval(Double(n) * 60)
            roster.update(seen: [join(code)], now: now)
            roster.finish(join(code), .declined, now: now)
        }
        let paused = t0.addingTimeInterval(130)
        #expect(roster.isPaused(now: paused))
        roster.update(seen: [join("444444")], now: paused)
        #expect(roster.offer(now: paused) == nil)
        #expect(roster.offer(now: t0.addingTimeInterval(120 + 29 * 60)) == nil)
        let after = t0.addingTimeInterval(120 + 31 * 60)
        #expect(!roster.isPaused(now: after))
        #expect(roster.offer(now: after)?.joins.map(\.code) == ["444444"])
    }

    @Test func slowDeclinesAndApprovalsDoNotPause() {
        var roster = NearbyRoster(maxArrivals: 100)
        // Three declines, but spread over more than ten minutes.
        for (n, code) in ["111111", "222222", "333333"].enumerated() {
            let now = t0.addingTimeInterval(Double(n) * 400)
            roster.update(seen: [join(code)], now: now)
            roster.finish(join(code), .declined, now: now)
        }
        #expect(!roster.isPaused(now: t0.addingTimeInterval(900)))
        for code in ["444444", "555555", "666666", "777777"] {
            roster.update(seen: [join(code)], now: t0.addingTimeInterval(1000))
            roster.finish(join(code), .approved, now: t0.addingTimeInterval(1000))
        }
        #expect(!roster.isPaused(now: t0.addingTimeInterval(1001)))
    }

    @Test func declineAllIsOneDeclineAndNothingComesBack() {
        var roster = NearbyRoster(maxArrivals: 100)
        roster.update(seen: [join("111111"), join("222222"), join("333333")], now: t0)
        roster.declineAll(now: t0)
        #expect(roster.live.isEmpty)
        roster.update(seen: [join("111111"), join("222222"), join("333333")], now: t0.addingTimeInterval(1))
        #expect(roster.live.isEmpty)
        // Two more declines make three; three codes declined together counted once.
        for code in ["444444", "555555"] {
            roster.update(seen: [join(code)], now: t0.addingTimeInterval(2))
            roster.finish(join(code), .declined, now: t0.addingTimeInterval(2))
        }
        #expect(roster.isPaused(now: t0.addingTimeInterval(3)))
    }

    // MARK: Which profiles may approve, and how

    @Test func noProfileApprovesWithASinglePress() {
        let ana = Account(id: "ana", name: "ana", server: server, role: .adult)
        let leo = Account(id: "leo", name: "leo", server: server, role: .kid)
        let mia = Account(id: "mia", name: "mia", server: server, role: .adult)
        // No kids: adults need a confirm step (no PIN) or their own PIN.
        var rules = HouseRules(accounts: [ana, mia], hasPin: { $0 == "mia" })
        #expect(rules.nearbyChoices(openId: "mia").map(\.step) == [.ownPin, .confirm])
        // A kid, with one adult PIN: the kid goes behind a grown-up's PIN, an
        // adult without a PIN too, and the open profile is first.
        rules = HouseRules(accounts: [ana, leo, mia], hasPin: { $0 == "mia" })
        let choices = rules.nearbyChoices(openId: "leo")
        #expect(choices.map(\.account.id) == ["leo", "ana", "mia"])
        #expect(choices.map(\.step) == [.grownUpPin, .grownUpPin, .ownPin])
        // A kid and no adult PIN: the kid may not approve at all.
        rules = HouseRules(accounts: [ana, leo], hasPin: { _ in false })
        #expect(rules.nearbyChoices(openId: "leo").map(\.account.id) == ["ana"])
        #expect(rules.nearbyChoices(openId: nil).allSatisfy { $0.step != .grownUpPin || $0.account.id != "leo" })
    }
}
