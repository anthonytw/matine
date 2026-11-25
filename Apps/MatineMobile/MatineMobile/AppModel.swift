import Foundation
import MatineKit
import Network
import Observation
import SwiftUI
import UIKit

/// The app's one piece of state: which screen, which profile. The same
/// rules as the Apple TV app (a PIN profile never opens without its PIN,
/// kid profiles lose the grown-up controls); the views differ, this does not.
@MainActor @Observable
final class AppModel {
    typealias Screen = ProfileScreen

    let profiles: Profiles
    /// The household: these profiles, shared with the owner's other devices through iCloud.
    let household: HouseholdSync
    /// Shown briefly after this device let another one in.
    private(set) var householdNotice: HouseholdNotice?
    struct HouseholdNotice: Equatable {
        let id = UUID()
        let device: String
        let name: String
    }
    @ObservationIgnored private var householdSyncing = false
    @ObservationIgnored private var householdDirty = false
    @ObservationIgnored private var householdDebounce: Task<Void, Never>?
    private(set) var accounts: [Account] = []
    /// Profiles behind a PIN, read once per `reload()` rather than per render.
    /// A Keychain error counts as locked: the gate fails closed.
    private(set) var lockedIds: Set<String> = []
    var screen: Screen = .picker {
        // A grown-up's PIN clears one trip to the sign-in screen, no more.
        didSet { if case .addProfile = screen {} else { grownUpCleared = false } }
    }
    /// Set when the grown-up's PIN screen was passed on the way to sign-in
    /// (needed to add a profile once a kid profile exists).
    var grownUpCleared = false
    /// A profile a code just signed in, shown on the sign-in screen's "No soy yo" panel (set and cleared by it).
    var pendingConfirmation: QuickConnectSignIn?

    /// Bumped each time a player has closed and its Stopped report is sent:
    /// screens showing progress refresh on it.
    private(set) var playbackEndedCount = 0
    func playbackEnded() { playbackEndedCount += 1 }

    #if DEBUG
    /// Set by the debug launch hook: "item:ID", "library:ID", "search", "profile", "play:ID".
    var debugRoute: String?
    /// -MatineDevLanguage: what the no-profile screens speak in this run (the picker), instead of Spanish.
    var debugDefaultLanguage: AppLanguage?
    #endif

    private struct ClientKey: Hashable { let id: String, language: AppLanguage, deviceId: String }
    /// A cache, filled while views are drawn: not observed (writing it from `body` would redraw the
    /// root a second time). Changes to `accounts` redraw.
    @ObservationIgnored private var sources: [ClientKey: HybridLibrarySource] = [:]

    /// The offline mirror's side: downloads, and whether the server answers.
    let downloads = DownloadsModel()
    let connection = ConnectionState()
    /// Search keywords: made here while charging, shared with the Apple TV through iCloud.
    let keywords = KeywordsModel()
    /// The server can't be reached: the screens read the downloads instead.
    private(set) var isOffline = false
    private let pathMonitor = NWPathMonitor()
    private var pathSatisfied = true
    /// The connection is metered (cellular, Personal Hotspot, Low Data Mode): the
    /// player then asks the server for a lighter stream. From the same path monitor.
    private(set) var isMetered = false
    private var probe: Task<Void, Never>?

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
        // Profiles restored from a backup come back without their PINs and
        // tokens (Keychain items stay on the device): start clean instead.
        if (try? profiles.store.reconcileInstall()) == .restored {
            UserDefaults.standard.removeObject(forKey: Self.lastUnlockedKey)
        }
        profiles.store.migrateRecentSearches()
        // The phone no longer keeps "the last profile opened" (the picker doesn't focus it).
        UserDefaults.standard.removeObject(forKey: "lastProfile")
        reload()
        screen = navigator.launch(lastUnlocked: UserDefaults.standard.string(forKey: Self.lastUnlockedKey), hasToken: hasToken)
        // Only the open profile is sent to sign-in; another's refused downloads wait for it to be opened.
        downloads.onSessionExpired = { [weak self] userId in
            guard let self, self.openAccount?.id == userId else { return }
            _ = self.sessionExpired(JellyfinError.unauthorized, userId: userId)
        }
        startConnectivity()
        keywords.registerBackgroundTask { [weak self] in await self?.refreshKeywords(background: true) }
        wake.onFire { [weak self] in Task { @MainActor in await self?.syncHousehold() } }
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

