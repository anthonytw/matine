import Foundation

/// A phone or tablet in "Entrar con un código" telling the Apple TV, over
/// Bonjour on the local network, which code it is showing. The person at the
/// TV compares the two codes and approves from there: no typing with the
/// remote.
///
/// What goes on the air is the 6-digit code and the kind of device, nothing
/// else: the request's secret never leaves `QuickConnectSession`, and no free
/// text crosses the network, so nothing a stranger writes can be displayed
/// (no name to impersonate, no digits but the code itself).
///
/// Threat note. The code is public on the LAN while announced, so anyone on
/// the network can see it, and can announce a code of their own (one they
/// started on the server) hoping someone at the TV approves it, which would
/// sign THEM in as the approving profile. Defences, all of which must stay:
/// the TV only ever offers a choice (a prominent "approve only if you hold
/// that device and it shows this code" warning, default focus on "Ahora no",
/// no input for a moment, a confirm step before any approval without a PIN);
/// it never offers over a PIN pad, the picker or the player; announcements
/// are rate-limited, several at once are listed and flagged, and repeated
/// declines pause offers for a while (see `NearbyRoster`); the TV can switch
/// the feature off; and after a Quick Connect sign-in the phone says who it
/// signed in as and lets its owner sign out at once ("No soy yo").
public struct NearbyJoin: Sendable, Equatable, Hashable, Identifiable {
    public static let serviceType = "_matine-join._tcp"
    /// The TXT record's format, so a later change can be told from this one.
    static let version = "1"
    /// At most this many announcements are read from one browse result.
    public static let resultCap = 20

    /// The kinds of device the TV names in plain, fixed words.
    public enum Kind: String, Sendable, Equatable {
        case iPhone = "iphone", iPad = "ipad", other

        /// From `UIDevice.current.model` ("iPhone", "iPad", "iPod touch"…).
        public init(model: String) {
            switch model {
            case "iPhone": self = .iPhone
            case "iPad": self = .iPad
            default: self = .other
            }
        }
    }

    public let kind: Kind
    /// Six digits, as the server shows them.
    public let code: String

    public var id: String { code }

    /// Nil unless `code` is six digits (anything else on the network is ignored).
    public init?(kind: Kind, code: String) {
        guard Profiles.isQuickConnectCode(code) else { return nil }
        self.kind = kind
        self.code = code
    }

    /// The TXT record to advertise.
    public var txt: [String: String] { ["v": Self.version, "kind": kind.rawValue, "code": code] }

    /// Reads a TXT record heard on the network, which anyone on it may have
    /// written: a wrong version or a missing or malformed code is nil, and a
    /// kind that is not one of ours is just `.other`.
    public init?(txt: [String: String]) {
        guard txt["v"] == Self.version, let code = txt["code"] else { return nil }
        self.init(kind: txt["kind"].flatMap(Kind.init(rawValue:)) ?? .other, code: code)
    }

    /// "482 913": the code as the person compares it.
    public var spacedCode: String { "\(code.prefix(3)) \(code.suffix(3))" }
}

/// What the sheet may ask about.
public struct NearbyOffer: Sendable, Equatable {
    /// Everything live and not yet answered, oldest first.
    public let joins: [NearbyJoin]
    /// More than one device, or one right after another answer: the sheet
    /// says so and lists them, and never quietly takes the first.
    public let isCrowded: Bool
}

/// How an offer ended.
public enum NearbyOutcome: Sendable, Equatable {
    case declined, approved
}

/// What the TV has heard, kept to what a person should be asked about:
/// announcements still on the air, not already answered, no faster than
/// anyone could honestly produce them, and not at all for a while after
/// repeated declines (someone is pestering, or it is not wanted). Anyone on
/// the network can announce anything, so nothing here approves anything by
/// itself: it only decides what the sheet offers. Pure, so tests drive it
/// with a clock.
public struct NearbyRoster: Sendable {
    /// New codes accepted within `window`; the rest are ignored.
    public let maxArrivals: Int
    public let window: TimeInterval
    /// How many may be live at once.
    public let maxShown: Int
    /// This many declines within `declineWindow` pause offers for `pause`.
    public let declineLimit: Int
    public let declineWindow: TimeInterval
    public let pause: TimeInterval
    /// An announcement this soon after an answer is flagged like a crowd.
    public let recentSpan: TimeInterval

