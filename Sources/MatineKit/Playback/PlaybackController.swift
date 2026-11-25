#if canImport(AVFoundation)
import AVFoundation
#if os(tvOS)
import AVKit
#endif
import Foundation
import Observation

/// One playback, from asking the source to the last report: shared by the
/// Apple TV and the phone/tablet app, so a fix to how a stream starts, retries
/// or closes lands in both. `close()` may come at any moment, even while
/// `start()` is still waiting; whatever `start()` builds after that is torn
/// down instead of played.
@MainActor @Observable
public final class Playback {
    public private(set) var player: AVPlayer?
    public private(set) var failed = false
    /// The video played to its end.
    public private(set) var ended = false

    private var closed = false
    private var began = false
    private var session: PlaybackSession?
    private var observer: Any?
    private var reporter: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var endObserver: (any NSObjectProtocol)?
    /// Feeds the reporter: a remote pause or seek tells the server at once.
    private var feed: AsyncStream<(Int64, Bool)>.Continuation?
    /// Where playback was asked to start: what a close before it began reports.
    private var startTicks: Int64 = 0

    /// How long a stream may take to become playable (a cold server remux
    /// included) before the player gives up and says so.
    public static let defaultReadyTimeout: Duration = .seconds(30)
    private let readyTimeout: Duration

    /// Wraps the final Stopped report. The phone app sets this to hold a
    /// background task, so a profile that relocks as the app goes to the
    /// background still tells the server. Runs the work and returns when done.
    public var keepAlive: @MainActor (_ work: @escaping @MainActor () async -> Void) async -> Void = { await $0() }

    public init(readyTimeout: Duration = Playback.defaultReadyTimeout) {
        self.readyTimeout = readyTimeout
    }

    /// `constrained`: a metered connection, which asks the source for a lighter stream.
    public func start(item: Item, source: any LibrarySource, startTicks: Int64, language: AppLanguage, constrained: Bool = false) async {
        self.startTicks = startTicks
        do {
            #if os(iOS)
            // Films and shows, not ring tones: the silent switch doesn't mute them.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            var plan = try await source.playbackPlan(itemId: item.id, startTicks: startTicks, allowDirectPlay: true, constrained: constrained)
            guard !closed else { return }
            // The session exists from here, so a close at any later point
            // still tells the server (ending a transcode it may have started).
            session = PlaybackSession(reporter: source, plan: plan)
            // On screen (paused) from the start: tvOS loads the stream once the
            // player is attached to a view.
            var candidate = makePlayer(plan, source, item, language)
            player = candidate
            if await !isReady(candidate) {
                guard !closed else { return }
                // Only a file the server thought plays as-is gets a second try
                // (AVPlayer refused it, an HEVC track tagged hev1, say): the
                // server's HLS remux fixes that. A failed server stream is final.
                guard plan.method == .directPlay else { throw PlaybackError.unplayable(nil) }
                plan = try await source.playbackPlan(itemId: item.id, startTicks: startTicks, allowDirectPlay: false, constrained: constrained)
                guard !closed else { return }
                session = PlaybackSession(reporter: source, plan: plan)
                candidate = makePlayer(plan, source, item, language)
                player = candidate
                guard await isReady(candidate) else { throw PlaybackError.unplayable(nil) }
            }
            guard !closed else { return }
            // A direct-play file carries its own tracks: start on the profile's
            // language. The server's HLS already follows the user's server-side
            // preferences, so it is left alone.
            if plan.method == .directPlay { await selectTracks(of: candidate, for: language) }
            guard !closed else { return }
            if startTicks > 0 {
                await candidate.seek(to: CMTime(seconds: Ticks.seconds(startTicks), preferredTimescale: 600))
            }
            guard !closed, let session else { return }
            begin(candidate, session, startTicks: startTicks)
        } catch {
            guard !closed else { return }
            player?.replaceCurrentItem(with: nil)
            player = nil
            failed = true
            // A server stream that never became ready may still be transcoding.
            await session?.stop(positionTicks: startTicks)
        }
    }

