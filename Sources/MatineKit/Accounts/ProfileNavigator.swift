import Foundation

/// Which screen an app shows: the picker, a sign-in, a PIN, or a profile's
/// home. The same on the Apple TV and the phone.
public enum ProfileScreen: Equatable, Sendable {
    case picker
    /// Sign in: a new profile, or (with an account) again for one whose
    /// token is gone or expired, prefilled with its server and name.
    case addProfile(Account?)
    case pin(Account)
    case home(Account)
    /// A grown-up's PIN before adding a profile (once a kid profile exists).
    case adultCheck
}

/// The decisions behind the profile and PIN screens: what comes next, and
/// whether a PIN is needed. Pure (profiles, PINs and tokens as passed in), so
/// the rules that keep a PIN profile closed are tested once and both apps
/// follow them. Each app maps the answer onto its own views and keeps its own
/// storage (what was opened last, when it was left).
public struct ProfileNavigator: Sendable {
    public let rules: HouseRules

    public init(rules: HouseRules) { self.rules = rules }

    func isPinned(_ account: Account) -> Bool { rules.pinned.contains(account.id) }

    /// The saved copy of a profile (its language may have changed since a view captured it).
    public func current(_ account: Account) -> Account { rules.accounts.first { $0.id == account.id } ?? account }

    // MARK: Starting

    /// Where the app opens at launch. No profiles: sign in. Else
    /// `HouseRules.start` (a profile left open within the grace period, else
    /// the last one opened without a PIN), else the picker. A profile with no
    /// token (signed out meanwhile) never opens: the picker, not a sign-in.
    /// An app that keeps no away record passes none.
    public func launch(away: AwayRecord = AwayRecord(), lastUnlocked: String?, now: Date = Date(), hasToken: (String) -> Bool) -> ProfileScreen {
        if rules.accounts.isEmpty { return .addProfile(nil) }
        return rules.start(away: away, lastUnlocked: lastUnlocked, now: now, hasToken: hasToken).map { .home($0) } ?? .picker
    }

    /// Where the app returns when a PIN profile locks: the last profile
    /// without a PIN that was opened (the kids', typically), else the picker.
    /// What opens on its own is never one behind a PIN.
    public func unlockedStart(lastUnlocked: String?, hasToken: (String) -> Bool) -> ProfileScreen {
        guard let account = rules.opensByItself(lastUnlocked: lastUnlocked), hasToken(account.id) else { return .picker }
        return .home(account)
    }

    // MARK: Choosing

    /// What choosing a profile does.
    public struct Choice: Equatable, Sendable {
        public var screen: ProfileScreen
        /// The profile to remember as the last opened without a PIN (it opened by itself); nil when none.
        public var unlocked: String?
        /// Where Cancel on the PIN screen goes back to (the profile it was chosen from); nil: the picker.
        public var cancelReturnsTo: Account?
    }

    /// A profile was chosen (picker, a profile switcher, a Top Shelf link): its
    /// PIN first if it has one, else straight in.
    public func choose(_ account: Account, from screen: ProfileScreen) -> Choice {
        if isPinned(account) {
            var open: Account?
            if case .home(let from) = screen { open = from }
            return Choice(screen: .pin(account), unlocked: nil, cancelReturnsTo: open)
        }
        return Choice(screen: .home(account), unlocked: account.id, cancelReturnsTo: nil)
    }

    /// Cancel on a PIN screen: back to the profile it was chosen from, else the picker.
    public func cancelPin(returnTo: Account?) -> ProfileScreen {
        returnTo.map { .home(current($0)) } ?? .picker
    }

    // MARK: Signing in

    /// "Añadir perfil": straight to sign-in, or a grown-up's PIN first.
    public var addProfile: ProfileScreen { rules.needsGrownUp ? .adultCheck : .addProfile(nil) }

    /// What a sign-in does once it has saved `account`. Only while the
    /// sign-in screen is still up (Cancel mid-sign-in wins): nil otherwise.
    /// A PIN profile lands on its PIN screen, never straight on its home,
    /// unless its PIN was just entered in this same flow (`pinEnteredFor`: its
    /// session ended while it was open) and this is that profile's own sign-in.
    public func landing(after account: Account, from screen: ProfileScreen, pinEnteredFor: String? = nil) -> Choice? {
        guard case .addProfile(let again) = screen else { return nil }
        if let again, again.id == account.id, pinEnteredFor == account.id {
            return Choice(screen: .home(account), unlocked: nil, cancelReturnsTo: nil)
        }
        return choose(account, from: screen)
    }

