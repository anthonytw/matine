import Foundation
import os

/// What the household sync needs from CloudKit; the real one is
/// `CloudKitHouseholdCloud`, tests use a fake.
public struct HouseholdCloudChanges: Sendable, Equatable {
    public var saved: [HouseholdMember]
    public var requests: [ApprovalRequest]
    /// The cloud's copy was started over (zone deleted, another Apple ID):
    /// everything is sent again.
    public var reset: Bool
    /// It was another Apple ID: what this device holds is not sent to it.
    public var accountChanged: Bool
    public init(saved: [HouseholdMember] = [], requests: [ApprovalRequest] = [], reset: Bool = false, accountChanged: Bool = false) {
        self.saved = saved
        self.requests = requests
        self.reset = reset || accountChanged
        self.accountChanged = accountChanged
    }
}

public protocol HouseholdCloud: Sendable {
    func account() async -> KeywordCloudAccount
    /// What changed since last time (the cloud object keeps its own change tokens).
    func fetchChanges() async throws -> HouseholdCloudChanges
    /// Sends members and requests; returns the record names CloudKit confirmed
    /// (`recordName` of a member, `id` of a request). Refused ones are absent.
    func save(members: [HouseholdMember], requests: [ApprovalRequest]) async throws -> Set<String>
    func delete(requestIds: [String]) async throws
    func reset() async
    func accountId() async -> String?
}

/// What this device knows of the household, kept in the Keychain beside the
/// tokens (this device only: it holds PINs, and a restored backup must not
/// bring them back).
struct HouseholdBook: Codable, Equatable {
    struct Entry: Codable, Equatable {
        /// The newest copy known, from the cloud or stamped here.
        var member: HouseholdMember
        /// The `modified` the cloud is known to hold.
        var sent: Int64
        /// The `modified` last applied to (or read from) this device's profile.
        var applied: Int64
    }

    var entries: [String: Entry] = [:]
    /// Profiles that were on this device when it joined another Apple ID: never sent to it.
    var muted: Set<String> = []
    /// Request ids already acted on, with when.
    var handled: [String: Int64] = [:]
    /// The iCloud user this book belongs to.
    var account: String?

    static let key = "household-book"
}

private let log = Logger(subsystem: "io.github.anthonytw.matine", category: "household")