    private var shown: [NearbyJoin] = []
    private var finished: [String] = []
    private var arrivals: [Date] = []
    private var declines: [Date] = []
    private var pausedUntil: Date?
    private var lastAnswer: Date?

    public init(
        maxArrivals: Int = 5, window: TimeInterval = 60, maxShown: Int = 5,
        declineLimit: Int = 3, declineWindow: TimeInterval = 10 * 60, pause: TimeInterval = 30 * 60,
        recentSpan: TimeInterval = 30
    ) {
        self.maxArrivals = maxArrivals
        self.window = window
        self.maxShown = maxShown
        self.declineLimit = declineLimit
        self.declineWindow = declineWindow
        self.pause = pause
        self.recentSpan = recentSpan
    }

    /// Everything live: the sheet checks that what it shows is still on the air.
    public var live: [NearbyJoin] { shown }

    public func isPaused(now: Date = Date()) -> Bool {
        guard let pausedUntil else { return false }
        return now < pausedUntil
    }

    /// What to ask about now; nil when nothing is live or offers are paused.
    public func offer(now: Date = Date()) -> NearbyOffer? {
        guard !shown.isEmpty, !isPaused(now: now) else { return nil }
        let recent = lastAnswer.map { now >= $0 && now.timeIntervalSince($0) < recentSpan } ?? false
        return NearbyOffer(joins: shown, isCrowded: shown.count > 1 || recent)
    }

    /// What is on the air now: new ones join (if the rate allows), vanished
    /// ones leave. Answered codes never come back.
    public mutating func update(seen: [NearbyJoin], now: Date = Date()) {
        let onAir = Set(seen.map(\.code))
        shown.removeAll { !onAir.contains($0.code) }
        let window = window
        arrivals.removeAll { now.timeIntervalSince($0) >= window || now < $0 }
        for join in seen.prefix(NearbyJoin.resultCap)
        where !shown.contains(where: { $0.code == join.code }) && !finished.contains(join.code) {
            guard shown.count < maxShown, arrivals.count < maxArrivals else { continue }
            shown.append(join)
            arrivals.append(now)
        }
    }

    /// "Ahora no" to everything on offer at once (Menu on the list, or a Play
    /// from the phone): none is offered again, and it counts as one decline.
    public mutating func declineAll(now: Date = Date()) {
        guard let first = shown.first else { return }
        for join in shown.dropFirst() {
            finished.append(join.code)
        }
        shown.removeAll(where: { _ in true })
        finish(first, .declined, now: now)
    }

    /// "Ahora no", or approved: this code is not offered again. Enough
    /// declines in a short time pause every offer.
    public mutating func finish(_ join: NearbyJoin, _ outcome: NearbyOutcome, now: Date = Date()) {
        shown.removeAll { $0.code == join.code }
        finished.append(join.code)
        if finished.count > 100 { finished.removeFirst(finished.count - 100) }
        lastAnswer = now
        guard outcome == .declined else { return }
        declines.append(now)
        let declineWindow = declineWindow
        declines.removeAll { now.timeIntervalSince($0) >= declineWindow }
        if declines.count >= declineLimit {
            pausedUntil = now.addingTimeInterval(pause)
            declines = []
        }
    }
}

/// What choosing a profile on the sheet leads to.
public enum NearbyStep: Sendable, Equatable {
    /// A second, deliberate press: "Aprobar 482 913 como X" / "Cancelar".
    case confirm
    /// The profile's own PIN, then approve.
    case ownPin
    /// Any grown-up's PIN, then approve.
    case grownUpPin
}

public struct NearbyChoice: Sendable, Equatable {
    public let account: Account
    public let step: NearbyStep
}

extension HouseRules {
    /// The profiles that may approve a nearby device, the open one first, each
    /// with what it must pass: no profile approves with a single press.
    public func nearbyChoices(openId: String?) -> [NearbyChoice] {
        let ordered = accounts.filter { $0.id == openId } + accounts.filter { $0.id != openId }
        return ordered.compactMap { account in
            switch approveGate(for: account) {
            case .open: NearbyChoice(account: account, step: .confirm)
            case .ownPin: NearbyChoice(account: account, step: .ownPin)
            case .grownUpPin: NearbyChoice(account: account, step: .grownUpPin)
            case .notAllowed: nil
            }
        }
    }
}
