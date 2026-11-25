import Foundation
import Testing
@testable import MatineKit

private let server = URL(string: "https://media.example.test")!

private func account(_ id: String, _ role: ProfileRole = .adult) -> Account {
    Account(id: id, name: "user-\(id)", server: server, role: role)
}

@Suite struct ProfileLookTests {
    @Test func aProfileSavedByAnEarlierBuildOpensAsAnAdultWithItsOwnRobot() throws {
        let old = #"[{"id":"u1","name":"ana","server":"https://media.example.test","language":"es-ES","deviceId":"d1"}]"#
        let decoded = try JSONDecoder().decode([Account].self, from: Data(old.utf8))
        #expect(decoded[0].role == .adult)
        #expect(decoded[0].displayName == nil)
        #expect(decoded[0].avatar == Avatar.initial(for: "u1"))
        #expect(decoded[0].shownName == "ana")
    }

    @Test func aLookFromANewerBuildFallsBackInsteadOfLosingTheProfiles() throws {
        let newer = #"[{"id":"u1","name":"ana","server":"https://media.example.test","language":"es-ES","deviceId":"d1","role":"robotOverlord","avatar":{"figure":{"hologram":{}},"color":"chartreuse"}}]"#
        let decoded = try JSONDecoder().decode([Account].self, from: Data(newer.utf8))
        #expect(decoded[0].role == .adult)
        #expect(decoded[0].avatar == Avatar.initial(for: "u1"))
    }

    @Test func lookAndRoleSurviveSaving() throws {
        var saved = account("u1", .kid)
        saved.displayName = "Leo"
        saved.avatar = Avatar(figure: .animal(.tortoise), color: .teal)
        let store = AccountStore(settings: InMemoryKeyValueStore(), secrets: InMemorySecretStore())
        try store.upsert(saved, token: "t")
        #expect(store.accounts() == [saved])
        #expect(store.accounts()[0].shownName == "Leo")
    }

    @Test func theInitialAvatarIsTheSameEverywhereAndDiffersBetweenProfiles() {
        #expect(Avatar.initial(for: "abc") == Avatar.initial(for: "abc"))
        // FNV-1a of "abc", a published test value: no per-process seeding.
        #expect(StableHash.fnv1a("abc") == 0xE71F_A219_0541_574B)
        let avatars = Set((0..<50).map { Avatar.initial(for: "user\($0)") })
        #expect(avatars.count == 50)
    }

    @Test func displayNamesAreTidiedAndBlankMeansTheServerName() {
        #expect(Profiles.cleanDisplayName("  Papá  ") == "Papá")
        #expect(Profiles.cleanDisplayName("Pa\u{0301}pa") == "Pápa")
        #expect(Profiles.cleanDisplayName("   ") == nil)
        #expect(Profiles.cleanDisplayName(String(repeating: "x", count: 40))?.count == 20)
        var blank = account("u1")
        blank.displayName = " "
        #expect(blank.shownName == "user-u1")
    }
}

@Suite struct RobotTests {
    @Test func theSameSeedDrawsTheSameRobot() {
        #expect(Robot(seed: 42, background: .ocean) == Robot(seed: 42, background: .ocean))
    }

    @Test func seedsGiveManyDifferentRobots() {
        let robots = Set((0..<200).map { Robot(seed: UInt64($0) &* 0x9E37_79B9, background: .grape).shapes })
        #expect(robots.count > 190)
    }

    @Test func accentsNeverMatchTheBackground() {
        for color in ProfileColor.allCases {
            for seed in 0..<100 {
                let fills = Robot(seed: UInt64(seed), background: color).shapes.compactMap { shape -> RGB? in
                    if case .ellipse(_, _, _, _, let fill) = shape { fill } else { nil }
                }
                #expect(!fills.contains(color.rgb))
            }
        }
    }

