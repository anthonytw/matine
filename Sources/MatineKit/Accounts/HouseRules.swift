import Foundation

/// What kid profiles change on this Apple TV. A kid profile has no sign-out,
/// language, PIN or Fijados controls. Once a kid profile exists, a grown-up's
/// PIN is needed to add a profile, to switch one between adult and kid, and
/// to put a first PIN on (or sign out of) an adult profile that has none: a
/// kid who walks into such a profile can't make its PIN the household's key.
/// No change may leave kid profiles without an adult, or without an adult
/// with a PIN.
public struct HouseRules: Sendable {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// Making the last adult a kid would leave no one to undo it.
        case lastAdult
        /// After the change no adult would have a PIN, so a kid could undo it.
        case needsAdultPin

        public var description: String {
            switch self {
            case .lastAdult: "at least one profile must stay an adult"
            case .needsAdultPin: "an adult profile needs a PIN first"
            }
        }
    }

    public let accounts: [Account]
    let pinned: Set<String>

    /// `hasPin` is asked once per profile; a profile whose PIN can't be read
    /// should answer true (the app's gate fails closed the same way).
    public init(accounts: [Account], hasPin: (String) -> Bool) {
        self.accounts = accounts
        pinned = Set(accounts.map(\.id).filter(hasPin))
    }

    /// Whether `id`'s PIN is set (or couldn't be read).
    public func isPinned(_ id: String) -> Bool { pinned.contains(id) }

    public var adults: [Account] { accounts.filter { !$0.isKid } }
    public var hasKids: Bool { accounts.contains(where: \.isKid) }
    /// Kids always have an adult with a PIN to undo what they touch.
    public var isSafe: Bool { !hasKids || !adultsWithPin.isEmpty }
    /// The adults whose PIN `PinGate.checkAny` tries.
    public var adultsWithPin: [Account] { adults.filter { pinned.contains($0.id) } }

    /// Adult profiles a kid could simply walk into from the picker: only a
    /// worry once a kid profile exists.
    public var unguardedAdults: [Account] { hasKids ? adults.filter { !pinned.contains($0.id) } : [] }

    /// Whether grown-up changes (adding a profile; a first PIN on, or signing
    /// out of, a profile without one) ask for a grown-up's PIN: once a kid
    /// profile exists. (Until then there's no one to keep out.)
    public var needsGrownUp: Bool { hasKids && !adultsWithPin.isEmpty }

    /// The profile the app opens on by itself (at launch, and when a PIN
    /// profile locks): the last one opened without a PIN, while it still
    /// has none. Nil: the picker. A profile behind a PIN never opens
    /// unasked, and in a house with kids neither does a grown-up's without
    /// one: a kid picking up the remote would land in it without a click.
    public func opensByItself(lastUnlocked id: String?) -> Account? {
        guard let id, !pinned.contains(id), let account = accounts.first(where: { $0.id == id }) else { return nil }
        if hasKids, !account.isKid { return nil }
        return account
    }

    /// How long a profile stays open after the app is left (one Back too
    /// many, the screensaver, tvOS closing the app in the background): back
    /// within it, the same profile reopens without its PIN.
    public static let reopenGrace: TimeInterval = 10 * 60

    /// How long the phone keeps a profile open across a trip that left the app
    /// inactive (Control Center, a notification, Face ID): past it, a PIN profile locks.
    public static let shortTripGrace: TimeInterval = 60

    /// The profile that was open when the app was left, if it was left less
    /// than `grace` ago (and still exists): it reopens as it was, PIN or not,
    /// so a stray press of Back doesn't drop a grown-up into the kids'
    /// profile. Past that, or with a clock that went backwards, nil: the
    /// usual start (`opensByItself`, else the picker).
    public func reopens(open id: String?, leftAt: Date?, now: Date = Date(), grace: TimeInterval = reopenGrace) -> Account? {
        guard let id, let leftAt else { return nil }
        let away = now.timeIntervalSince(leftAt)
        guard away >= 0, away < grace else { return nil }
        return accounts.first { $0.id == id }
    }

    /// Putting a first PIN on `account`, or signing out of it, asks for a
    /// grown-up's PIN when it has none of its own to prove it's theirs.
    public func needsGrownUp(toChange account: Account) -> Bool {
        needsGrownUp && !pinned.contains(account.id)
    }

    /// What approving another device as `account` (Quick Connect hands out a
    /// long-lived session as that profile) must pass first.
    public enum ApproveGate: Equatable, Sendable {
        /// The profile's own PIN.
        case ownPin
        /// Any grown-up's PIN.
        case grownUpPin
        /// Nothing: no one to keep out.
        case open
        /// Not offered: a kid profile in a house with no grown-up PIN.
        case notAllowed
    }

    /// A kid profile may approve a device only behind a grown-up's PIN (and
    /// not at all when no grown-up has one). An adult uses their own PIN; one
    /// without, in a house with kids, a grown-up's.
    public func approveGate(for account: Account) -> ApproveGate {
        if account.isKid { return adultsWithPin.isEmpty ? .notAllowed : .grownUpPin }
        if pinned.contains(account.id) { return .ownPin }
        return needsGrownUp ? .grownUpPin : .open
    }

    /// Why `account` can't become `role`; nil when it can.
    public func refusal(changing account: Account, to role: ProfileRole) -> Refusal? {
        guard account.role != role else { return nil }
        let after = accounts.map { $0.id == account.id ? with($0, role) : $0 }
        if !after.contains(where: { !$0.isKid }) { return .lastAdult }
        return check(after: after, pinned: pinned)
    }

    /// Why `account`'s PIN can't be removed: it's the last adult PIN while
    /// kid profiles exist. Nil when it can.
    public func refusal(removingPinOf account: Account) -> Refusal? {
        check(after: accounts, pinned: pinned.subtracting([account.id]))
    }

    /// Why `account` can't be signed out (removed from this Apple TV); nil when it can.
    public func refusal(removing account: Account) -> Refusal? {
        check(after: accounts.filter { $0.id != account.id }, pinned: pinned.subtracting([account.id]))
    }

    private func check(after: [Account], pinned: Set<String>) -> Refusal? {
        guard after.contains(where: \.isKid) else { return nil }
        let adultsAfter = after.filter { !$0.isKid }
        if adultsAfter.isEmpty { return .lastAdult }
        if !adultsAfter.contains(where: { pinned.contains($0.id) }) { return .needsAdultPin }
        return nil
    }

    private func with(_ account: Account, _ role: ProfileRole) -> Account {
        var changed = account
        changed.role = role
        return changed
    }
}