    /// The server stopped accepting `userId`'s token: its sign-in screen, and
    /// whether that profile was open (its PIN was just entered, so signing in
    /// again doesn't ask twice). Nil when there is no such profile.
    public func signInAgain(for userId: String, from screen: ProfileScreen) -> (screen: ProfileScreen, pinEntered: Bool)? {
        guard let account = rules.accounts.first(where: { $0.id == userId }) else { return nil }
        if case .home(let open) = screen, open.id == userId { return (.addProfile(account), true) }
        return (.addProfile(account), false)
    }

    // MARK: Locking

    /// What a profile left open becomes once the app has been away long enough
    /// (or, on the phone, was backgrounded): a PIN profile closes, so whoever
    /// picks the device up next starts on `unlockedStart`. A sign-in screen
    /// reached through a grown-up's PIN, or that PIN screen itself, goes back
    /// to the picker: the PIN passed there is not good for whoever comes next.
    public func relocked(_ screen: ProfileScreen, lastUnlocked: String?, hasToken: (String) -> Bool) -> ProfileScreen {
        switch screen {
        case .home(let account) where isPinned(account):
            return unlockedStart(lastUnlocked: lastUnlocked, hasToken: hasToken)
        case .addProfile(nil) where rules.needsGrownUp, .adultCheck:
            return .picker
        default:
            return screen
        }
    }

    // MARK: Changes

    /// After profiles were signed out or removed on this device: the next screen.
    public var afterLeaving: ProfileScreen { rules.accounts.isEmpty ? .addProfile(nil) : .picker }

    /// After the household changed this device's profiles (`rules` are the new
    /// ones): an open profile that was removed goes to the picker (or sign-in
    /// when none is left), an open home follows its saved copy, and the first
    /// profile to arrive on an empty sign-in screen shows the picker.
    public func afterHousehold(_ screen: ProfileScreen, removed: [Account], wasEmpty: Bool) -> ProfileScreen {
        switch screen {
        case .home(let open), .pin(let open):
            if removed.contains(where: { $0.id == open.id }) { return afterLeaving }
            if case .home = screen { return .home(current(open)) }
            return screen
        case .addProfile(nil) where wasEmpty && !rules.accounts.isEmpty:
            return .picker
        case .addProfile(let again?) where removed.contains { $0.id == again.id }:
            // Signing in again for a profile the household has just removed.
            return afterLeaving
        default:
            return screen
        }
    }
}

/// When the phone closes a PIN profile after the app was left. Pure, so the
/// rule is tested here: a profile closes the moment the app is backgrounded,
/// except while a player is open. Closing it then would end Picture in
/// Picture and the audio under the lock screen (the player is part of the
/// profile's screen). Its relock waits instead: it happens when the player
/// closes while the app is not active, or on return when the app was away
/// for `HouseRules.reopenGrace` or longer. A shorter trip that left the app
/// only inactive (Control Center, a notification) keeps it for
/// `HouseRules.shortTripGrace`.
///
/// Times are seconds on the monotonic clock (`PinGate.systemUptime`), never
/// the date: setting the date back must not stretch the grace. A reading that
/// went backwards (a restart) closes the profile. While a player is open and
/// the app is in the background the app switcher's snapshot shows the player,
/// so the player covers itself (`PlayerView` overlays `PrivacyCover`).
public struct AwayLock: Sendable, Equatable {
    public private(set) var playerOpen = false
    public private(set) var isActive = true
    private var since: TimeInterval?
    private var waitingForPlayer = false

    public init() {}

    /// A player came on screen, or went.
    public mutating func playerChanged(open: Bool) { playerOpen = open }

    /// The app stopped being active without being backgrounded (Control Center, a notification).
    public mutating func becameInactive(at uptime: TimeInterval) {
        isActive = false
        if since == nil { since = uptime }
    }

    /// The app went to the background. True: close a PIN profile now.
    public mutating func backgrounded(at uptime: TimeInterval) -> Bool {
        isActive = false
        if since == nil { since = uptime }
        if playerOpen {
            waitingForPlayer = true
            return false
        }
        return true
    }

    /// The player closed. True: a relock was put off for it and the app is
    /// still away, so a PIN profile closes now.
    public mutating func playerClosed() -> Bool {
        playerOpen = false
        defer { if isActive { waitingForPlayer = false } }
        return waitingForPlayer && !isActive
    }

    /// The app is active again. True: it was away long enough that a PIN
    /// profile closes. (A reading that went backwards proves nothing: it closes.)
    public mutating func returned(at uptime: TimeInterval) -> Bool {
        let waited = waitingForPlayer
        waitingForPlayer = false
        isActive = true
        guard let left = since else { return false }
        since = nil
        let away = uptime - left
        return away < 0 || away >= (waited ? HouseRules.reopenGrace : HouseRules.shortTripGrace)
    }
}
