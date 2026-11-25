import MatineKit
import SwiftUI

/// A film, a video or an episode; for a series, its seasons and episodes.
struct DetailView: View {
    @Environment(\.locale) private var locale
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.play) private var play
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: Item
    let source: any LibrarySource
    let account: Account

    @State private var fresh: Item?
    /// What Play on a series starts.
    @State private var episode: Item?
    @State private var seasons: [Item] = []
    @State private var seasonId: String?
    @State private var episodes: [String: [Item]] = [:]
    /// Seasons whose episodes are being fetched now (see `loadEpisodes`).
    @State private var loadingEpisodes: Set<String> = []
    @State private var pinFailed = false
    @State private var tvChooser = TVChooser()
    /// The TV a video was sent to from this page, for the "En la tele" bar.
    @State private var onTV: TVTarget?
    /// Consecutive refreshes that found the TV not playing.
    @State private var idleChecks = 0
    @State private var tvPaused = false
    @State private var tvNote: String?
    /// When the video was sent: the TV takes a few seconds to report it playing.
    @State private var sentAt = Date.distantPast
    @Environment(\.scenePhase) private var scenePhase

    private var shown: Item { fresh ?? item }
    private var isSeries: Bool { item.kind == .series }
    /// What the Play buttons start: the series' next episode, else the item itself.
    private var target: Item? { isSeries ? episode : shown }
    private var canPin: Bool { shown.isPinnable && !model.current(account).isKid && !model.isOffline && source is HybridLibrarySource }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 16) {
                    titleBlock
                    actions
                    if let onTV { tvBar(onTV) }
                    if let overview = shown.overview, !overview.isEmpty {
                        Text(verbatim: overview).font(.body).fixedSize(horizontal: false, vertical: true)
                    }
                    if isSeries, !seasons.isEmpty { seasonSection }
                }
                .padding(.horizontal)
                .frame(maxWidth: 720, alignment: .leading)
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: model.playbackEndedCount) { await load() }
        // While the bar shows and the app is in front, ask the TV every 15 seconds.
        .task(id: scenePhase == .active ? onTV?.id : nil) {
            guard onTV != nil else { return }
            await refreshTVBar()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                await refreshTVBar()
            }
        }
        .tvChooser(tvChooser)
        .alert("No se ha podido cambiar Fijados.", isPresented: $pinFailed) { Button("Vale", role: .cancel) {} }
    }

    // MARK: Pieces

    private var header: some View {
        ArtView(item: shown, ref: shown.backdropImage ?? shown.wideImage ?? shown.posterImage, source: source,
                aspect: sizeClass == .regular ? 21 / 9 : 16 / 10, maxHeight: 900)
            .overlay { LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom) }
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: shown.kind == .episode ? (shown.seriesName ?? shown.displayName) : shown.displayName)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            if shown.kind == .episode { Text(verbatim: shown.episodeTitle(AppLanguage(locale: locale))).font(.headline) }
            factsLine.font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var factsLine: Text {
        let real = isSeries ? seasons.filter { ($0.seasonIndex ?? 1) >= 1 }.count : 0
        guard real > 0 else { return Text(verbatim: shown.facts) }
        let seasonsText = Text("\(real) temporadas")
        return shown.facts.isEmpty ? seasonsText : Text("\(shown.facts) · \(seasonsText)")
    }

    /// Play is the wide button; restart, TV and pin are round icons of one
    /// size beside it. At accessibility text sizes the row wraps as a whole
    /// (icons under Play) instead of squeezing a label.
    @ViewBuilder private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            if let target {
                let resume = target.resumeTicks > 0
                Button { play(target, from: resume ? target.resumeTicks : 0) } label: {
                    Label(playLabel(target, resume: resume), systemImage: "play.fill")
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 12) {
                if let target, target.resumeTicks > 0 {
                    Button { play(target, from: 0) } label: { roundIcon("arrow.counterclockwise") }
                        .roundIconStyle()
                        .accessibilityLabel(Text("Desde el principio"))
                }
                if target != nil, client != nil { tvButton }
                if !isSeries, let target { DownloadButton(item: target, account: account) }
                if canPin { pinButton }
            }
        }
        .controlSize(.large)
    }

    private func roundIcon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 28, height: 28)
    }

    private func playLabel(_ target: Item, resume: Bool) -> LocalizedStringKey {
        if isSeries, let label = target.episodeLabel(AppLanguage(locale: locale)) { return resume ? "Continuar \(label)" : "Reproducir \(label)" }
        return resume ? "Continuar" : "Reproducir"
    }

    // MARK: Play on a TV

    private var client: JellyfinClient? { (source as? HybridLibrarySource).flatMap { model.isOffline ? nil : $0.server.client } }

    /// The choosing is `TVChooser`'s (shared with the player).
    private var tvButton: some View {
        Button { Task { await tapTV() } } label: { roundIcon("tv") }
            .roundIconStyle()
            .accessibilityLabel(Text("Reproducir en la tele"))
            .accessibilityIdentifier("detail.playOnTV")
    }

    private func tvBar(_ tv: TVTarget) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tv").foregroundStyle(Color.accentColor)
            Text(verbatim: tvNote ?? "").font(.subheadline.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 0)
            Button { Task { await tvState(tv, tvPaused ? .unpause : .pause) } } label: {
                Image(systemName: tvPaused ? "play.fill" : "pause.fill").frame(minWidth: 24)
            }
            .accessibilityLabel(tvPaused ? Text("Reanudar en la tele") : Text("Pausar en la tele"))
            Button { Task { if await tvState(tv, .stop) { onTV = nil } } } label: {
                Image(systemName: "stop.fill").frame(minWidth: 24)
            }
            .accessibilityLabel(Text("Detener en la tele"))
            Button { onTV = nil } label: { Image(systemName: "xmark").frame(minWidth: 24) }
                .accessibilityLabel(Text("Ocultar"))
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detail.tvBar")
    }

    private func currentTVs() async -> [TVTarget]? {
        guard let client else { return nil }
        return await tvChooser.tvs(client: client, userId: account.id, model: model)
    }

    private func tapTV() async {
        guard let client else { return }
        await tvChooser.tap(client: client, userId: account.id, model: model) { await sendToTV($0) }
    }

    private func sendToTV(_ tv: TVTarget) async {
        guard let client, let target else { return }
        do {
            try await client.sendPlay(sessionId: tv.id, itemId: target.id, startTicks: target.resumeTicks)
            tvPaused = false
            tvNote = String(localized: "Reproduciendo en \(tv.name)")
            sentAt = Date()
            idleChecks = 0
            onTV = tv
        } catch {
            if model.sessionExpired(error, userId: account.id) { return }
            // Refresh once: a TV that closed Matiné is no longer there.
            if let found = await currentTVs(), !found.contains(where: { $0.id == tv.id }) { tvChooser.noTV = true } else { tvChooser.failed = true }
        }
    }

    /// True when the TV took the command.
    private func tvState(_ tv: TVTarget, _ state: RemotePlaystate) async -> Bool {
        guard let client else { return false }
        do {
            try await client.sendPlaystate(sessionId: tv.id, state)
            if state == .pause { tvPaused = true } else if state == .unpause { tvPaused = false }
            return true
        } catch {
            // A revoked token goes to sign-in, not to "couldn't reach the TV".
            if !model.sessionExpired(error, userId: account.id) { tvChooser.failed = true }
            return false
        }
    }

    /// Drops the "En la tele" bar once the TV is no longer playing (it
    /// stopped, closed Matiné or went away). The first ten seconds are
    /// grace: the TV takes a moment to report what it plays.
    /// Two "not playing" answers in a row, so a slow start (a transcode
    /// warming up) doesn't hide the bar while the TV is still loading.
    private func refreshTVBar() async {
        guard let tv = onTV, Date().timeIntervalSince(sentAt) > 10, let found = await currentTVs() else { return }
        if found.first(where: { $0.id == tv.id })?.isPlaying ?? false {
            idleChecks = 0
        } else {
            idleChecks += 1
            if idleChecks >= 2 { onTV = nil; idleChecks = 0 }
        }
    }

    private var pinButton: some View {
        let pinned = shown.userData?.isFavorite == true
        return Button { Task { await togglePin(!pinned) } } label: {
            roundIcon(pinned ? "pin.fill" : "pin")
        }
        .roundIconStyle()
        .accessibilityLabel(pinned ? Text("Quitar de Fijados") : Text("Fijar"))
    }

    // MARK: Seasons and episodes

    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                Menu {
                    Picker("Temporada", selection: Binding(get: { seasonId }, set: { seasonId = $0 })) {
                        ForEach(seasons) { season in Text(verbatim: season.name).tag(Optional(season.id)) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(verbatim: seasons.first { $0.id == seasonId }?.name ?? "").font(.title3.bold())
                        Image(systemName: "chevron.up.chevron.down").font(.footnote)
                    }
                }
                .accessibilityLabel(Text("Temporada"))
                .accessibilityValue(Text(verbatim: seasons.first { $0.id == seasonId }?.name ?? ""))
            } else {
                Text(verbatim: seasons.first?.name ?? "").font(.title3.bold())
            }
            if let seasonId, let list = episodes[seasonId] {
                let suffix = Item.sharedSuffix(list.map(\.displayName))
                SeasonDownloadButton(seriesId: item.id, seasonId: seasonId, episodes: list, account: account)
                LazyVStack(spacing: 14) {
                    ForEach(list) { episode in
                        HStack(alignment: .top, spacing: 8) {
                            // The row opens the episode's own page (Play, Desde el principio, tele, Descargar).
                            NavigationLink(value: episode) { EpisodeRow(episode: episode, source: source, suffix: suffix) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("detail.episode.\(episode.id)")
                            DownloadButton(item: episode, account: account, round: false)
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
        }
        .task(id: seasonId) { await loadEpisodes() }
    }

    // MARK: Loading

    private func load() async {
        async let fetched = try? source.item(item.id)
        if isSeries {
            async let next = try? source.episodeToPlay(seriesId: item.id)
            async let list = try? source.seasons(seriesId: item.id)
            let (newSeasons, newNext) = await (list, next)
            if let newSeasons {
                seasons = newSeasons
                episode = newNext ?? nil
                if seasonId == nil || !newSeasons.contains(where: { $0.id == seasonId }) {
                    seasonId = Item.defaultSeason(newSeasons, next: newNext ?? nil)?.id
                }
                // Back from the player: this season's progress is stale.
                episodes = [:]
                await loadEpisodes()
            }
        }
        if let newer = await fetched { fresh = newer }
    }

    private func loadEpisodes() async {
        // Two callers ask for the first season (`load` and the season's own task): one fetch.
        guard isSeries, let seasonId, episodes[seasonId] == nil, !loadingEpisodes.contains(seasonId) else { return }
        loadingEpisodes.insert(seasonId)
        defer { loadingEpisodes.remove(seasonId) }
        do {
            episodes[seasonId] = try await source.episodes(seriesId: item.id, seasonId: seasonId)
        } catch {
            _ = model.sessionExpired(error, userId: account.id)
        }
    }

    private func togglePin(_ wanted: Bool) async {
        do {
            try await source.setPinned(wanted, itemId: shown.id)
            var changed = shown
            var data = changed.userData ?? UserData()
            data.isFavorite = wanted
            changed.userData = data
            fresh = changed
        } catch {
            if !model.sessionExpired(error, userId: account.id) { pinFailed = true }
        }
    }
}

/// One episode: its still, number and name, synopsis, and progress.
private struct EpisodeRow: View {
    let episode: Item
    let source: any LibrarySource
    let suffix: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ArtView(item: episode, ref: episode.ownPrimaryImage ?? episode.posterImage, source: source, aspect: 16 / 9, maxHeight: 240)
                .frame(width: 136)
                .overlay(alignment: .bottom) { if let percent = episode.progressPercent { WatchedBar(percent: percent) } }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    if episode.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.footnote)
                    }
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(verbatim: overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(episode.userData?.played == true ? Text("visto") : episode.progressPercent != nil ? Text("empezado") : Text(verbatim: ""))
    }

    private var title: String {
        let name = episode.displayName(dropping: suffix)
        guard let number = episode.episodeNumber else { return name }
        return "\(number). \(name)"
    }
}

private extension View {
    /// The round bordered button the icon actions share.
    func roundIconStyle() -> some View { buttonStyle(.bordered).buttonBorderShape(.circle) }
}
