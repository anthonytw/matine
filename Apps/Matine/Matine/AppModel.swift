import Foundation
import MatineKit
import Observation
import SwiftUI
import TVServices

/// The app's one piece of state: which screen, which profile.
@MainActor @Observable
final class AppModel {
    typealias Screen = ProfileScreen

    let profiles: Profiles
    /// The household: these profiles, shared with the owner's other devices through iCloud.
    let household: HouseholdSync
    /// Shown briefly after this device let another one in (never over the player).
    private(set) var householdNotice: HouseholdNotice?
    struct HouseholdNotice: Equatable {
        let id = UUID()
        let device: String
        let name: String
    }
    @ObservationIgnored private var householdSyncing = false
    @ObservationIgnored private var householdDirty = false
    @ObservationIgnored private var householdDebounce: Task<Void, Never>?
    /// Search keywords a phone made, read from iCloud.
    let keywords = KeywordsModel()
    private(set) var accounts: [Account] = []
    /// Profiles behind a PIN, read once per `reload()` rather than per render.
    /// A Keychain error counts as locked: the gate fails closed.
    private(set) var lockedIds: Set<String> = []
    var screen: Screen = .picker {
        didSet {
            // A Top Shelf link waits only for its own profile (its PIN screen, then its home):
            // a cancelled PIN, a lock or a switch of profile drops it, so it never fires later.
            if let link = pendingLink {
                switch screen {
                case .pin(let account), .home(let account): if account.id != link.accountId { pendingLink = nil }
                default: pendingLink = nil
                }
            }
            // A PIN entered for one sign-in clears that one only: leaving its sign-in screen ends it.
            guard let id = unlockedForSignIn else { return }
            if case .addProfile(let again?) = screen, again.id == id { return }
            unlockedForSignIn = nil
        }
    }

    /// Bumped each time a player has closed and its Stopped report is sent:
    /// screens showing progress refresh on it.
    private(set) var playbackEndedCount = 0
    /// Something Home shows has changed (a pin, a playback): refresh on return.
    var homeIsStale = false
    /// The player covers everything: backdrops stop turning meanwhile.
    private(set) var playerIsOpen = false

    /// The open player's handler for the phone's pause, unpause, seek and stop,
    /// and which player (by id) it belongs to: a player that closes after the
    /// next one has opened must not clear the next one's.
    private var playerCommandHandler: ((RemoteCommand) -> Void)?
    private var playerOwner: UUID?
    /// A PIN profile's relock waits for an open player: swapping the screen
    /// out from under it would tear the player down mid-playback.
    private var relockGate = RelockGate()
    /// Back past the grace with a PIN profile's player open: the player covers
    /// itself and closes, and the profile locks once it has gone (`RelockGate`).
    private(set) var playerMustClose = false
    /// A PIN profile's player went to the background: it stays covered until the
    /// return is judged (within the grace it shows again; past it, it closes covered).
    private(set) var coverPinPlayer = false
    /// How many players have come on screen, so a waiting Play can tell its own appeared.
    /// (Commands are handled one at a time and a Play waits for its player, so a
    /// Stop sent right after a Play always finds the player's handler set.)
    private(set) var playerAppearances = 0

    func playerAppeared(_ id: UUID, handler: @escaping (RemoteCommand) -> Void) {
        playerIsOpen = true
        relockGate.playerOpened()
        playerAppearances += 1
        playerOwner = id
        playerCommandHandler = handler
    }

    func playerDisappeared(_ id: UUID) {
        guard playerOwner == id else { return }
        playerIsOpen = false
        playerOwner = nil
        playerCommandHandler = nil
        // A relock put off while this player was up (the TV came back from the screensaver mid-film).
        playerMustClose = false
        coverPinPlayer = false
        if relockGate.playerClosed() { relockIfNeeded() }
    }

    /// From the phone: to the open player; with none open, nothing to steer.
    func deliver(_ command: RemoteCommand) {
        playerCommandHandler?(command)
    }

    func playbackEnded() {
        playbackEndedCount += 1
        homeIsStale = true
    }

    #if DEBUG
    /// Set by the debug launch hook: "item:ID", "library:ID", "search", "settings",
    /// "manage", "play:ID" or "resume:ID".
    var debugRoute: String?
    /// -MatineDevLanguage: what the no-profile screens speak in this run (the picker), instead of Spanish.
    var debugDefaultLanguage: AppLanguage?
    /// "manage": Settings opens on the household's profiles, past the PIN.
    var debugOpensManage = false
    #endif