    /// A little after a local change (a PIN, a role, a sign-in), so edits go out together.
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
                sources = sources.filter { $0.key.id != gone.id }
                Task { await downloads.forget(userId: gone.id) }
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

    /// Takes and makes search keywords with a grown-up profile's catalog (it sees every
    /// library; keywords belong to the server, not the profile). Not offline. In the app
    /// only the open profile is used, and none while a kid profile is open; in the
    /// background (nobody is looking) a grown-up without a PIN is preferred, else any grown-up.
    func refreshKeywords(background: Bool = false) async {
        guard !isOffline else { return }
        keywordsRefreshedAt = Date()
        let candidates: [Account]
        if background {
            let adults = accounts.filter { !$0.isKid }
            candidates = adults.filter { !hasPin($0) } + adults.filter(hasPin)
        } else if let open = openAccount, !current(open).isKid {
            candidates = [current(open)]
        } else {
            return
        }
        guard let account = candidates.first(where: { client(for: $0) != nil }), let client = client(for: account) else { return }
        // In the app, the run ends when that profile is no longer the open one (a kid's opened, say).
        await keywords.refresh(account: account, client: client, profiles: profiles, background: background) { [weak self] in
            background || self?.openAccount?.id == account.id
        }
    }

    /// When keywords were last taken and made: coming back to the app within a few
    /// minutes (Control Center, a notification, Face ID) doesn't go to iCloud again.
    private var keywordsRefreshedAt: Date?
    private static let keywordsRefreshEvery: TimeInterval = 5 * 60

    private func refreshKeywordsIfDue() {
        guard openAccount != nil else { return }
        if let last = keywordsRefreshedAt, Date().timeIntervalSince(last) < Self.keywordsRefreshEvery { return }
        Task { await refreshKeywords() }
    }

    // MARK: Offline

