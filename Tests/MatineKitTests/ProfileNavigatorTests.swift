import Foundation
import Testing
@testable import MatineKit

private let server = URL(string: "https://media.example.test")!

private func account(_ id: String, _ role: ProfileRole = .adult) -> Account {
    Account(id: id, name: "user-\(id)", server: server, role: role)
}

/// Mum has a PIN, dad has none, Leo is a kid.
@Suite struct ProfileNavigatorTests {
    let mum = account("mum"), dad = account("dad"), leo = account("leo", .kid)
    let always: (String) -> Bool = { _ in true }

    func navigator(_ accounts: [Account], pins: Set<String> = ["mum"]) -> ProfileNavigator {
        ProfileNavigator(rules: HouseRules(accounts: accounts, hasPin: pins.contains))
    }

    // MARK: Choosing

    @Test func aPinProfileAsksForItsPinAndANormalOneOpens() {
        let nav = navigator([mum, dad, leo])
        let pin = nav.choose(mum, from: .picker)
        #expect(pin == .init(screen: .pin(mum), unlocked: nil, cancelReturnsTo: nil))
        #expect(nav.choose(leo, from: .picker) == .init(screen: .home(leo), unlocked: "leo", cancelReturnsTo: nil))
    }

    @Test func aPinChosenFromAnOpenProfileCancelsBackToIt() {
        let nav = navigator([mum, dad, leo])
        let choice = nav.choose(mum, from: .home(leo))
        #expect(choice.cancelReturnsTo == leo)
        #expect(nav.cancelPin(returnTo: leo) == .home(leo))
        #expect(nav.cancelPin(returnTo: nil) == .picker)
        // Back to the saved copy, not the one the screen captured.
        var renamed = leo
        renamed.displayName = "Leo"
        #expect(navigator([mum, renamed]).cancelPin(returnTo: leo) == .home(renamed))
    }

    // MARK: Signing in

    @Test func aSignInOfAPinProfileLandsOnItsPinNeverOnItsHome() {
        let nav = navigator([mum, dad, leo])
        #expect(nav.landing(after: mum, from: .addProfile(nil))?.screen == .pin(mum))
        #expect(nav.landing(after: mum, from: .addProfile(mum))?.screen == .pin(mum))
        #expect(nav.landing(after: dad, from: .addProfile(nil))?.screen == .home(dad))
        // The password was right for someone who is not at the PIN: still the PIN.
        #expect(nav.landing(after: mum, from: .addProfile(leo), pinEnteredFor: "leo")?.screen == .pin(mum))
        #expect(nav.landing(after: mum, from: .addProfile(nil), pinEnteredFor: "mum")?.screen == .pin(mum))
    }

    @Test func aPinEnteredInTheSameFlowIsNotAskedForTwice() {
        let nav = navigator([mum, dad, leo])
        let choice = nav.landing(after: mum, from: .addProfile(mum), pinEnteredFor: "mum")
        #expect(choice?.screen == .home(mum))
        #expect(choice?.unlocked == nil)
    }

    @Test func aSignInOnlyLandsWhileTheSignInScreenIsUp() {
        let nav = navigator([mum, dad, leo])
        #expect(nav.landing(after: dad, from: .picker) == nil)
        #expect(nav.landing(after: dad, from: .home(leo)) == nil)
        #expect(nav.landing(after: mum, from: .pin(mum)) == nil)
    }

    @Test func anExpiredSessionGoesToItsSignInAndRemembersAnOpenPin() {
        let nav = navigator([mum, dad, leo])
        let open = nav.signInAgain(for: "mum", from: .home(mum))
        #expect(open?.screen == .addProfile(mum))
        #expect(open?.pinEntered == true)
        #expect(nav.signInAgain(for: "mum", from: .home(leo))?.pinEntered == false)
        #expect(nav.signInAgain(for: "mum", from: .picker)?.pinEntered == false)
        #expect(nav.signInAgain(for: "ghost", from: .home(leo)) == nil)
    }