    /// Where a Top Shelf link leads, waiting until its profile is open (after
    /// the PIN, if it has one). Home takes it on appearing.
    var pendingLink: AppLink?

    /// The shared keychain group the Top Shelf extension reads; nil if the
    /// build has none (then no shelf is written).
    private let shelfStore: KeychainSecretStore? = (Bundle.main.object(forInfoDictionaryKey: "MatineKeychainGroup") as? String)
        .map { KeychainSecretStore(accessGroup: $0) }

    /// Signed-in clients, built once per profile and language (a new look or
    /// name keeps the client).
    private struct ClientKey: Hashable { let id: String, language: AppLanguage, deviceId: String }
    /// A cache, filled while views are drawn: not observed (a write from `body` would redraw it, and
    /// a missing token, which stores nil, would redraw it forever). Changes to `accounts` redraw.
    @ObservationIgnored private var clients: [ClientKey: JellyfinClient] = [:]

    private static func key(_ account: Account) -> ClientKey {
        ClientKey(id: account.id, language: account.language, deviceId: account.deviceId)
    }

    init(profiles: Profiles) {
        self.profiles = profiles
        let wake = HouseholdWake()
        // Built now, not on first use: the keywords' handler (made with `keywords`) and this one
        // must both be registered with the shared engine before it first runs.
        let cloud = CloudKitHouseholdCloud()
        cloud.onActivity { wake.fire() }
        household = HouseholdSync(cloud: cloud, profiles: profiles)
        // Keychain items outlive the app; profiles restored without them (or items without profiles) start clean.
        if (try? profiles.store.reconcileInstall()) == .restored {
            for key in [Self.lastProfileKey, Self.lastUnlockedKey, Self.awayKey] { UserDefaults.standard.removeObject(forKey: key) }
        }
        profiles.store.migrateRecentSearches()
        reload()
        wake.onFire { [weak self] in Task { @MainActor in await self?.syncHousehold() } }
        // Within the grace period of leaving, the profile that was open
        // (tvOS may have closed the app meanwhile); else the usual start.
        screen = navigator.launch(away: away, lastUnlocked: UserDefaults.standard.string(forKey: Self.lastUnlockedKey), hasToken: hasToken)
    }

    // MARK: Household

    /// Takes the household from iCloud, sends what changed here and answers
    /// other devices' approvals. One at a time; a call meanwhile runs again after.
    func syncHousehold() async {
        guard !householdSyncing else {
            householdDirty = true
            return
        }
        householdSyncing = true
        defer { householdSyncing = false }
        repeat {
            householdDirty = false
            applyHousehold(await household.sync())
        } while householdDirty
    }

