import CryptoKit
import Foundation

/// The household: the profiles every device of one Apple ID shows, kept in the
/// owner's private iCloud database. A member is what a profile is minus what
/// belongs to one device: no token, no device id, no PIN attempts, no recent
/// searches, and nothing about what anyone watches. The PIN travels with it
/// (encrypted in CloudKit, readable on the owner's devices only), so a profile
/// that shows up on a new device asks for the same PIN there.

/// A record's name: a hash of the server's address and the user's id, so no
/// user name appears in CloudKit's names.
public enum HouseholdRecordName {
    /// A server address as compared and hashed: no trailing slash.
    public static func normalized(_ server: URL) -> String {
        var address = server.absoluteString
        while address.hasSuffix("/") { address.removeLast() }
        return address
    }

    public static func make(server: URL, userId: String) -> String {
        let digest = SHA256.hash(data: Data((normalized(server) + "\u{0}" + userId).utf8))
        return "p" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

public struct HouseholdMember: Codable, Sendable, Equatable, CustomStringConvertible {
    public var server: URL
    public var userId: String
    public var name: String
    /// "" when the profile has none.
    public var displayName: String
    public var role: ProfileRole
    public var avatar: Avatar
    public var language: AppLanguage
    /// "" when the profile has no PIN.
    public var pin: String
    /// When it last changed, in seconds since 1970. The newest copy wins whole.
    public var modified: Int64
    /// A tombstone: the profile was removed from every device.
    public var removed: Bool

    public init(
        server: URL, userId: String, name: String, displayName: String = "", role: ProfileRole = .adult, avatar: Avatar? = nil,
        language: AppLanguage = .default, pin: String = "", modified: Int64, removed: Bool = false
    ) {
        self.server = server
        self.userId = userId
        self.name = name
        self.displayName = displayName
        self.role = role
        self.avatar = avatar ?? .initial(for: userId)
        self.language = language
        self.pin = pin
        self.modified = modified
        self.removed = removed
    }

    public init(account: Account, pin: String?, modified: Int64, removed: Bool = false) {
        self.init(
            server: account.server, userId: account.id, name: account.name, displayName: account.displayName ?? "", role: account.role,
            avatar: account.avatar, language: account.language, pin: pin ?? "", modified: modified, removed: removed
        )
    }

    /// Never shows the PIN (a log line or a failed test must not leak it).
    public var description: String {
        "HouseholdMember(\(recordName), role: \(role.rawValue), pin: \(pin.isEmpty ? "none" : "set"), modified: \(modified), removed: \(removed))"
    }

    public var recordName: String { HouseholdRecordName.make(server: server, userId: userId) }

    /// Everything but `modified`.
    func sameContent(as other: HouseholdMember) -> Bool {
        var copy = other
        copy.modified = modified
        return copy == self
    }

    /// A stable text of the whole member, to break a tie between two copies
    /// stamped in the same second: every device picks the same one.
    var canonical: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Whether `self` should replace `held`: the newer wins; a tombstone beats
    /// a live copy of the same second; then the text order, so all devices agree.
    func supersedes(_ held: HouseholdMember) -> Bool {
        if modified != held.modified { return modified > held.modified }
        if removed != held.removed { return removed }
        return !sameContent(as: held) && canonical > held.canonical
    }

    /// The account this member makes on a device that doesn't have it: no
    /// token, a device id of its own.
    func newAccount() -> Account {
        Account(
            id: userId, name: name, server: server, language: language, displayName: displayName.isEmpty ? nil : displayName,
            role: role, avatar: avatar
        )
    }

    /// `account` with this member's name, look, role and language (its device id stays).
    func applied(to account: Account) -> Account {
        var out = account
        out.name = name
        out.displayName = displayName.isEmpty ? nil : displayName
        out.role = role
        out.avatar = avatar
        out.language = language
        return out
    }
}

/// A new device asking the others to approve its Quick Connect code.
public struct ApprovalRequest: Sendable, Equatable {
    public enum Database: Sendable, Equatable { case `private`, shared }

    /// The record's name ("r" and a random id): one request, one approval.
    public var id: String
    public var server: URL
    public var userId: String
    public var code: String
    /// What the requesting device is ("iPad"), for the notice the approver shows.
    public var device: String
    public var created: Date
    /// Where it was found. Only the owner's own (private) database counts.
    public var database: Database

    public init(
        id: String = "r" + UUID().uuidString, server: URL, userId: String, code: String, device: String, created: Date,
        database: Database = .private
    ) {
        self.id = id
        self.server = server
        self.userId = userId
        self.code = code
        self.device = device
        self.created = created
        self.database = database
    }
}

/// Whether this device approves a request. Approving signs the requesting
/// device in as that profile for good, so every condition is a reason to say no.
public enum ApprovalPolicy {
    public static let maxAge: TimeInterval = 5 * 60
    public static let futureSlack: TimeInterval = 60

    public enum Verdict: Equatable, Sendable {
        /// Approve it as the holder's profile, then delete the request.
        case approve
        /// Not for this device, or not allowed: leave it for the others.
        case skip
        /// Stale, from the future or malformed: delete it.
        case discard
    }

    /// What this device holds for the request's profile.
    public struct Holder: Sendable {
        public var account: Account
        public var hasToken: Bool
        /// The profile is a live member of the household (not a tombstone).
        public var inHousehold: Bool
        public init(account: Account, hasToken: Bool, inHousehold: Bool) {
            self.account = account
            self.hasToken = hasToken
            self.inHousehold = inHousehold
        }
    }

    public static func decide(_ request: ApprovalRequest, now: Date, holder: Holder?, alreadyHandled: Bool) -> Verdict {
        guard Profiles.isQuickConnectCode(request.code) else { return .discard }
        // Age first: a stale request is deleted wherever it came from.
        let age = now.timeIntervalSince(request.created)
        guard age < maxAge, age > -futureSlack else { return .discard }
        // A shared zone's participant must never get the owner signed in.
        guard request.database == .private else { return .skip }
        guard !alreadyHandled else { return .skip }
        guard let holder, holder.hasToken, holder.inHousehold,
              holder.account.id == request.userId,
              HouseholdRecordName.normalized(holder.account.server) == HouseholdRecordName.normalized(request.server) else { return .skip }
        // A kid's session is never handed out without a grown-up's PIN: kids
        // sign in with the blank password instead.
        guard !holder.account.isKid else { return .skip }
        return .approve
    }
}