/// Keeps this device's profiles and the household in iCloud the same: the
/// newest copy of each profile wins whole, nothing secret but the PIN
/// travels, and a change that would leave kids without a grown-up PIN is held back.
///
/// The book is this actor's state: loaded once, changed in place and saved
/// after each step, so a removal made while a sync is in flight is never
/// overwritten by that sync's older copy.
public actor HouseholdSync {
    public struct Approval: Sendable, Equatable {
        public var device: String
        public var name: String
    }

    public struct Report: Sendable, Equatable {
        /// This device's profiles changed (arrived, were edited or removed by the household).
        public var changed = false
        /// Profiles the household removed from this device.
        public var removed: [Account] = []
        /// Devices this one let in.
        public var approvals: [Approval] = []
        /// Profiles whose newer copy was not applied because it would break the house rules.
        public var held: [String] = []
        public var unavailable: String?
    }

    private let cloud: any HouseholdCloud
    private let profiles: Profiles
    private let now: @Sendable () -> Date
    private var book = HouseholdBook()
    private var loaded = false
    /// Users signed in a moment ago whose sign-in may still be undone ("No soy
    /// yo"): never stamped or published until released.
    private var held: Set<String> = []
    /// A sign-in waiting for approval is under way: a profile that appears meanwhile may be
    /// that sign-in, so none is published as new until `hold` has named it.
    private var holdingNewSignIns = false

    public init(cloud: any HouseholdCloud, profiles: Profiles, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cloud = cloud
        self.profiles = profiles
        self.now = now
    }

    // MARK: Book

    /// Reads the book once. A missing book is a new one; a Keychain error or a
    /// book that doesn't decode is not "empty": it throws, and nothing is saved over it.
    private func ensureBook() throws {
        guard !loaded else { return }
        if let data = try profiles.store.secrets.read(HouseholdBook.key) {
            book = try JSONDecoder().decode(HouseholdBook.self, from: data)
        }
        loaded = true
    }

    private func persist() {
        guard loaded, let data = try? JSONEncoder().encode(book) else { return }
        try? profiles.store.secrets.write(data, for: HouseholdBook.key)
    }

    private var seconds: Int64 { Int64(now().timeIntervalSince1970) }

    private func snapshot(_ account: Account, modified: Int64) -> HouseholdMember? {
        guard let pin = try? profiles.pins.storedPin(for: account.id) else {
            // No PIN, or one that can't be read: only the first is published.
            return (try? profiles.pins.hasPin(account.id)) == false ? HouseholdMember(account: account, pin: nil, modified: modified) : nil
        }
        return HouseholdMember(account: account, pin: pin, modified: modified)
    }

    private func name(of account: Account) -> String { HouseholdRecordName.make(server: account.server, userId: account.id) }

    // MARK: Sync

    /// Sends what changed here, takes what changed elsewhere, answers waiting
    /// approval requests. Safe to call often.
    public func sync() async -> Report {
        var report = Report()
        do { try ensureBook() } catch {
            report.unavailable = "household book unreadable: \(error)"
            log.error("household book unreadable")
            return report
        }
        switch await cloud.account() {
        case .available:
            if let id = await cloud.accountId() { claim(account: id) }
        case .noAccount:
            await cloud.reset()
            report.unavailable = "signed out of iCloud"
            return report
        case .unavailable(let why):
            report.unavailable = why
            return report
        }
        do {
            for round in 0..<3 {
                let changes = try await cloud.fetchChanges()
                if changes.accountChanged { switchAccount() }
                if changes.reset { for name in book.entries.keys { book.entries[name]?.sent = 0 } }
                if round == 0 { stampEdits() }
                merge(changes.saved)
                addNew()
                persist()
                await applyPending(&report)
                persist()
                await answer(changes.requests, &report)
                let outgoing = book.entries.filter { $0.value.member.modified > $0.value.sent && !book.muted.contains($0.key) }
                guard !outgoing.isEmpty else { break }
                let confirmed = try await cloud.save(members: outgoing.values.map(\.member), requests: [])
                for (name, entry) in outgoing where confirmed.contains(name) {
                    let sent = book.entries[name]?.sent ?? 0
                    book.entries[name]?.sent = max(sent, entry.member.modified)
                }
                persist()
                if confirmed.isEmpty { break }
            }
        } catch {
            report.unavailable = "\(error)"
        }
        book.handled = book.handled.filter { $0.value > seconds - 3600 }
        persist()
        if !report.held.isEmpty { log.notice("household: \(report.held.count) change(s) held back by the house rules") }
        if report.unavailable != nil { log.notice("household sync unavailable") }
        return report
    }

    /// Notes whose iCloud this book was made under. Another account than last
    /// time: the profiles here are kept but never sent to it.
    private func claim(account id: String) {
        defer { book.account = id }
        guard let known = book.account, known != id else { return }
        switchAccount()
    }

    private func switchAccount() {
        book.muted = Set(profiles.store.accounts().map(name(of:)))
        book.entries = [:]
        book.handled = [:]
    }

    /// A profile edited here since it was last in step with the household:
    /// stamped now, so it wins and is sent.
    private func stampEdits() {
        for account in profiles.store.accounts() {
            let name = name(of: account)
            guard !book.muted.contains(name), !held.contains(account.id), var entry = book.entries[name],
                  entry.applied >= entry.member.modified,
                  let snap = snapshot(account, modified: seconds), !snap.sameContent(as: entry.member) else { continue }
            var edited = snap
            edited.modified = max(seconds, entry.member.modified + 1)
            entry.member = edited
            entry.applied = edited.modified
            book.entries[name] = entry
        }
    }

    private func merge(_ incoming: [HouseholdMember]) {
        for member in incoming {
            let name = member.recordName
            // A record from the cloud puts this profile in the household again: it
            // is no longer one that was kept off the previous Apple ID.
            let wasMuted = book.muted.remove(name) != nil
            guard var entry = book.entries[name] else {
                // First meeting with a tombstone for a profile this device holds a live
                // session for: keep ours, stamped after the tombstone and sent.
                if member.removed, !wasMuted, let local = profiles.store.accounts().first(where: { $0.id == member.userId }),
                   ((try? profiles.store.token(for: local.id)) ?? nil) != nil,
                   let snap = snapshot(local, modified: max(seconds, member.modified + 1)) {
                    book.entries[name] = .init(member: snap, sent: 0, applied: snap.modified)
                } else {
                    book.entries[name] = .init(member: member, sent: member.modified, applied: 0)
                }
                continue
            }
            if member.supersedes(entry.member) {
                entry.member = member
                entry.sent = member.modified
                entry.applied = min(entry.applied, member.modified - 1)
            } else if member.modified == entry.member.modified, member.sameContent(as: entry.member) {
                entry.sent = max(entry.sent, member.modified)
            } else if member.modified <= entry.member.modified {
                // The cloud holds an older (or losing) copy: ours goes again.
                entry.sent = min(entry.sent, entry.member.modified - 1)
            }
            book.entries[name] = entry
        }
    }

    /// Profiles here that the household has never heard of.
    private func addNew() {
        guard !holdingNewSignIns else { return }
        for account in profiles.store.accounts() {
            let name = name(of: account)
            guard book.entries[name] == nil, !book.muted.contains(name), !held.contains(account.id),
                  let snap = snapshot(account, modified: seconds) else { continue }
            book.entries[name] = .init(member: snap, sent: 0, applied: snap.modified)
        }
    }

    // MARK: Applying the household here

    private struct Target {
        var name: String
        var member: HouseholdMember
        var local: Account?
        var localPinned: Bool

        /// 0: a profile or PIN arriving, 1: a role or PIN removal, 2: a removal.
        var order: Int {
            if member.removed { return 2 }
            if local == nil || (!localPinned && !member.pin.isEmpty) { return 0 }
            return 1
        }
    }

    private func applyPending(_ report: inout Report) async {
        let local = profiles.store.accounts()
        var targets: [Target] = []
        for (name, entry) in book.entries.sorted(by: { $0.key < $1.key }) where !book.muted.contains(name) {
            let member = entry.member
            let account = local.first { $0.id == member.userId }
            let missing = !member.removed && account == nil
            guard member.modified > entry.applied || missing else { continue }
            if let account, HouseholdRecordName.normalized(account.server) != HouseholdRecordName.normalized(member.server) {
                report.held.append(member.name)
                continue
            }
            // A PIN that isn't four digits is never read as "no PIN".
            if !member.removed, !member.pin.isEmpty, !PinGate.isValid(member.pin) {
                report.held.append(member.name)
                continue
            }
            let pinned = account.map { (try? profiles.pins.hasPin($0.id)) ?? true } ?? false
            targets.append(Target(name: name, member: member, local: account, localPinned: pinned))
        }
        guard !targets.isEmpty else { return }

        // Would these together keep kids behind a grown-up's PIN?
        func rules(applying chosen: [Target]) -> HouseRules {
            var accounts = local
            var pinned = Set(local.filter { (try? profiles.pins.hasPin($0.id)) ?? true }.map(\.id))
            for target in chosen {
                let member = target.member
                accounts.removeAll { $0.id == member.userId }
                pinned.remove(member.userId)
                if member.removed { continue }
                accounts.append(target.local.map(member.applied(to:)) ?? member.newAccount())
                if !member.pin.isEmpty { pinned.insert(member.userId) }
            }
            return HouseRules(accounts: accounts, hasPin: pinned.contains)
        }
        var chosen = targets
        if !rules(applying: targets).isSafe {
            // What doesn't touch the rules applies. The rest is added one at a time
            // (arrivals and PINs first, removals last), each kept only while the
            // house stays safe; the others wait for the next sync.
            func touches(_ target: Target) -> Bool {
                let member = target.member
                return member.removed != (target.local == nil) || target.local?.role != member.role || target.localPinned != !member.pin.isEmpty
            }
            chosen = targets.filter { !touches($0) }
            var waiting = targets.filter(touches).sorted { ($0.order, $0.name) < ($1.order, $1.name) }
            var progress = true
            while progress {
                progress = false
                for target in waiting where rules(applying: chosen + [target]).isSafe {
                    chosen.append(target)
                    waiting.removeAll { $0.name == target.name }
                    progress = true
                    break
                }
            }
            report.held.append(contentsOf: waiting.map(\.member.name))
        }
        for target in chosen { await apply(target, &report) }
    }

    private func apply(_ target: Target, _ report: inout Report) async {
        let member = target.member
        if member.removed {
            if let account = target.local {
                try? await profiles.signOut(account)
                report.removed.append(account)
                report.changed = true
            }
        } else {
            do {
                // The PIN first: a profile the household protects never exists without it, even briefly.
                let stored = try profiles.pins.storedPin(for: member.userId)
                var pinChanged = false
                if member.pin.isEmpty {
                    if stored != nil {
                        try profiles.pins.removePin(for: member.userId)
                        pinChanged = true
                    }
                } else if stored != member.pin {
                    try profiles.pins.setPin(member.pin, for: member.userId)
                    pinChanged = true
                }
                if let account = target.local {
                    let updated = member.applied(to: account)
                    if updated != account {
                        try profiles.store.update(updated)
                        report.changed = true
                    }
                } else {
                    do {
                        try profiles.store.insert(member.newAccount())
                    } catch {
                        if pinChanged { try? profiles.pins.removePin(for: member.userId) }
                        throw error
                    }
                    report.changed = true
                }
                if pinChanged { report.changed = true }
            } catch {
                report.held.append(member.name)
                return
            }
        }
        let applied = book.entries[target.name]?.applied ?? 0
        book.entries[target.name]?.applied = max(applied, member.modified)
    }

    // MARK: Removing

    /// "Quitar de todos los dispositivos": a tombstone every device obeys, and
    /// the profile goes from this one now. (The caller has already passed the
    /// house rules and the grown-up's PIN.) The tombstone is saved before the
    /// profile goes, and a sync in flight cannot overwrite it.
    public func removeEverywhere(_ account: Account) async throws {
        try ensureBook()
        let name = name(of: account)
        if !book.muted.contains(name) {
            let stamp = max(seconds, (book.entries[name]?.member.modified ?? 0) + 1)
            book.entries[name] = .init(
                member: HouseholdMember(account: account, pin: nil, modified: stamp, removed: true),
                sent: book.entries[name]?.sent ?? 0, applied: stamp
            )
            persist()
        }
        held.remove(account.id)
        try await profiles.signOut(account)
    }

    /// A sign-in that may still be undone: kept out of the household until
    /// `release`, so undoing it never writes anything.
    public func hold(userId: String) { held.insert(userId) }
    /// Set before awaiting a sign-in that may be undone, cleared once `hold` has named it (or it failed).
    public func holdNewSignIns(_ on: Bool) { holdingNewSignIns = on }
    public func release(userId: String) { held.remove(userId) }

    /// Undoes a held sign-in ("No soy yo"): the session ends and the profile
    /// goes from this device. Never a tombstone. A user the household already
    /// had comes back as a profile needing sign-in at the next sync; one it
    /// never heard of, and never sent, leaves no trace.
    public func forget(_ account: Account) async {
        try? ensureBook()
        try? await profiles.signOut(account)
        let name = name(of: account)
        if let entry = book.entries[name], entry.sent == 0 { book.entries[name] = nil }
        held.remove(account.id)
        persist()
    }

    // MARK: Approval

    /// Asks the household's other devices to approve `code`. Returns the
    /// request's id (to withdraw), nil when iCloud wouldn't take it.
    public func requestApproval(server: URL, userId: String, code: String, device: String) async -> String? {
        guard case .available = await cloud.account() else { return nil }
        let request = ApprovalRequest(server: server, userId: userId, code: code, device: device, created: now())
        guard let confirmed = try? await cloud.save(members: [], requests: [request]), confirmed.contains(request.id) else { return nil }
        return request.id
    }

    /// Takes a request back (approved, cancelled, lapsed).
    public func withdraw(_ id: String) async {
        try? await cloud.delete(requestIds: [id])
    }

    private func answer(_ requests: [ApprovalRequest], _ report: inout Report) async {
        guard !requests.isEmpty else { return }
        let local = profiles.store.accounts()
        var done: [String] = []
        for request in requests {
            let name = HouseholdRecordName.make(server: request.server, userId: request.userId)
            let holder = local.first { $0.id == request.userId }.map { account in
                ApprovalPolicy.Holder(
                    account: account, hasToken: ((try? profiles.store.token(for: account.id)) ?? nil) != nil,
                    inHousehold: book.entries[name].map { !$0.member.removed && !book.muted.contains(name) } ?? false
                )
            }
            switch ApprovalPolicy.decide(request, now: now(), holder: holder, alreadyHandled: book.handled[request.id] != nil) {
            case .skip:
                continue
            case .discard:
                done.append(request.id)
            case .approve:
                guard let account = holder?.account else { continue }
                // Saved before the call: a crash must not approve the same request again.
                book.handled[request.id] = seconds
                persist()
                do {
                    try await profiles.approveQuickConnect(code: request.code, as: account)
                    report.approvals.append(Approval(device: request.device, name: account.shownName))
                    done.append(request.id)
                } catch {
                    // The code stays on the other device's screen for anyone to approve by hand.
                }
            }
        }
        if !done.isEmpty { try? await cloud.delete(requestIds: done) }
    }
}

/// How the cloud tells the app something arrived (a push): the app sets what
/// happens, the cloud only fires it.
public final class HouseholdWake: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    public init() {}
    public func onFire(_ handler: @escaping @Sendable () -> Void) { lock.withLock { self.handler = handler } }
    public func fire() { lock.withLock { handler }?() }
}