    @Test func everyShapeStaysNearTheCanvas() {
        for seed in 0..<500 {
            for shape in Robot(seed: UInt64(seed), background: .teal).shapes {
                switch shape {
                case let .rect(x, y, width, height, _, _):
                    #expect(x >= 0 && y >= 0 && x + width <= 100 && width > 0 && height > 0)
                    if y + height > 100 { #expect(y >= 80) } // only the shoulders run off the bottom
                case let .ellipse(cx, cy, rx, ry, _):
                    #expect(cx - rx >= 0 && cx + rx <= 100 && cy - ry >= 0 && cy + ry <= 100)
                case let .line(points, _, _):
                    #expect(points.allSatisfy { (0...100).contains($0.x) && (0...100).contains($0.y) })
                case let .arc(cx, cy, radius, _, _, _, _):
                    #expect(cx - radius >= 0 && cx + radius <= 100 && cy - radius >= 0)
                }
            }
        }
    }

    @Test func theSVGIsWellFormed() {
        for seed: UInt64 in [0, 1, 7, .max] {
            let svg = Robot(seed: seed, background: .cherry).svg(background: .cherry)
            #expect(XMLParser(data: Data(svg.utf8)).parse())
            #expect(svg.contains(ProfileColor.cherry.rgb.hex))
        }
    }

    @Test func aSmileArcCurvesDown() {
        let svg = Robot.svgElement(.arc(cx: 50, cy: 50, radius: 10, from: 0, to: 180, width: 2, color: Robot.ink))
        // From the right end, clockwise on screen (sweep 1), through the bottom, to the left end.
        #expect(svg.contains("M60.00 50.00 A10.00 10.00 0 0 1 40.00 50.00"))
    }
}

@Suite struct HouseRulesTests {
    @Test func withoutKidsNothingIsGuarded() {
        let rules = HouseRules(accounts: [account("a"), account("b")], hasPin: { _ in false })
        #expect(!rules.hasKids)
        #expect(rules.unguardedAdults.isEmpty)
        #expect(!rules.needsGrownUp)
    }

    @Test func makingAKidNeedsAnAdultWithAPin() {
        let accounts = [account("a"), account("kid")]
        let none = HouseRules(accounts: accounts, hasPin: { _ in false })
        #expect(none.refusal(changing: accounts[1], to: .kid) == .needsAdultPin)
        let parent = HouseRules(accounts: accounts, hasPin: { $0 == "a" })
        #expect(parent.refusal(changing: accounts[1], to: .kid) == nil)
        // The kid's own PIN doesn't count.
        let kidsPin = HouseRules(accounts: accounts, hasPin: { $0 == "kid" })
        #expect(kidsPin.refusal(changing: accounts[1], to: .kid) == .needsAdultPin)
    }

    @Test func theLastAdultStaysAnAdult() {
        let accounts = [account("a"), account("kid", .kid)]
        let rules = HouseRules(accounts: accounts, hasPin: { _ in true })
        #expect(rules.refusal(changing: accounts[0], to: .kid) == .lastAdult)
        #expect(rules.refusal(changing: accounts[0], to: .adult) == nil)
    }

    @Test func theOnlyAdultWithAPinCantBecomeAKidWhileKidsExist() {
        let accounts = [account("a"), account("b"), account("kid", .kid)]
        let rules = HouseRules(accounts: accounts, hasPin: { $0 == "a" })
        #expect(rules.refusal(changing: accounts[0], to: .kid) == .needsAdultPin)
        #expect(rules.refusal(changing: accounts[1], to: .kid) == nil)
        // A kid back to an adult is always fine.
        #expect(rules.refusal(changing: accounts[2], to: .adult) == nil)
    }