/// When the app was left, and which profile was open then: the FIRST
/// moment it stopped being active (screensaver, Back to the Home screen),
/// kept until it is active again. Later phases while away (the TV going to
/// sleep an hour into the screensaver) never move it, so the grace period
/// counts from when someone actually walked away. Saved, so a relaunch after
/// tvOS closed the app knows too. Not secret (a profile id and a time, like
/// the profile list beside it in UserDefaults).
public struct AwayRecord: Codable, Sendable, Equatable {
    public private(set) var open: String?
    public private(set) var leftAt: Date?

    public init(open: String? = nil, leftAt: Date? = nil) {
        self.open = open
        self.leftAt = leftAt
    }

    /// The app stopped being active, with `open` on screen (nil: not a
    /// profile's home — the picker, a PIN screen, sign-in). Only the first
    /// call while away counts.
    public mutating func left(at time: Date, open: String?) {
        guard leftAt == nil else { return }
        leftAt = time
        self.open = open
    }

    /// The app is active again: how long it was away (nil if it never left),
    /// and whether a PIN profile left open must lock. Clears the record.
    public mutating func returned(at now: Date, grace: TimeInterval = HouseRules.reopenGrace) -> (away: TimeInterval, relock: Bool)? {
        defer { self = AwayRecord() }
        guard let leftAt else { return nil }
        let away = now.timeIntervalSince(leftAt)
        return (away, away < 0 || away >= grace)
    }
}

extension HouseRules {
    /// Where the app opens at launch: the profile that was open when it was
    /// left, if that was within the grace period; else the last profile
    /// without a PIN (`opensByItself`); else nil, the picker. Either needs a
    /// token: signed out meanwhile means the picker, not a sign-in.
    public func start(away: AwayRecord, lastUnlocked: String?, now: Date = Date(), hasToken: (String) -> Bool) -> Account? {
        if let back = reopens(open: away.open, leftAt: away.leftAt, now: now), hasToken(back.id) { return back }
        if let open = opensByItself(lastUnlocked: lastUnlocked), hasToken(open.id) { return open }
        return nil
    }
}

/// The TV's side of "a relock waits for an open player" (the phone's is
/// `AwayLock`, which also closes a profile the moment the app is backgrounded:
/// the TV only ever relocks on return, after `HouseRules.reopenGrace`, so it
/// needs just this). Swapping the screen out from under a presented player
/// tears the player's host view down mid-playback, so a relock due while a
/// player is open first closes the player (`closePlayer`), then locks once it
/// has gone (`playerClosed`). Past the grace nothing is mid-playback any more
/// (tvOS paused it), and a PIN profile never stays open past it. Nothing is
/// owed twice.
public struct RelockGate: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        /// Nothing to lock.
        case none
        /// Lock now.
        case lock
        /// Close the open player (covered meanwhile); the lock follows when it has gone.
        case closePlayer
    }

    public private(set) var playerOpen = false
    public private(set) var owed = false

    public init() {}

    /// The app came back and `AwayRecord.returned` said whether a PIN profile must lock.
    public mutating func returned(relock: Bool) -> Action {
        guard relock else { return .none }
        if playerOpen {
            owed = true
            return .closePlayer
        }
        return .lock
    }

    /// A player came on screen.
    public mutating func playerOpened() { playerOpen = true }

    /// The player closed. True: a relock was put off for it, so lock now.
    public mutating func playerClosed() -> Bool {
        playerOpen = false
        defer { owed = false }
        return owed
    }
}