    @Test func addingAProfileAsksAGrownUpOnceThereAreKidsAndAPin() {
        #expect(navigator([mum, leo]).addProfile == .adultCheck)
        #expect(navigator([mum, dad]).addProfile == .addProfile(nil))
        // Kids but no adult PIN: nobody could answer it (the house rules refuse that state).
        #expect(navigator([dad, leo], pins: []).addProfile == .addProfile(nil))
    }

    // MARK: Starting and locking

    @Test func launchWithNoProfilesIsSignIn() {
        #expect(navigator([]).launch(lastUnlocked: nil, hasToken: always) == .addProfile(nil))
    }

    @Test func launchOpensOnlyWhatMayOpenByItselfAndHasASession() {
        let nav = navigator([mum, dad, leo])
        #expect(nav.launch(lastUnlocked: "leo", hasToken: always) == .home(leo))
        #expect(nav.launch(lastUnlocked: "leo", hasToken: { $0 != "leo" }) == .picker)
        // A PIN profile, and (with kids) an adult without one, never open unasked.
        #expect(nav.launch(lastUnlocked: "mum", hasToken: always) == .picker)
        #expect(nav.launch(lastUnlocked: "dad", hasToken: always) == .picker)
        #expect(nav.launch(lastUnlocked: nil, hasToken: always) == .picker)
    }

    @Test func launchReopensTheOpenProfileWithinTheGraceAndOnlyThen() {
        let nav = navigator([mum, dad, leo])
        let left = Date(timeIntervalSince1970: 1_000_000)
        var away = AwayRecord()
        away.left(at: left, open: "mum")
        let soon = left.addingTimeInterval(HouseRules.reopenGrace - 1)
        #expect(nav.launch(away: away, lastUnlocked: "leo", now: soon, hasToken: always) == .home(mum))
        let late = left.addingTimeInterval(HouseRules.reopenGrace)
        #expect(nav.launch(away: away, lastUnlocked: "leo", now: late, hasToken: always) == .home(leo))
        #expect(nav.launch(away: away, lastUnlocked: nil, now: late, hasToken: always) == .picker)
        // No session meanwhile: not even within the grace.
        #expect(nav.launch(away: away, lastUnlocked: nil, now: soon, hasToken: { $0 != "mum" }) == .picker)
    }

    @Test func relockClosesAPinProfileToTheLastUnlockedOne() {
        let nav = navigator([mum, dad, leo])
        #expect(nav.relocked(.home(mum), lastUnlocked: "leo", hasToken: always) == .home(leo))
        #expect(nav.relocked(.home(mum), lastUnlocked: nil, hasToken: always) == .picker)
        #expect(nav.relocked(.home(mum), lastUnlocked: "mum", hasToken: always) == .picker)
        // Profiles without a PIN stay as they are.
        #expect(nav.relocked(.home(leo), lastUnlocked: "leo", hasToken: always) == .home(leo))
        #expect(nav.relocked(.picker, lastUnlocked: "leo", hasToken: always) == .picker)
    }

    @Test func relockEndsAGrownUpsPinPassedForASignIn() {
        let nav = navigator([mum, dad, leo])
        #expect(nav.relocked(.addProfile(nil), lastUnlocked: nil, hasToken: always) == .picker)
        #expect(nav.relocked(.adultCheck, lastUnlocked: nil, hasToken: always) == .picker)
        // Signing in again for a profile is not adding one; with no kids there was no PIN to pass.
        #expect(nav.relocked(.addProfile(dad), lastUnlocked: nil, hasToken: always) == .addProfile(dad))
        #expect(navigator([mum, dad]).relocked(.addProfile(nil), lastUnlocked: nil, hasToken: always) == .addProfile(nil))
    }

    // MARK: Changes

    @Test func afterLeavingIsThePickerOrSignIn() {
        #expect(navigator([mum]).afterLeaving == .picker)
        #expect(navigator([]).afterLeaving == .addProfile(nil))
    }

