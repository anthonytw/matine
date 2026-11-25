import Foundation

/// The optional 4-digit PIN in front of a profile tile.
///
/// It keeps a child out of a parent's profile on this Apple TV; it is not the
/// account's security, which is the Jellyfin password. With 10,000 possible
/// PINs a hash would add nothing, so the PIN sits in the Keychain as-is and
/// the real guard is the attempt limit, kept in the Keychain too so that
/// relaunching the app doesn't reset it.
public struct PinGate: Sendable {
    public enum Outcome: Equatable, Sendable {
        case open
        case wrong(attemptsLeft: Int)
        case locked(until: Date)
    }

    public enum PinError: Error, Equatable { case notFourDigits }

    /// Failures allowed before a lockout.
    public static let attemptsPerRound = 5
    /// First lockout; each further one doubles, up to `maxLockout`.
    public static let firstLockout: TimeInterval = 30
    public static let maxLockout: TimeInterval = 15 * 60

    let secrets: any SecretStore
    let now: @Sendable () -> Date
    let uptime: @Sendable () -> TimeInterval

    /// - Parameter uptime: a clock that only moves forward and that Settings
    ///   cannot change (seconds since boot, asleep or not). A lockout is also
    ///   timed on it, so setting the date forward or back does not skip one.
    public init(
        secrets: any SecretStore,
        now: @escaping @Sendable () -> Date = { Date() },
        uptime: @escaping @Sendable () -> TimeInterval = PinGate.systemUptime
    ) {
        self.secrets = secrets
        self.now = now
        self.uptime = uptime
    }