    /// Audio in the profile's language (else the other one), and its subtitles
    /// when the audio isn't in it. The system player's menus still change either.
    private func selectTracks(of player: AVPlayer, for language: AppLanguage) async {
        guard let item = player.currentItem else { return }
        let asset = item.asset
        // Either group may be missing (most files have no subtitles): each is
        // handled on its own, so a file without subtitles still gets its audio.
        let audio = (try? await asset.loadMediaSelectionGroup(for: .audible)) ?? nil
        let legible = (try? await asset.loadMediaSelectionGroup(for: .legible)) ?? nil
        let audioOptions = audio?.options ?? []
        // Forced-only and "describes music and sound" tracks are not a viewer's pick.
        let subtitleOptions = (legible?.options ?? []).filter {
            !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) && !$0.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
        }
        let choice = MediaLanguages.choose(
            preferred: language.mediaLanguages,
            // Many MP4 tracks carry only the mdhd language ("spa"), not an elng tag.
            audio: audioOptions.map { $0.extendedLanguageTag ?? $0.locale?.identifier },
            subtitles: subtitleOptions.map { $0.extendedLanguageTag ?? $0.locale?.identifier }
        )
        if let audio, let index = choice.audio { item.select(audioOptions[index], in: audio) }
        // Subtitles are only ever turned ON here; otherwise the file's own
        // default stays, forced subtitles (foreign lines in a Spanish film) included.
        if let legible, let index = choice.subtitle { item.select(subtitleOptions[index], in: legible) }
    }

    private func makePlayer(_ plan: PlaybackPlan, _ source: any LibrarySource, _ item: Item, _ language: AppLanguage) -> AVPlayer {
        // The token goes as a header on every request the player makes
        // (file, playlist, segments), never in the URL.
        let asset = AVURLAsset(url: plan.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.streamHeaders])
        let playerItem = AVPlayerItem(asset: asset)
        #if os(tvOS)
        playerItem.externalMetadata = Self.metadata(for: item, language: language)
        #endif
        let player = AVPlayer(playerItem: playerItem)
        #if os(iOS)
        // AirPlay only for a downloaded file (the phone serves the bytes, no token needed).
        // A server stream would be fetched by the receiver without our token header (a 401,
        // and the token never goes in a URL); the TV handoff covers that case. Mirroring
        // stays a mirror: the app does not take over an external screen.
        player.allowsExternalPlayback = Self.allowsExternalPlayback(for: plan)
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        #endif
        return player
    }

    /// Whether AirPlay may take this stream over: only a local file, which needs no token.
    nonisolated static func allowsExternalPlayback(for plan: PlaybackPlan) -> Bool { plan.url.isFileURL }

    /// What the player's info panel shows: the title, "Serie · T1 · E3" for an
    /// episode, and the synopsis.
    static func metadata(for item: Item, language: AppLanguage) -> [AVMetadataItem] {
        func entry(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let entry = AVMutableMetadataItem()
            entry.identifier = identifier
            entry.value = value as NSString
            entry.extendedLanguageTag = "und"
            return entry
        }
        var entries = [entry(.commonIdentifierTitle, item.kind == .episode ? item.displayName : item.seriesName ?? item.displayName)]
        if item.kind == .episode, let series = item.seriesName {
            entries.append(entry(.iTunesMetadataTrackSubTitle, [series, item.episodeLabel(language)].compactMap { $0 }.joined(separator: " · ")))
        }
        if let overview = item.overview, !overview.isEmpty { entries.append(entry(.commonIdentifierDescription, overview)) }
        return entries
    }

    /// Waits until the item can play (true), has failed, timed out or the
    /// player was closed (false). A short poll: AVPlayerItem.status is
    /// main-thread KVO, and this keeps the wait cancellable by `close()`.
    private func isReady(_ player: AVPlayer) async -> Bool {
        guard let item = player.currentItem else { return false }
        let deadline = ContinuousClock.now + readyTimeout
        while !closed, !Task.isCancelled, ContinuousClock.now < deadline {
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default:
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
            }
        }
        return false
    }

    private func begin(_ player: AVPlayer, _ session: PlaybackSession, startTicks: Int64) {
        // Time updates feed one reporter, so they reach the session in order.
        // A few buffered, so a quick pause-and-resume isn't merged away.
        let (times, feed) = AsyncStream.makeStream(of: (Int64, Bool).self, bufferingPolicy: .bufferingNewest(8))
        // Start goes out now, not at the first tick a second later.
        feed.yield((startTicks, false))
        self.feed = feed
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak player] time in
            feed.yield((Ticks.from(seconds: time.seconds), player?.timeControlStatus == .paused))
        }
        reporter = Task {
            for await (ticks, paused) in times { await session.update(positionTicks: ticks, isPaused: paused) }
        }
        // The time observer is silent while paused; the server still wants to
        // hear (it ends an idle transcode), so a paused player reports too.
        heartbeat = Task { [weak player] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let player, player.timeControlStatus == .paused else { continue }
                feed.yield((Ticks.from(seconds: player.currentTime().seconds), true))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended = true }
        }
        began = true
        player.play()
    }

    /// A phone's pause, unpause or seek (stop is the view's: it closes). Only
    /// once playback has begun, so a command can't start or move a stream
    /// that is still loading.
    public func apply(_ command: RemoteCommand) {
        guard began, !closed, let player else { return }
        var paused = player.timeControlStatus == .paused
        var position = Ticks.from(seconds: player.currentTime().seconds)
        switch command {
        case .pause: player.pause(); paused = true
        case .unpause: player.play(); paused = false
        case .playPause:
            paused.toggle()
            if paused { player.pause() } else { player.play() }
        case .seek(let ticks):
            player.seek(to: CMTime(seconds: Ticks.seconds(ticks), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            position = ticks
        case .play, .stop: return
        }
        feed?.yield((position, paused))
    }

    /// Stops the player and tells the server; returns once Stopped has gone
    /// out, and whether anything actually played.
    public func close() async -> Bool {
        guard !closed else { return false }
        closed = true
        // Before playback began (still loading or seeking) the player's time
        // is 0: reporting that would erase the resume point.
        var position = startTicks
        if let player {
            player.pause()
            if began { position = Ticks.from(seconds: player.currentTime().seconds) }
            if let observer { player.removeTimeObserver(observer) }
            player.replaceCurrentItem(with: nil)
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        heartbeat?.cancel()
        reporter?.cancel()
        feed = nil
        self.player = nil
        #if os(iOS)
        // Let the music app (or anything we interrupted) carry on.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        let session = session
        await keepAlive { await session?.stop(positionTicks: position) }
        return began
    }
}
#endif