    @Test func theHouseholdRemovingTheOpenProfileClosesIt() {
        let nav = navigator([dad, leo])
        #expect(nav.afterHousehold(.home(mum), removed: [mum], wasEmpty: false) == .picker)
        #expect(nav.afterHousehold(.pin(mum), removed: [mum], wasEmpty: false) == .picker)
        #expect(navigator([]).afterHousehold(.home(mum), removed: [mum], wasEmpty: false) == .addProfile(nil))
        // Another profile removed: the open one stays, with its saved copy.
        var renamed = leo
        renamed.displayName = "Leo"
        #expect(navigator([renamed]).afterHousehold(.home(leo), removed: [mum], wasEmpty: false) == .home(renamed))
        #expect(nav.afterHousehold(.pin(mum), removed: [], wasEmpty: false) == .pin(mum))
    }

    @Test func theFirstProfileToArriveReplacesTheEmptySignIn() {
        let nav = navigator([dad])
        #expect(nav.afterHousehold(.addProfile(nil), removed: [], wasEmpty: true) == .picker)
        #expect(nav.afterHousehold(.addProfile(nil), removed: [], wasEmpty: false) == .addProfile(nil))
        #expect(nav.afterHousehold(.addProfile(dad), removed: [], wasEmpty: true) == .addProfile(dad))
        #expect(nav.afterHousehold(.adultCheck, removed: [], wasEmpty: true) == .adultCheck)
        // Signing in again for a profile the household just removed has nothing left to sign in to.
        #expect(nav.afterHousehold(.addProfile(mum), removed: [mum], wasEmpty: false) == .picker)
        #expect(nav.afterHousehold(.addProfile(dad), removed: [mum], wasEmpty: false) == .addProfile(dad))
    }
}

@Suite struct TopShelfRulesTests {
    let mum = account("mum"), dad = account("dad"), leo = account("leo", .kid)

    func rules(_ accounts: [Account], pins: Set<String> = ["mum"]) -> HouseRules {
        HouseRules(accounts: accounts, hasPin: pins.contains)
    }

    @Test func aProfileWithoutAPinMayShowInAHouseWithNoKids() {
        #expect(TopShelfSnapshot.mayShow(accountId: "dad", rules: rules([mum, dad])))
    }

    /// Dad's rows were put up when no kid lived here; adding or changing a profile later takes them down.
    @Test func anAdultsRowsGoOnceAKidProfileExists() {
        #expect(!TopShelfSnapshot.mayShow(accountId: "dad", rules: rules([mum, dad, leo])))
        var teen = leo
        teen.role = .adult
        #expect(TopShelfSnapshot.mayShow(accountId: "dad", rules: rules([mum, dad, teen])))
    }

    @Test func aKidsRowsStayAndAPinOrAMissingProfileNeverShow() {
        #expect(TopShelfSnapshot.mayShow(accountId: "leo", rules: rules([mum, dad, leo])))
        #expect(!TopShelfSnapshot.mayShow(accountId: "mum", rules: rules([mum, dad, leo])))
        #expect(!TopShelfSnapshot.mayShow(accountId: "gone", rules: rules([mum, dad, leo])))
        // A kid who is switched to adult becomes unguarded while other kids remain.
        var other = account("zoe", .kid)
        other.role = .kid
        var grown = leo
        grown.role = .adult
        #expect(!TopShelfSnapshot.mayShow(accountId: "leo", rules: rules([mum, grown, other])))
    }
}

@Suite struct AwayLockTests {
    let t0: TimeInterval = 5_000

    @Test func backgroundedWithNoPlayerClosesAtOnce() {
        var lock = AwayLock()
        let r1 = lock.backgrounded(at: t0)
        #expect(r1)
    }

    /// Closing the profile would end Picture in Picture and the audio under the lock screen.
    @Test func backgroundedWithAPlayerOpenWaits() {
        var lock = AwayLock()
        lock.playerChanged(open: true)
        let r2 = lock.backgrounded(at: t0)
        #expect(!r2)
    }

