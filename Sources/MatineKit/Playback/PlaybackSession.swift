import Foundation

/// Tells the server where playback is, so resume points and watched state
/// match the web app. The player calls `update` as often as it likes (every
/// second is fine); this sends a progress report only every `interval`, or at
/// once when pause state changes.
///
/// Reports go out strictly one after another, in the order they were made: a
/// late progress report can never land after Stopped and drag the resume
/// point back. Failed reports are dropped (the next carries a newer position;
/// Stopped is the one that sets the resume point).
public actor PlaybackSession {
    public static let interval: TimeInterval = 10

    let reporter: any PlaybackReporting
    let plan: PlaybackPlan
    let now: @Sendable () -> Date

    private var started = false
    private var stopped = false
    private var lastSent: Date?
    private var lastPaused: Bool?
    /// The last report queued; each new one waits for it.
    private var tail: Task<Void, Never>?

    public init(reporter: any PlaybackReporting, plan: PlaybackPlan, now: @escaping @Sendable () -> Date = { Date() }) {
        self.reporter = reporter
        self.plan = plan
        self.now = now
    }

    public init(client: JellyfinClient, plan: PlaybackPlan, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(reporter: client, plan: plan, now: now)
    }

    public func update(positionTicks: Int64, isPaused: Bool) {
        guard !stopped else { return }
        let report = PlaybackReport(plan: plan, positionTicks: positionTicks, isPaused: isPaused)
        if !started {
            started = true
            lastSent = now()
            lastPaused = isPaused
            enqueue { try await $0.reportStart(report) }
            return
        }
        let due = lastSent.map { now().timeIntervalSince($0) >= Self.interval } ?? true
        guard due || isPaused != lastPaused else { return }
        lastSent = now()
        lastPaused = isPaused
        enqueue { try await $0.reportProgress(report) }
    }

    /// Once, when the player closes; returns when Stopped has been sent (or
    /// failed). Updates after this, or still on their way, are ignored, so a
    /// late update can't start a session the server would show as playing.
    /// Before anything started, a direct file needs no word; a server stream
    /// still gets Stopped, which ends its transcode (by play session) instead
    /// of leaving ffmpeg running until the server times it out.
    public func stop(positionTicks: Int64) async {
        guard !stopped else { return }
        stopped = true
        guard started || plan.method == .transcode else { return }
        let report = PlaybackReport(plan: plan, positionTicks: positionTicks, isPaused: true)
        enqueue { try await $0.reportStopped(report) }
        await tail?.value
    }

    /// Waits for every queued report (tests).
    func flush() async { await tail?.value }

    private func enqueue(_ send: @escaping @Sendable (any PlaybackReporting) async throws -> Void) {
        let previous = tail
        let reporter = reporter
        tail = Task {
            await previous?.value
            try? await send(reporter)
        }
    }
}