    @Test func adultsWithoutAPinAreFlaggedOnceAKidExists() {
        let accounts = [account("a"), account("b"), account("kid", .kid)]
        let rules = HouseRules(accounts: accounts, hasPin: { $0 == "a" })
        #expect(rules.unguardedAdults.map(\.id) == ["b"])
        #expect(rules.adultsWithPin.map(\.id) == ["a"])
        #expect(rules.needsGrownUp)
        // b has no PIN of its own: a first PIN or signing out needs a grown-up's.
        #expect(rules.needsGrownUp(toChange: accounts[1]))
        #expect(!rules.needsGrownUp(toChange: accounts[0]))
    }

    @Test func theLastAdultPinCantBeRemovedOrSignedOutWhileKidsExist() {
        let accounts = [account("a"), account("b"), account("kid", .kid)]
        let one = HouseRules(accounts: accounts, hasPin: { $0 == "a" })
        #expect(one.refusal(removingPinOf: accounts[0]) == .needsAdultPin)
        #expect(one.refusal(removing: accounts[0]) == .needsAdultPin)
        #expect(one.refusal(removing: accounts[1]) == nil)
        let both = HouseRules(accounts: accounts, hasPin: { $0 != "kid" })
        #expect(both.refusal(removingPinOf: accounts[0]) == nil)
        #expect(both.refusal(removing: accounts[0]) == nil)
        // The only adult can't leave the kids alone.
        let alone = HouseRules(accounts: [account("a"), account("kid", .kid)], hasPin: { _ in true })
        #expect(alone.refusal(removing: alone.accounts[0]) == .lastAdult)
        // Without kids anything goes.
        let grownUps = HouseRules(accounts: [account("a")], hasPin: { _ in true })
        #expect(grownUps.refusal(removing: grownUps.accounts[0]) == nil)
        #expect(grownUps.refusal(removingPinOf: grownUps.accounts[0]) == nil)
    }
}

@Suite struct CheckAnyPinTests {
    let secrets = InMemorySecretStore()
    let clock = Clock()
    var gate: PinGate { clock.gate(secrets) }

    @Test func anyAdultsPinOpens() throws {
        try gate.setPin("1111", for: "a")
        try gate.setPin("2222", for: "b")
        #expect(try gate.checkAny("2222", for: ["a", "b"]) == .open)
        #expect(try gate.checkAny("1111", for: ["a", "b"]) == .open)
        // Only the profiles asked about count.
        #expect(try gate.checkAny("2222", for: ["a"]) == .wrong(attemptsLeft: 4))
    }

    @Test func aRightPinClearsThePadsFailures() throws {
        try gate.setPin("1111", for: "a")
        for _ in 0..<3 { _ = try gate.checkAny("0000", for: ["a"]) }
        #expect(try gate.checkAny("1111", for: ["a"]) == .open)
        #expect(try gate.checkAny("0000", for: ["a"]) == .wrong(attemptsLeft: 4))
    }

    @Test func wrongGuessesLockOnlyTheGrownUpPadNeverTheAdultsOwnTiles() throws {
        try gate.setPin("1111", for: "a")
        try gate.setPin("2222", for: "b")
        #expect(try gate.checkAny("0000", for: ["a", "b"]) == .wrong(attemptsLeft: 4))
        for _ in 0..<3 { _ = try gate.checkAny("0000", for: ["a", "b"]) }
        guard case .locked = try gate.checkAny("0000", for: ["a", "b"]) else { Issue.record("expected locked"); return }
        // Even the right PIN waits out the pad's lockout...
        guard case .locked = try gate.checkAny("1111", for: ["a", "b"]) else { Issue.record("expected locked"); return }
        // ...but each adult's own tile is untouched.
        #expect(try gate.check("1111", for: "a") == .open)
        #expect(try gate.check("0000", for: "b") == .wrong(attemptsLeft: 4))
        clock.now += PinGate.firstLockout + 1
        #expect(try gate.checkAny("2222", for: ["a", "b"]) == .open)
    }