    private func startConnectivity() {
        connection.onChange { [weak self] offline in
            Task { @MainActor in self?.connectionChanged(offline: offline) }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.pathChanged(satisfied: satisfied, metered: metered) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
    }

    /// The system's word that the network is back isn't the server's: while the
    /// mirror is showing, ask it every 15 seconds. Not running while online.
    private func startProbing() {
        guard probe == nil else { return }
        probe = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.probeIfOffline()
            }
        }
    }

    private func stopProbing() {
        probe?.cancel()
        probe = nil
    }

    private func pathChanged(satisfied: Bool, metered: Bool) {
        isMetered = metered
        pathSatisfied = satisfied
        if !satisfied { connection.set(offline: true) } else if isOffline { Task { await probeIfOffline() } }
    }

    private func connectionChanged(offline: Bool) {
        isOffline = offline
        if offline { startProbing() } else { stopProbing() }
        // Screens showing the library reload once on a change: now going
        // offline, after the catch-up coming back.
        if offline { playbackEnded() } else { Task { await syncDownloads(reconnected: true) } }
    }

    private func probeIfOffline() async {
        guard isOffline, pathSatisfied, let account = openAccount ?? accounts.first else { return }
        if await profiles.anonymousClient(server: account.server).isReachable() { connection.set(offline: false) }
    }

    private var openAccount: Account? {
        if case .home(let account) = screen { return account }
        return nil
    }

    /// Sends the progress made offline and takes the server's current progress; picks interrupted downloads back up.
    func syncDownloads(reconnected: Bool = false) async {
        guard let account = openAccount, !isOffline, let client = try? profiles.client(for: account) else {
            if reconnected { playbackEnded() }
            return
        }
        let store = downloads.store(for: account.id)
        let downloader = downloads.downloader
        await downloader.resumeAll(client: client, userId: account.id)
        var sent = 0
        do {
            sent = try await DownloadSync.run(
                store: store, queue: downloads.queue(for: account.id), client: client,
                removed: { id in Task { await downloader.remove(itemId: id, userId: account.id) } }
            )
            downloads.load(userId: account.id)
        } catch {
            _ = sessionExpired(error, userId: account.id)
        }
        // Screens reload once, and only if something changed under them.
        if reconnected || sent > 0 { playbackEnded() }
    }

    /// A profile was opened: read its downloads and catch up with the server.
    func profileOpened(_ account: Account) async {
        downloads.load(userId: account.id)
        if pathSatisfied == false { connection.set(offline: true) }
        await syncDownloads()
    }

    /// The signed-in client, for downloads (nil without a token).
    func client(for account: Account) -> JellyfinClient? { try? profiles.client(for: account) }

    func download(_ item: Item, account: Account) {
        guard !isOffline, let client = client(for: account) else { downloads.problem = true; return }
        downloads.download(item, client: client, userId: account.id)
    }

    func downloadSeason(seriesId: String, seasonId: String, episodes: [Item], account: Account) {
        guard !isOffline, let client = client(for: account) else { downloads.problem = true; return }
        downloads.downloadSeason(seriesId: seriesId, seasonId: seasonId, episodes: episodes, client: client, userId: account.id)
    }

    func retryDownloads(account: Account) {
        guard !isOffline, let client = client(for: account) else { downloads.problem = true; return }
        downloads.retry(client: client, userId: account.id)
    }

    /// The offline mirror on its own: what the Descargas place shows.
    func localSource(for account: Account) -> LocalLibrarySource {
        LocalLibrarySource(store: downloads.store(for: account.id), queue: downloads.queue(for: account.id))
    }

    static func live() -> AppModel {
        // Posters load through URLSession.shared. Their URLs carry no token and
        // change when the art does, so caching them is safe. API calls use their
        // own ephemeral session and never land here.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 256 << 20)
        let secrets = KeychainSecretStore()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        return AppModel(profiles: Profiles(
            store: AccountStore(settings: UserDefaults.standard, secrets: secrets),
            pins: PinGate(secrets: secrets),
            deviceName: device,
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
        sources = sources.filter { current.contains($0.key) }
    }

    /// The language the current screen speaks: the open profile's, else Spanish.
    var language: AppLanguage {
        switch screen {
        case .home(let account), .pin(let account): current(account).language
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

    func addProfile() { screen = navigator.addProfile }

    /// Any adult's PIN (`PinGate.checkAny`); nil when it couldn't be checked.
    func checkAdultPin(_ pin: String) -> PinGate.Outcome? {
        try? profiles.pins.checkAny(pin, for: rules.adultsWithPin.map(\.id))
    }

    func hasPin(_ account: Account) -> Bool { lockedIds.contains(account.id) }

    func choose(_ account: Account) {
        let choice = navigator.choose(account, from: screen)
        if let unlocked = choice.unlocked { UserDefaults.standard.set(unlocked, forKey: Self.lastUnlockedKey) }
        screen = choice.screen
    }

    /// Cancel on a PIN screen: the picker (a profile is only ever chosen from there, or from a sign-in).
    func cancelPin() { screen = .picker }

    private static let lastUnlockedKey = "lastUnlockedProfile"

    /// The server no longer accepts this profile's token: back to sign-in for
    /// it, from whichever screen noticed. True if `error` was that.
    @discardableResult
    func sessionExpired(_ error: any Error, userId: String) -> Bool {
        guard (error as? JellyfinError) == .unauthorized, let again = navigator.signInAgain(for: userId, from: screen) else { return false }
        screen = again.screen
        return true
    }

    /// Every screen of the open profile reads through this (see `LibrarySource`).
    func source(for account: Account) -> (any LibrarySource)? {
        if let cached = sources[Self.key(account)] { return cached }
        guard let client = try? profiles.client(for: account) else { return nil }
        let server = ServerLibrarySource(client: client, userId: account.id, device: profiles.deviceName)
        let source = HybridLibrarySource(server: server, local: localSource(for: account), connection: connection)
        sources[Self.key(account)] = source
        return source
    }

    /// Leaving the app closes a PIN profile: whoever picks up the device next
    /// starts on the last profile without a PIN (or the picker). A grown-up's
    /// PIN passed for "Añadir perfil" ends the same way.
    func relockIfNeeded() {
        // The "No soy yo" panel is up: the new profile is held until someone confirms or refuses it, and
        // leaving the screen would release it unconfirmed. The panel stays; a grown-up's PIN does not.
        if pendingConfirmation != nil, case .addProfile = screen {
            grownUpCleared = false
            return
        }
        let next = navigator.relocked(screen, lastUnlocked: UserDefaults.standard.string(forKey: Self.lastUnlockedKey), hasToken: hasToken)
        if next != screen { screen = next }
    }

    // MARK: The player and the lock

    /// When the app was left and whether a player was open (`AwayLock`): a PIN profile
    /// backgrounded with a player open keeps it (Picture in Picture, audio under the lock screen).
    private var lock = AwayLock()
    var playerOpen: Bool { lock.playerOpen }

    func playerAppeared() { lock.playerChanged(open: true) }

    /// The player closed. If the app is not active (it ended in PiP, or while the screen was
    /// locked) and the relock was put off, the PIN profile closes now.
    func playerDisappeared() {
        if lock.playerClosed() { relockIfNeeded() }
    }

    func phaseChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            refreshKeywordsIfDue()
            Task { await syncHousehold() }
            if lock.returned(at: PinGate.systemUptime()) { relockIfNeeded() }
        case .background:
            if lock.backgrounded(at: PinGate.systemUptime()) { relockIfNeeded() }
            keywords.scheduleBackgroundTask()
        default:
            lock.becameInactive(at: PinGate.systemUptime())
        }
    }

    /// The signed-in profile. Opens it only if the sign-in screen is still up,
    /// and through `choose`, so a profile that has a PIN asks for it.
    @discardableResult
    func signIn(server: URL, username: String, password: String, expecting userId: String? = nil) async throws -> Account {
        let account = try await profiles.signIn(server: server, username: username, password: password, expecting: userId)
        downloads.store(for: account.id).clearResumeData()
        sources = sources.filter { $0.key.id != account.id }
        reload()
        if let choice = navigator.landing(after: account, from: screen) {
            if let unlocked = choice.unlocked { UserDefaults.standard.set(unlocked, forKey: Self.lastUnlockedKey) }
            screen = choice.screen
        }
        return account
    }

    /// Waits for a Quick Connect code to be approved elsewhere, then saves the
    /// profile and opens it as `signIn` does (a PIN profile lands on its PIN).
    /// `policy` says who may be approved. Cancelling the caller's task stops the polling.
    @discardableResult
    func finishQuickConnect(_ session: QuickConnectSession, policy: QuickConnectPolicy) async throws -> Account {
        let signedIn = try await finishQuickConnectHeld(session, policy: policy)
        land(signedIn)
        return signedIn.account
    }

    /// Signs in and saves the profile, but stays where it is: the sign-in
    /// screen first says who it signed in as (a code announced on the network
    /// is not secret), then `land` opens it or `refuseSignIn` undoes it.
    func finishQuickConnectHeld(_ session: QuickConnectSession, policy: QuickConnectPolicy) async throws -> QuickConnectSignIn {
        await household.holdNewSignIns(true)
        let signedIn: QuickConnectSignIn
        do {
            signedIn = try await profiles.finishQuickConnect(session, policy: policy)
        } catch {
            await household.holdNewSignIns(false)
            throw error
        }
        // A new profile may still be undone ("No soy yo"): kept out of the household until `land`.
        if signedIn.isNew { await household.hold(userId: signedIn.account.id) }
        await household.holdNewSignIns(false)
        downloads.store(for: signedIn.account.id).clearResumeData()
        sources = sources.filter { $0.key.id != signedIn.account.id }
        refreshLists()
        return signedIn
    }

    /// Opens the profile a code just signed in (a PIN profile lands on its PIN).
    func land(_ signedIn: QuickConnectSignIn) {
        pendingConfirmation = nil
        Task { await household.release(userId: signedIn.account.id) }
        scheduleHouseholdSync()
        guard case .addProfile = screen else { return }
        switch signedIn.landing {
        case .home: choose(signedIn.account)
        case .pin: screen = .pin(signedIn.account)
        }
    }

    /// "No soy yo": ends the session and forgets the profile at once, past
    /// the house rules about signing out (someone else signed in). Only for a
    /// profile that was new to this phone: removing it is rule-safe, while an
    /// existing one might be the last grown-up with a PIN.
    func refuseSignIn(_ signedIn: QuickConnectSignIn) async {
        pendingConfirmation = nil
        guard signedIn.isNew else { return }
        let account = signedIn.account
        sources = sources.filter { $0.key.id != account.id }
        // The empty download folder the sign-in made goes too.
        await downloads.forget(userId: account.id)
        // Never a tombstone: the sign-in is undone, not a profile removed from the household.
        await household.forget(account)
        reload()
    }

    /// The saved copy of a profile (its language may have changed since a view captured it).
    func current(_ account: Account) -> Account { accounts.first { $0.id == account.id } ?? account }

    func signOutRefusal(_ account: Account) -> HouseRules.Refusal? { rules.refusal(removing: current(account)) }

    /// Signs out of this device: the profile stays in the household, asking to sign in again.
    func signOut(_ account: Account) async { await leave(account, everywhere: false) }

    /// "Quitar de todos los dispositivos": the profile goes from every device of this Apple ID.
    func removeEverywhere(_ account: Account) async { await leave(account, everywhere: true) }

    private func leave(_ account: Account, everywhere: Bool) async {
        // Signing out here leaves the profile in the household; only removing it is subject to the house rules.
        guard !everywhere || signOutRefusal(account) == nil else { return }
        sources = sources.filter { $0.key.id != account.id }
        // Posters hold no token, but what a profile browsed leaves with it.
        URLCache.shared.removeAllCachedResponses()
        // Downloads belong to the profile: they go with it, after the progress
        // made offline reaches the server (if it can).
        if !isOffline, let client = client(for: account) {
            _ = try? await downloads.queue(for: account.id).flush(client: client, userId: account.id)
        }
        await downloads.forget(userId: account.id)
        if everywhere { try? await household.removeEverywhere(account) } else { try? await profiles.endSession(account) }
        reload()
        if everywhere { MeaningCache.remove(accountId: account.id) }
        screen = navigator.afterLeaving
    }

    @discardableResult
    private func save(_ account: Account, _ change: (inout Account) -> Void) -> Bool {
        var changed = current(account)
        change(&changed)
        let saved = (try? profiles.store.update(changed)) != nil
        reload()
        if case .home(let open) = screen, open.id == changed.id { screen = .home(changed) }
        return saved
    }

    func setLanguage(_ language: AppLanguage, for account: Account) {
        save(account) { $0.language = language }
    }

    func setPin(_ pin: String, for account: Account) throws {
        try profiles.pins.setPin(pin, for: account.id)
        reload()
    }

    enum ChangeProblem: Error, Equatable { case refused(HouseRules.Refusal) }

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