    @Test func theWaitingRelockHappensWhenThePlayerClosesWhileAway() {
        var lock = AwayLock()
        lock.playerChanged(open: true)
        _ = lock.backgrounded(at: t0)
        let r3 = lock.playerClosed()
        #expect(r3)
        // A later return, however soon, is still a return after the relock; nothing is owed twice.
        let r4 = lock.returned(at: t0 + (5))
        #expect(!r4)
    }

    @Test func aPlayerThatClosesInTheAppRelocksNothing() {
        var lock = AwayLock()
        lock.playerChanged(open: true)
        let r5 = lock.playerClosed()
        #expect(!r5)
        #expect(!lock.playerOpen)
    }

    @Test func returningWithinTheGraceKeepsTheProfileAndAfterItClosesIt() {
        var soon = AwayLock()
        soon.playerChanged(open: true)
        _ = soon.backgrounded(at: t0)
        let r6 = soon.returned(at: t0 + (HouseRules.reopenGrace - 1))
        #expect(!r6)

        var late = AwayLock()
        late.playerChanged(open: true)
        _ = late.backgrounded(at: t0)
        let r7 = late.returned(at: t0 + (HouseRules.reopenGrace + 1))
        #expect(r7)
    }

    @Test func aShortInactiveTripUsesTheShortGrace() {
        var lock = AwayLock()
        lock.becameInactive(at: t0)
        let r8 = lock.returned(at: t0 + (HouseRules.shortTripGrace - 1))
        #expect(!r8)
        lock.becameInactive(at: t0)
        let r9 = lock.returned(at: t0 + (HouseRules.shortTripGrace + 1))
        #expect(r9)
    }

    @Test func onlyTheFirstLeaveCountsAndAClockThatWentBackwardsCloses() {
        var lock = AwayLock()
        lock.becameInactive(at: t0)
        _ = lock.backgrounded(at: t0 + (500))
        let r10 = lock.returned(at: t0 + (HouseRules.shortTripGrace + 1))
        #expect(r10)
        lock.becameInactive(at: t0)
        let r11 = lock.returned(at: t0 + (-5))
        #expect(r11)
        // Never left: nothing to close.
        var fresh = AwayLock()
        let r12 = fresh.returned(at: t0)
        #expect(!r12)
    }

    @Test func theGraceBoundaryCloses() {
        var lock = AwayLock()
        lock.becameInactive(at: t0)
        let r = lock.returned(at: t0 + HouseRules.shortTripGrace)
        #expect(r)
    }

    /// The clock the lock runs on is the monotonic one: nothing here reads the date, so
    /// setting it back cannot extend the grace. A restart (the reading goes back) closes.
    @Test func aReadingThatWentBackwardsFromARestartCloses() {
        var lock = AwayLock()
        lock.playerChanged(open: true)
        _ = lock.backgrounded(at: 9_000)
        let r = lock.returned(at: 40)
        #expect(r)
    }
}

@Suite struct RelockGateTests {
    @Test func aReturnWithNoPlayerRelocksAtOnce() {
        var gate = RelockGate()
        let g1 = gate.returned(relock: true)
        #expect(g1 == .lock)
        let g2 = gate.returned(relock: false)
        #expect(g2 == .none)
    }

    /// Past the grace a PIN profile never stays open: the player is closed, then the profile locks.
    @Test func aReturnPastTheGraceWithAPlayerOpenClosesItThenLocks() {
        var gate = RelockGate()
        gate.playerOpened()
        let g3 = gate.returned(relock: true)
        #expect(g3 == .closePlayer)
        #expect(gate.owed)
        let g4 = gate.playerClosed()
        #expect(g4)
        // Nothing is owed twice.
        gate.playerOpened()
        let g5 = gate.playerClosed()
        #expect(!g5)
    }

    @Test func aPlayerThatClosesWithNothingOwedRelocksNothing() {
        var gate = RelockGate()
        gate.playerOpened()
        let g6 = gate.returned(relock: false)
        #expect(g6 == .none)
        let g7 = gate.playerClosed()
        #expect(!g7)
        #expect(!gate.playerOpen)
    }
}