    /// A little after a local change, so edits go out together.
    private func scheduleHouseholdSync() {
        householdDebounce?.cancel()
        householdDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.syncHousehold()
        }
    }

    private func applyHousehold(_ report: HouseholdSync.Report) {
        if report.changed || !report.removed.isEmpty {
            let wasEmpty = accounts.isEmpty
            refreshLists()
            for gone in report.removed {
                clearTopShelf(ifFor: gone)
                // A profile the household removed takes its search reading with it.
                MeaningCache.remove(accountId: gone.id)
            }
            let next = navigator.afterHousehold(screen, removed: report.removed, wasEmpty: wasEmpty)
            if next != screen { screen = next }
        }
        if let approval = report.approvals.last {
            let notice = HouseholdNotice(device: approval.device, name: approval.name)
            householdNotice = notice
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                if self?.householdNotice == notice { self?.householdNotice = nil }
            }
        }
    }

    func hasToken(_ account: Account) -> Bool { hasToken(account.id) }
    private func hasToken(_ id: String) -> Bool { ((try? profiles.store.token(for: id)) ?? nil) != nil }

    /// Waits for a Quick Connect code to be approved elsewhere, then saves the
    /// profile; a PIN profile goes through its PIN as every sign-in does.
    @discardableResult
    func finishQuickConnect(_ session: QuickConnectSession, policy: QuickConnectPolicy) async throws -> Account {
        let signedIn = try await profiles.finishQuickConnect(session, policy: policy)
        clients = clients.filter { $0.key.id != signedIn.account.id }
        reload()
        if case .addProfile = screen { landAfterSignIn(signedIn.account) }
        return signedIn.account
    }

    /// When the app was left and what was open (`AwayRecord`), saved as it changes.
    private var away: AwayRecord {
        get {
            UserDefaults.standard.data(forKey: Self.awayKey).flatMap { try? JSONDecoder().decode(AwayRecord.self, from: $0) } ?? AwayRecord()
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.awayKey) }
    }

    static func live() -> AppModel {
        // Before anything touches URLSession.shared: posters load through it.
        // Their URLs carry no token and change when the art does, so caching
        // them is safe; tvOS may purge the disk part at will. API calls use
        // their own ephemeral session and never land here.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 256 << 20)
        let secrets = KeychainSecretStore()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return AppModel(profiles: Profiles(
            store: AccountStore(settings: UserDefaults.standard, secrets: secrets),
            pins: PinGate(secrets: secrets),
            deviceName: "Apple TV",
            version: version
        ))
    }

    func reload() {
        refreshLists()
        scheduleHouseholdSync()
    }

    private func refreshLists() {
        accounts = profiles.store.accounts()
        lockedIds = Set(accounts.filter { (try? profiles.pins.hasPin($0.id)) ?? true }.map(\.id))
        let current = Set(accounts.map(Self.key))
        clients = clients.filter { current.contains($0.key) }
        pruneTopShelf()
    }

    /// The language the current screen speaks: the open profile's, else Spanish.
    var language: AppLanguage {
        switch screen {
        case .home(let account), .pin(let account): account.language
        case .picker, .addProfile, .adultCheck:
            #if DEBUG
            debugDefaultLanguage ?? .default
            #else
            .default
            #endif
        }
    }

    /// What kid profiles change here, from the profiles and PINs as last read.
    var rules: HouseRules { HouseRules(accounts: accounts, hasPin: lockedIds.contains) }

    /// What comes next on the profile and PIN screens (the decisions are MatineKit's, and tested there).
    private var navigator: ProfileNavigator { ProfileNavigator(rules: rules) }

    /// "Añadir perfil" on the picker: straight to sign-in, or a grown-up's PIN first.
    func addProfile() {
        screen = navigator.addProfile
    }

    /// Any adult's PIN (`PinGate.checkAny`); nil when it couldn't be checked.
    func checkAdultPin(_ pin: String) -> PinGate.Outcome? {
        try? profiles.pins.checkAny(pin, for: rules.adultsWithPin.map(\.id))
    }

    func setAvatar(_ avatar: Avatar, for account: Account) {
        save(account) { $0.avatar = avatar }
    }

    func setDisplayName(_ typed: String, for account: Account) {
        save(account) { $0.displayName = Profiles.cleanDisplayName(typed) }
    }

    /// Adult or kid; refused (and nothing saved) when the house rules say no.
    /// Why a profile change didn't happen.
    enum ChangeProblem: Error, Equatable {
        case refused(HouseRules.Refusal)
        case notSaved
    }

    func setRole(_ role: ProfileRole, for account: Account) -> ChangeProblem? {
        if let refusal = rules.refusal(changing: current(account), to: role) { return .refused(refusal) }
        return save(account) { $0.role = role } ? nil : .notSaved
    }

    /// Changes the saved copy; the open screen follows if it is this profile.
    @discardableResult
    private func save(_ account: Account, _ change: (inout Account) -> Void) -> Bool {
        var changed = current(account)
        change(&changed)
        let saved = (try? profiles.store.update(changed)) != nil
        reload()
        if case .home(let open) = screen, open.id == changed.id { screen = .home(changed) }
        return saved
    }

    func hasPin(_ account: Account) -> Bool { lockedIds.contains(account.id) }

    func choose(_ account: Account) {
        UserDefaults.standard.set(account.id, forKey: Self.lastProfileKey)
        apply(navigator.choose(account, from: screen))
    }

    private func apply(_ choice: ProfileNavigator.Choice) {
        if let unlocked = choice.unlocked { UserDefaults.standard.set(unlocked, forKey: Self.lastUnlockedKey) }
        // From the profile tab's switcher: Cancel on the PIN goes back there.
        pinCancelReturnsTo = choice.cancelReturnsTo
        screen = choice.screen
    }

    /// The profile that was open when a PIN profile was chosen from its
    /// switcher, for the PIN screen's Cancel.
    var pinCancelReturnsTo: Account?

    /// Cancel on a PIN screen: back to the profile it was chosen from, else the picker.
    func cancelPin() {
        let back = pinCancelReturnsTo
        pinCancelReturnsTo = nil
        screen = navigator.cancelPin(returnTo: back)
    }

    /// The profile whose PIN was entered in this same flow (its session expired while it was open).
    private var unlockedForSignIn: String?

    /// Where a sign-in lands: through the PIN gate, unless the PIN was just entered in this flow.
    private func landAfterSignIn(_ account: Account) {
        defer { unlockedForSignIn = nil }
        // Only for the profile whose sign-in screen this is: never a PIN profile without its PIN.
        guard let choice = navigator.landing(after: account, from: screen, pinEnteredFor: unlockedForSignIn) else { return }
        UserDefaults.standard.set(account.id, forKey: Self.lastProfileKey)
        apply(choice)
    }

    /// The profile opened last: the picker starts with it focused.
    var lastProfileId: String? { UserDefaults.standard.string(forKey: Self.lastProfileKey) }
    private static let lastProfileKey = "lastProfile"
    private static let lastUnlockedKey = "lastUnlockedProfile"
    private static let awayKey = "away"

    /// The server no longer accepts this profile's token (revoked, password
    /// changed): back to sign-in for it, from whichever screen noticed.
    /// True if `error` was that.
    @discardableResult
    func sessionExpired(_ error: any Error, userId: String) -> Bool {
        guard (error as? JellyfinError) == .unauthorized, let again = navigator.signInAgain(for: userId, from: screen) else { return false }
        // It was open, so its PIN (if any) was just entered: signing in again doesn't ask for it twice.
        if again.pinEntered { unlockedForSignIn = userId }
        screen = again.screen
        // Its rows come off the home screen with its session.
        clearTopShelf(ifFor: userId)
        return true
    }

    func client(for account: Account) -> JellyfinClient? {
        if let cached = clients[Self.key(account)] { return cached }
        let client = try? profiles.client(for: account)
        clients[Self.key(account)] = client
        return client
    }

    /// Away longer than the grace period closes a PIN profile, so whoever
    /// picks up the remote next starts on the last profile without a PIN
    /// (or the picker). A grown-up's PIN passed for "Añadir perfil" ends too.
    func relockIfNeeded() {
        pinCancelReturnsTo = nil
        unlockedForSignIn = nil
        let next = navigator.relocked(screen, lastUnlocked: UserDefaults.standard.string(forKey: Self.lastUnlockedKey), hasToken: hasToken)
        if next != screen { screen = next }
    }

    /// Bumped when the app comes back after a long time away: Home goes back
    /// to its top and refreshes, so the morning starts on fresh rows.
    private(set) var returnedAfterLongAwayCount = 0

    func phaseChanged(to phase: ScenePhase) {
        var record = away
        switch phase {
        case .active:
            Task { await syncHousehold() }
            guard let back = record.returned(at: Date()) else {
                coverPinPlayer = false
                return
            }
            away = record
            // Back within the grace period (one Back too many, a peek at the
            // screensaver): the profile is as it was. Longer: a PIN profile locks.
            switch relockGate.returned(relock: back.relock) {
            case .none: coverPinPlayer = false
            case .lock:
                coverPinPlayer = false
                relockIfNeeded()
            // The open player closes first (covered until it has); `playerDisappeared` then locks.
            case .closePlayer: playerMustClose = true
            }
            if back.away > 2 * 60 * 60 {
                homeIsStale = true
                returnedAfterLongAwayCount += 1
            }
        default:
            // Not locked yet: tvOS may close the app now, and a launch within
            // the grace period reopens this profile. Only the first leave counts.
            if case .home(let account) = screen { record.left(at: Date(), open: account.id) } else { record.left(at: Date(), open: nil) }
            if phase == .background, playerIsOpen, case .home(let account) = screen, hasPin(account) { coverPinPlayer = true }
            away = record
        }
    }

    /// The signed-in profile. Goes through `choose` (so a PIN profile asks for its PIN) only if the sign-in screen is
    /// still up: pressing Cancel mid-sign-in wins.
    @discardableResult
    func signIn(server: URL, username: String, password: String, expecting userId: String? = nil) async throws -> Account {
        let account = try await profiles.signIn(server: server, username: username, password: password, expecting: userId)
        clients = clients.filter { $0.key.id != account.id }
        reload()
        if case .addProfile = screen { landAfterSignIn(account) }
        return account
    }

    /// The saved copy of a profile (its language may have changed since a view captured it).
    func current(_ account: Account) -> Account { accounts.first { $0.id == account.id } ?? account }

    /// Why this profile can't leave the device now (the kids' last adult,
    /// or last adult with a PIN); nil when it can.
    func signOutRefusal(_ account: Account) -> HouseRules.Refusal? { rules.refusal(removing: current(account)) }

    /// Signs out of this device: the profile stays in the household, asking to sign in again.
    func signOut(_ account: Account) async { await leave(account, everywhere: false) }

    /// "Quitar de todos los dispositivos": the profile goes from every device of this Apple ID.
    func removeEverywhere(_ account: Account) async { await leave(account, everywhere: true) }

    private func leave(_ account: Account, everywhere: Bool) async {
        // Signing out here leaves the profile in the household; only removing it is subject to the house rules.
        guard !everywhere || signOutRefusal(account) == nil else { return }
        clients = clients.filter { $0.key.id != account.id }
        clearTopShelf(ifFor: account)
        // Posters hold no token, but what a profile browsed leaves with it.
        URLCache.shared.removeAllCachedResponses()
        if everywhere { try? await household.removeEverywhere(account) } else { try? await profiles.endSession(account) }
        reload()
        if everywhere { MeaningCache.remove(accountId: account.id) }
        screen = navigator.afterLeaving
    }

    func setLanguage(_ language: AppLanguage, for account: Account) {
        save(account) { $0.language = language }
    }

    func setPin(_ pin: String, for account: Account) throws {
        try profiles.pins.setPin(pin, for: account.id)
        // A PIN profile's viewing never stays on the home screen.
        clearTopShelf(ifFor: account)
        reload()
    }

    // MARK: Top Shelf

    /// Shows this profile's rows above the app on the home screen, but only a
    /// profile without a PIN: anyone holding the remote sees the shelf.
    func updateTopShelf(for account: Account, client: JellyfinClient, rows: [HomeRow]) {
        guard let shelfStore else { return }
        // Not a PIN profile, and not an adult in a house with kids.
        guard TopShelfSnapshot.mayShow(accountId: account.id, rules: rules) else {
            clearTopShelf(ifFor: account.id)
            return
        }
        // Written (and the system told, which fetches every tile's image again) only when it changed.
        let shelf = TopShelfSnapshot.make(account: account, client: client, rows: rows)
        guard shelf != storedTopShelf else { return }
        if let shelf, let data = try? shelf.encoded() {
            try? shelfStore.write(data, for: TopShelfSnapshot.key)
        } else {
            try? shelfStore.delete(TopShelfSnapshot.key)
        }
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private var storedTopShelf: TopShelfSnapshot? {
        guard let shelfStore, let data = (try? shelfStore.read(TopShelfSnapshot.key)) ?? nil else { return nil }
        return TopShelfSnapshot.decode(data)
    }

    /// Takes the shelf down when its profile may no longer be shown (a PIN was set, a kid
    /// profile was added or changed, the profile went): checked on every change of the
    /// profiles, not only when that profile's Home loads.
    private func pruneTopShelf() {
        guard let shown = storedTopShelf, !TopShelfSnapshot.mayShow(accountId: shown.accountId, rules: rules) else { return }
        clearTopShelf(ifFor: shown.accountId)
    }

    private func clearTopShelf(ifFor account: Account) { clearTopShelf(ifFor: account.id) }

    private func clearTopShelf(ifFor accountId: String) {
        guard let shelfStore, storedTopShelf?.accountId == accountId else { return }
        try? shelfStore.delete(TopShelfSnapshot.key)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    /// A matine:// link from the Top Shelf. It names a profile; opening it goes
    /// through the picker's own path (`choose`), so a PIN profile asks for its
    /// PIN first. Unknown links and profiles are ignored.
    func open(_ url: URL) {
        guard let link = AppLink(url), let account = accounts.first(where: { $0.id == link.accountId }) else { return }
        pendingLink = link
        if case .home(let open) = screen, open.id == account.id { return }
        choose(account)
    }

    func removePin(for account: Account) throws {
        if let refusal = rules.refusal(removingPinOf: current(account)) { throw ChangeProblem.refused(refusal) }
        try profiles.pins.removePin(for: account.id)
        reload()
    }

    /// Checks a PIN; nil when the Keychain couldn't be read, which never opens anything.
    func checkPin(_ pin: String, for account: Account) -> PinGate.Outcome? {
        try? profiles.pins.check(pin, for: account.id)
    }
}