    @Test func noPinsMeansNothingOpens() throws {
        #expect(try gate.checkAny("1234", for: ["a"]) == nil)
        #expect(try gate.checkAny("1234", for: []) == nil)
    }
}

@Suite struct RecentSearchesTests {
    let settings = InMemoryKeyValueStore()

    @Test func newestFirstDedupedAndCapped() {
        let recent = RecentSearches(settings: settings, accountId: "a")
        recent.add("dinosaurios")
        recent.add("  Cuentos   de  hadas ")
        recent.add("DINOSAURIOS")
        recent.add("dinosáurios ")
        recent.add("x")
        // Case, accents and spaces aside, the same search: the newest wording stays.
        #expect(recent.list() == ["dinosáurios", "Cuentos de hadas"])
        for index in 0..<20 { recent.add("busca \(index)") }
        #expect(recent.list().count == RecentSearches.limit)
        #expect(recent.list().first == "busca 19")
    }

    @Test func eachProfileHasItsOwnAndSigningOutForgetsThem() throws {
        let store = AccountStore(settings: settings, secrets: InMemorySecretStore())
        try store.upsert(account("a"), token: "t")
        store.recentSearches(for: "a").add("ranas")
        #expect(store.recentSearches(for: "b").list().isEmpty)
        #expect(store.recentSearches(for: "a").list() == ["ranas"])
        try store.remove("a")
        #expect(store.recentSearches(for: "a").list().isEmpty)
    }

    /// What someone searched for is close to what they watch: it never lands in
    /// the settings, which iCloud and Finder back up.
    @Test func searchesStayOutOfTheBackedUpSettings() throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(settings: settings, secrets: secrets)
        store.recentSearches(for: "a").add("ranas")
        #expect(settings.data(forKey: RecentSearches.key("a")) == nil)
        #expect(try secrets.read(RecentSearches.key("a")) != nil)
        // Signing out of this device (the profile stays) forgets them too.
        try store.removeToken("a")
        #expect(store.recentSearches(for: "a").list().isEmpty)
    }

    @Test func searchesAnEarlierBuildLeftInTheSettingsMoveToTheKeychainOnce() throws {
        let secrets = InMemorySecretStore()
        let store = AccountStore(settings: settings, secrets: secrets)
        try store.upsert(account("a"), token: "t")
        try store.upsert(account("b"), token: "t")
        RecentSearches(settings: settings, accountId: "a").add("leones")
        RecentSearches(settings: settings, accountId: "b").add("tigres")
        // The Keychain already has b's: it wins, and the settings copy still goes.
        SecretKeyValueStore(secrets: secrets).set(try JSONEncoder().encode(["osos"]), forKey: RecentSearches.key("b"))
        // Reading is a pure accessor: it writes nothing.
        #expect(store.recentSearches(for: "a").list().isEmpty)
        #expect(settings.data(forKey: RecentSearches.key("a")) != nil)
        store.migrateRecentSearches()
        #expect(store.recentSearches(for: "a").list() == ["leones"])
        #expect(store.recentSearches(for: "b").list() == ["osos"])
        #expect(settings.data(forKey: RecentSearches.key("a")) == nil)
        #expect(settings.data(forKey: RecentSearches.key("b")) == nil)
        store.migrateRecentSearches()
        #expect(store.recentSearches(for: "a").list() == ["leones"])
    }
}