    /// `CLOCK_MONOTONIC`: counts sleep, unaffected by the date setting.
    public static let systemUptime: @Sendable () -> TimeInterval = {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    struct Attempts: Codable, Equatable {
        var failures = 0
        var lockouts = 0
        var lockedUntil: Date?
        /// How long that lockout is, and the monotonic time it began (see `lockRemaining`).
        var lockLength: TimeInterval?
        var lockedAtUptime: TimeInterval?
    }

    static func pinKey(_ accountId: String) -> String { "pin.\(accountId)" }
    static func attemptsKey(_ accountId: String) -> String { "pin-attempts.\(accountId)" }

    public static func isValid(_ pin: String) -> Bool {
        pin.count == 4 && pin.allSatisfy { $0.isASCII && $0.isNumber }
    }

    public func hasPin(_ accountId: String) throws -> Bool {
        try secrets.read(Self.pinKey(accountId)) != nil
    }

    /// The PIN itself, for the household record (it travels encrypted, to the
    /// owner's own devices only). Nil when there is none.
    public func storedPin(for accountId: String) throws -> String? {
        try secrets.readString(Self.pinKey(accountId))
    }

    public func setPin(_ pin: String, for accountId: String) throws {
        guard Self.isValid(pin) else { throw PinError.notFourDigits }
        try secrets.writeString(pin, for: Self.pinKey(accountId))
        try secrets.delete(Self.attemptsKey(accountId))
    }

    public func removePin(for accountId: String) throws {
        try secrets.delete(Self.pinKey(accountId))
        try secrets.delete(Self.attemptsKey(accountId))
    }

    /// A profile with no PIN is always open.
    public func check(_ entered: String, for accountId: String) throws -> Outcome {
        guard let stored = try secrets.read(Self.pinKey(accountId)) else { return .open }
        var attempts = try loadAttempts(key: Self.attemptsKey(accountId))
        if let until = try activeLock(&attempts, key: Self.attemptsKey(accountId)) { return .locked(until: until) }

        if Self.constantTimeEqual(Data(entered.utf8), stored) {
            try secrets.delete(Self.attemptsKey(accountId))
            return .open
        }
        return try recordFailure(&attempts, key: Self.attemptsKey(accountId))
    }

    /// One more failure on the record at `key`: a lockout every fifth,
    /// doubling each time up to `maxLockout`.
    private func recordFailure(_ attempts: inout Attempts, key: String) throws -> Outcome {
        attempts.failures += 1
        if attempts.failures >= Self.attemptsPerRound {
            let lockout = min(Self.firstLockout * pow(2, Double(attempts.lockouts)), Self.maxLockout)
            let until = now().addingTimeInterval(lockout)
            attempts.lockouts += 1
            attempts.failures = 0
            attempts.lockedUntil = until
            attempts.lockLength = lockout
            attempts.lockedAtUptime = uptime()
            try saveAttempts(attempts, key: key)
            return .locked(until: until)
        }
        attempts.lockedUntil = nil
        attempts.lockLength = nil
        attempts.lockedAtUptime = nil
        try saveAttempts(attempts, key: key)
        return .wrong(attemptsLeft: Self.attemptsPerRound - attempts.failures)
    }

    /// When a lockout in force ends; nil if none is.
    ///
    /// The wall clock can be set by hand, so it is not the judge while the
    /// device has not restarted: the lockout is timed on the monotonic clock
    /// the attempt record was stamped with. Without that (after a restart, or
    /// a record from an older build) the wall clock decides, and a lock
    /// further out than the lockout's own length means the date was set back:
    /// it starts again from now, for its length, rather than ending at once
    /// (a guess-and-reset loop) or lasting until the old date comes round.
    func activeLock(_ attempts: inout Attempts, key: String) throws -> Date? {
        guard let until = attempts.lockedUntil else { return nil }
        let wall = now()
        let up = uptime()
        if let began = attempts.lockedAtUptime, let length = attempts.lockLength, up >= began {
            let left = length - (up - began)
            return left > 0 ? wall.addingTimeInterval(left) : nil
        }
        guard until > wall else { return nil }
        let length = min(attempts.lockLength ?? Self.maxLockout, Self.maxLockout)
        // From here the monotonic clock times it: stamped again for what is left, or for a
        // whole length when the date was set back.
        let again = until > wall.addingTimeInterval(length) ? wall.addingTimeInterval(length) : until
        attempts.lockedUntil = again
        attempts.lockLength = again.timeIntervalSince(wall)
        attempts.lockedAtUptime = up
        try saveAttempts(attempts, key: key)
        return again
    }

    /// The attempt record for "a grown-up's PIN" (`checkAny`): its own, so a
    /// kid guessing there locks only that pad, never each adult's tile.
    static let grownUpAttemptsKey = "pin-attempts.grown-up"

    /// One PIN against several profiles' ("a grown-up's PIN": any adult's).
    /// It opens when it is any of their PINs. Failures count on a record of
    /// their own, with the same limit and lockouts as one profile's. Nil when
    /// none of them has a PIN: nothing opens.
    public func checkAny(_ entered: String, for accountIds: [String]) throws -> Outcome? {
        let pins = try accountIds.compactMap { try secrets.read(Self.pinKey($0)) }
        guard !pins.isEmpty else { return nil }
        var attempts = try loadAttempts(key: Self.grownUpAttemptsKey)
        if let until = try activeLock(&attempts, key: Self.grownUpAttemptsKey) { return .locked(until: until) }
        // Every PIN compared, match or not: no early exit to time.
        let matched = pins.map { Self.constantTimeEqual(Data(entered.utf8), $0) }.contains(true)
        if matched {
            try secrets.delete(Self.grownUpAttemptsKey)
            return .open
        }
        return try recordFailure(&attempts, key: Self.grownUpAttemptsKey)
    }

    func loadAttempts(key: String) throws -> Attempts {
        guard let data = try secrets.read(key) else { return Attempts() }
        return (try? JSONDecoder().decode(Attempts.self, from: data)) ?? Attempts()
    }

    func saveAttempts(_ attempts: Attempts, key: String) throws {
        try secrets.write(try JSONEncoder().encode(attempts), for: key)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