@Suite struct BlurHashTests {
    static func encode83(_ value: Int, length: Int) -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
        var digits: [Character] = []
        var rest = value
        for _ in 0..<length {
            digits.insert(alphabet[rest % 83], at: 0)
            rest /= 83
        }
        return String(digits)
    }

    @Test func aHashWithOnlyItsAverageIsThatColorEverywhere() throws {
        let hash = "00" + Self.encode83(200 << 16 | 100 << 8 | 50, length: 4)
        let pixels = try #require(BlurHash.decode(hash, width: 4, height: 3))
        #expect(pixels.count == 4 * 3 * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            #expect(Array(pixels[offset..<offset + 4]) == [200, 100, 50, 255])
        }
    }

    @Test func thePublishedExampleDecodes() throws {
        // The example on blurha.sh: 4 × 3 components around a gray average.
        let hash = "LEHV6nWB2yk8pyo0adR*.7kCMdnj"
        let pixels = try #require(BlurHash.decode(hash, width: 32, height: 32))
        #expect(pixels.count == 32 * 32 * 4)
        // Not flat: the detail components are applied.
        #expect(Set(stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }).count > 20)
    }

    @Test func malformedHashesAreRefused() {
        for bad in ["", "LEHV6", "LEHV6nWB2yk8pyo0adR*.7kCMdn", "LEHV6nWB2yk8pyo0adR*.7kCMdnj!", "\"EHV6nWB2yk8pyo0adR*.7kCMdnj"] {
            #expect(BlurHash.decode(bad, width: 8, height: 8) == nil)
        }
    }

    @Test func anItemFindsTheHashOfItsImage() throws {
        let json = #"{"Id":"i1","Name":"n","Type":"Movie","ImageTags":{"Primary":"tag1"},"ImageBlurHashes":{"Primary":{"tag1":"00abcd","old":null}}}"#
        let item = try JSONDecoder().decode(Item.self, from: Data(json.utf8))
        let ref = try #require(item.posterImage)
        #expect(item.blurHash(for: ref) == "00abcd")
    }
}

@Suite struct TidyNamesTests {
    @Test func aChannelsRepeatedTailIsFoundAndDropped() {
        let names = ["Uno - cuentos - Canal Ejemplo", "Dos - cuentos - Canal Ejemplo", "Tres - Canal Ejemplo", "Especial de verano"]
        let suffix = Item.sharedSuffix(names)
        #expect(suffix == " - Canal Ejemplo")
        var item = Item(id: "e1", name: names[0], kind: .episode)
        #expect(item.displayName(dropping: suffix) == "Uno - cuentos")
        item.name = "Especial de verano"
        #expect(item.displayName(dropping: suffix) == "Especial de verano")
    }

    @Test func fewOrVariedNamesKeepTheirTails() {
        #expect(Item.sharedSuffix(["A - x", "B - x"]) == nil)
        #expect(Item.sharedSuffix(["A - x", "B - y", "C - z", "D - w"]) == nil)
        // A name that is only the tail isn't emptied.
        #expect(Item(id: "e", name: " - x", kind: .episode).displayName(dropping: " - x") == " - x")
    }

    @Test func seguirVerMergesResumeAndNextUpOnePerSeries() {
        func episode(_ id: String, series: String) -> Item {
            var item = Item(id: id, name: id, kind: .episode)
            item.seriesId = series
            return item
        }
        let resume = [episode("a2", series: "A"), Item(id: "m", name: "m", kind: .movie)]
        let next = [episode("a3", series: "A"), episode("b1", series: "B"), Item(id: "m", name: "m", kind: .movie)]
        #expect(HomeLoader.watching(resume: resume, nextUp: next).map(\.id) == ["a2", "m", "b1"])
    }
}

@Suite struct OpensByItselfTests {
    private let kid = account("k", .kid), mum = account("m")

    @Test func theLastProfileWithoutAPinOpensByItself() {
        let rules = HouseRules(accounts: [mum, kid], hasPin: { $0 == "m" })
        #expect(rules.opensByItself(lastUnlocked: "k")?.id == "k")
    }

    @Test func aProfileBehindAPinNeverDoes() {
        // A PIN set since it was last opened.
        let rules = HouseRules(accounts: [mum, kid], hasPin: { _ in true })
        #expect(rules.opensByItself(lastUnlocked: "k") == nil)
    }

    @Test func aGrownUpWithoutAPinDoesntOpenByItselfWhereThereAreKids() {
        let dad = account("d")
        let rules = HouseRules(accounts: [mum, dad, kid], hasPin: { $0 == "m" })
        #expect(rules.opensByItself(lastUnlocked: "d") == nil)
        // No kids in the house: nobody to protect, it opens.
        #expect(HouseRules(accounts: [dad], hasPin: { _ in false }).opensByItself(lastUnlocked: "d")?.id == "d")
    }

    @Test func theOpenProfileReopensWithinTheGracePeriodPinOrNot() {
        let rules = HouseRules(accounts: [mum, kid], hasPin: { $0 == "m" })
        let left = Date(timeIntervalSince1970: 1_000_000)
        #expect(rules.reopens(open: "m", leftAt: left, now: left.addingTimeInterval(9 * 60))?.id == "m")
        #expect(rules.reopens(open: "m", leftAt: left, now: left.addingTimeInterval(HouseRules.reopenGrace)) == nil)
        // A clock that went backwards proves nothing.
        #expect(rules.reopens(open: "m", leftAt: left, now: left.addingTimeInterval(-5)) == nil)
        // Signed out meanwhile, or nothing remembered.
        #expect(rules.reopens(open: "gone", leftAt: left, now: left) == nil)
        #expect(rules.reopens(open: nil, leftAt: left, now: left) == nil)
        #expect(rules.reopens(open: "m", leftAt: nil, now: left) == nil)
    }

    @Test func onlyTheFirstLeaveCounts() {
        // Screensaver at T0, the TV asleep 50 minutes later: still left at T0.
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var away = AwayRecord()
        away.left(at: t0, open: "m")
        away.left(at: t0.addingTimeInterval(50 * 60), open: "m")
        #expect(away.leftAt == t0)
        let rules = HouseRules(accounts: [mum, kid], hasPin: { $0 == "m" })
        // Relaunched 55 minutes in: the usual start (the kids'), not mum's.
        #expect(rules.start(away: away, lastUnlocked: "k", now: t0.addingTimeInterval(55 * 60), hasToken: { _ in true })?.id == "k")
        #expect(rules.start(away: away, lastUnlocked: "k", now: t0.addingTimeInterval(5 * 60), hasToken: { _ in true })?.id == "m")
    }

    @Test func comingBackClearsTheRecordAndSaysWhetherToLock() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var away = AwayRecord()
        away.left(at: t0, open: "m")
        let late = away.returned(at: t0.addingTimeInterval(HouseRules.reopenGrace + 1))
        #expect(late?.relock == true)
        // Cleared: a crash right after can't reopen what just locked.
        #expect(away == AwayRecord())
        #expect(away.returned(at: t0) == nil)
        away.left(at: t0, open: "m")
        #expect(away.returned(at: t0.addingTimeInterval(60))?.relock == false)
        away.left(at: t0, open: "m")
        #expect(away.returned(at: t0.addingTimeInterval(-60))?.relock == true)
    }

    @Test func leavingFromAPinScreenReopensNothing() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var away = AwayRecord()
        away.left(at: t0, open: nil)
        let rules = HouseRules(accounts: [mum, kid], hasPin: { $0 == "m" })
        #expect(rules.start(away: away, lastUnlocked: nil, now: t0, hasToken: { _ in true }) == nil)
    }

    @Test func aReopenNeedsAToken() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var away = AwayRecord()
        away.left(at: t0, open: "m")
        let rules = HouseRules(accounts: [mum, kid], hasPin: { $0 == "m" })
        #expect(rules.start(away: away, lastUnlocked: "k", now: t0, hasToken: { $0 == "k" })?.id == "k")
    }

    @Test func nothingRememberedOrSignedOutMeansThePicker() {
        let rules = HouseRules(accounts: [mum], hasPin: { _ in false })
        #expect(rules.opensByItself(lastUnlocked: nil) == nil)
        #expect(rules.opensByItself(lastUnlocked: "k") == nil)
    }
}
