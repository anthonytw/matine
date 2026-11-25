import MatineKit
import SwiftUI

/// Where a tile or button leads, inside a tab's navigation stack.
enum Route: Hashable {
    case item(Item)
    case person(Person)
}

/// What `PlayerView` needs, presented full screen.
struct PlayRequest: Identifiable, Hashable {
    let item: Item
    let startTicks: Int64
    var id: String { "\(item.id)@\(startTicks)" }
}

/// Backdrop, title, description, Play/Resume and the pin toggle. For a series,
/// Play starts its next episode (Jellyfin's Next up, else the first unwatched);
/// a row of the season's episodes (led by a surprise pick) fills the first
/// screen, and below it the same episodes as a list, with their synopses,
/// for seasons too long to browse sideways.
struct DetailView: View {
    @Environment(\.locale) private var locale
    let item: Item
    let client: JellyfinClient
    let account: Account
    @Binding var playing: PlayRequest?
    @Environment(AppModel.self) private var model

    private var userId: String { account.id }

    @State private var full: Item?
    @State private var episode: Item?
    @State private var seasons: [Item] = []
    @State private var seasonId: String?
    /// Episodes by season id: the row shows only the selected season's, so a
    /// switch never leaves the previous season's tiles under the new name.
    @State private var episodesBySeason: [String: [Item]] = [:]
    /// The viewer chose a season; until then it follows the episode Play starts.
    @State private var seasonPicked = false
    @State private var pinned: Bool?
    @State private var pinBusy = false
    @State private var pinFailed = false
    /// The item itself couldn't be fetched (server unreachable): the page says so.
    @State private var loadFailed = false
    /// Seasons whose episodes couldn't be fetched: their row offers Reintentar.
    @State private var episodesFailed: Set<String> = []
    /// Loaded once per visit; Back from a page above doesn't fetch it again
    /// (a playback does, through `playbackEndedCount`).
    @State private var loaded = false
    /// On screen now, and a playback ended while it wasn't: pages in other tabs or
    /// buried in a stack reload when they are next seen, not all at once.
    @State private var visible = false
    @State private var stale = false
    /// Only the newest load writes its result.
    @State private var loadGeneration = 0
    @Namespace private var episodesScope
    /// A series page's backdrops, in turn (its own, then episode stills).
    @State private var seriesArts: [SpotlightBackdrop.Art] = []

    private var shown: Item { full ?? item }
    /// What Play plays: the item itself, or for a series the episode picked for it.
    private var target: Item? { shown.kind == .series ? episode : shown }
    private var isPinned: Bool { pinned ?? shown.userData?.isFavorite ?? false }

    var body: some View {
        GeometryReader { screen in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // The list's heading peeks in below the row: there's more down there.
                    hero.frame(maxWidth: .infinity, minHeight: screen.size.height - (peeks ? 70 : 0), alignment: .bottomLeading)
                    if shown.kind == .series, !currentEpisodes.isEmpty { episodeList }
                    if shown.hasCredits { creditsSection }
                }
            }
            .scrollClipDisabled()
        }
        // A series shows more of itself than one picture: its art, then its
        // episodes' stills in turn.
        .background { CyclingBackdrop(arts: seriesArts.isEmpty ? backdropArt.map { [$0] } ?? [] : seriesArts, client: client) }
        .onChange(of: currentEpisodes.map(\.id), initial: true) { drawSeriesArts() }
        .onChange(of: backdropArt) { drawSeriesArts() }
        .task {
            guard !loaded else { return }
            loaded = true
            await load()
        }
        .onAppear {
            visible = true
            if stale {
                stale = false
                Task { await load() }
            }
        }
        .onDisappear { visible = false }
        // Back from the player (Stopped sent): the resume point has moved.
        .onChange(of: model.playbackEndedCount) {
            if visible { Task { await load() } } else { stale = true }
        }
    }

    /// The next section's heading peeks in below the first screen: there's more down there.
    private var peeks: Bool { shown.kind == .series || shown.hasCredits }

    private var currentEpisodes: [Item] { seasonId.flatMap { episodesBySeason[$0] } ?? [] }

    /// The series' own art first, then a dozen of the season's stills, shuffled.
    private func drawSeriesArts() {
        guard shown.kind == .series else { return }
        let stills = currentEpisodes.compactMap(\.ownPrimaryImage).shuffled().prefix(12).map { SpotlightBackdrop.Art(ref: $0, soft: false) }
        seriesArts = (backdropArt.map { [$0] } ?? []) + stills.filter { $0 != backdropArt }
    }

    /// The first screen: what the page is, its buttons and (for a series)
    /// the season row, at the bottom of the screen.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            HomeHero.Title(item: shown, client: client, size: 72)
            if let tagline = shown.taglines?.first(where: { !$0.isEmpty }) {
                Text(verbatim: tagline).font(.title3.weight(.regular)).italic().foregroundStyle(.white.opacity(0.85)).lineLimit(2).frame(maxWidth: 1050, alignment: .leading)
            }
            ItemFacts(item: shown, showsRatings: true)
            if let overview = shown.overview, !overview.isEmpty {
                Text(overview).font(.callout).lineLimit(shown.kind == .series ? 3 : 5).frame(maxWidth: 1050, alignment: .leading)
            }
            crewLine
            if shown.kind == .series, let episode {
                // What Play starts, in a line of its own.
                Text("Siguiente: \(episodeTitle(episode))").font(.headline).lineLimit(1).frame(maxWidth: 1050, alignment: .leading)
            }
            // First when the page couldn't load: focus lands on the way out
            // of it, not on a Play built from stale data.
            if loadFailed {
                RetryMessage("No se puede conectar con el servidor.") { Task { await load() } }
            }
            actions
            if shown.kind == .series, !seasons.isEmpty { seasonSection }
            if pinFailed { Text("No se ha podido cambiar Fijados.").foregroundStyle(.red) }
        }
        .padding(.horizontal, 80)
        .padding(.top, 80)
        .padding(.bottom, peeks ? 30 : 100)
    }

    /// "Dirección: …  ·  Guion: …", when the server knows them.
    @ViewBuilder private var crewLine: some View {
        let directors = shown.directors.map(\.name).joined(separator: ", ")
        let writers = shown.writers.map(\.name).joined(separator: ", ")
        if !directors.isEmpty || !writers.isEmpty {
            HStack(spacing: 24) {
                if !directors.isEmpty { Text("Dirección: \(directors)") }
                if !writers.isEmpty { Text("Guion: \(writers)") }
            }
            .font(.callout)
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(1)
            .frame(maxWidth: 1050, alignment: .leading)
        }
    }

    /// The cast (an episode's guest stars after it), on black below the rest.
    private var creditsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !shown.cast.isEmpty { CastRow(title: "Reparto", people: shown.cast, client: client) }
            if !shown.guestStars.isEmpty { CastRow(title: "Estrellas invitadas", people: shown.guestStars, client: client) }
        }
        .padding(.horizontal, 80)
        .padding(.top, shown.kind == .series && !currentEpisodes.isEmpty ? 0 : 40)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            VStack(spacing: 0) {
                if !(shown.kind == .series && !currentEpisodes.isEmpty) {
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 200)
                }
                Color.black.opacity(0.85)
            }
            .padding(.top, shown.kind == .series && !currentEpisodes.isEmpty ? 0 : -200)
        }
    }

    /// Every episode of the season again, one per line: a still, then its
    /// name, length and synopsis, so a long season reads at a glance.
    private var episodeList: some View {
        let episodes = currentEpisodes
        return VStack(alignment: .leading, spacing: 28) {
            Text("Todos los episodios").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(episodes) { episode in
                    NavigationLink(value: Route.item(episode)) {
                        EpisodeLine(episode: episode, client: client, title: episodeTitle(episode), isNext: episode.id == self.episode?.id)
                    }
                    .buttonStyle(.card)
                }
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
        .padding(.bottom, 80)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The list scrolls up over the art: on black, it reads. The black
        // fades in above it, so there's no edge across the picture.
        .background {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom).frame(height: 200)
                Color.black.opacity(0.85)
            }
            .padding(.top, -200)
        }
        .focusSection()
    }

    /// The item's backdrop; with none (a channel of downloaded videos, say),
    /// the next episode's still or the item's own art, softened when it's a
    /// portrait poster.
    private var backdropArt: SpotlightBackdrop.Art? {
        if let ref = shown.backdropImage { return .init(ref: ref, soft: false) }
        if let ref = episode?.ownPrimaryImage ?? shown.wideImage { return .init(ref: ref, soft: false) }
        return shown.posterImage.map { .init(ref: $0, soft: true) }
    }

    /// The tail every episode name of this season repeats (a YouTube
    /// channel's "- Canal Ejemplo"), dropped where episodes are listed.
    private var seasonSuffix: String? {
        Item.sharedSuffix((seasonId.flatMap { episodesBySeason[$0] } ?? []).map(\.displayName))
    }

    private func episodeTitle(_ episode: Item) -> String {
        [episode.episodeLabel(AppLanguage(locale: locale)), episode.displayName(dropping: seasonSuffix)].compactMap { $0 }.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 28) {
            if let target {
                if target.resumeTicks > 0 {
                    Button { playing = PlayRequest(item: target, startTicks: target.resumeTicks) } label: {
                        Label("Reanudar", systemImage: "play.fill").padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    Button("Desde el principio") { playing = PlayRequest(item: target, startTicks: 0) }
                } else {
                    Button { playing = PlayRequest(item: target, startTicks: 0) } label: {
                        Label("Reproducir", systemImage: "play.fill").padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                }
            }
            // An episode leads to its series: its other episodes and its pin.
            if shown.kind == .episode, let seriesId = shown.seriesId {
                NavigationLink(value: Route.item(Item(id: seriesId, name: shown.seriesName ?? "", kind: .series))) {
                    Label("Ver serie", systemImage: "square.stack.3d.up.fill")
                }
            }
            // Fijados is the grown-ups' to arrange: a round icon beside Play.
            if shown.isPinnable, !model.current(account).isKid {
                Button { Task { await togglePin() } } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                }
                .buttonBorderShape(.circle)
                .disabled(pinBusy)
                .accessibilityLabel(Text(isPinned ? "Quitar de Fijados" : "Fijar en inicio"))
            }
        }
        .focusSection()
    }

    /// A season picker over one row of that season's episodes.
    private var seasonSection: some View {
        let episodes = currentEpisodes
        // The row opens scrolled to the episode Play would start, when it's in
        // this season, so Down from the buttons lands on it.
        let nextId = episodes.contains { $0.id == episode?.id } ? episode?.id : nil
        return VStack(alignment: .leading, spacing: 20) {
            // One season needs no picker.
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(seasons) { season in
                            let selected = season.id == seasonId
                            Button {
                                seasonId = season.id
                                seasonPicked = true
                            } label: {
                                if selected { Label(season.displayName, systemImage: "checkmark") } else { Text(season.displayName) }
                            }
                            .opacity(selected ? 1 : 0.7)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 80)
                }
                .scrollClipDisabled()
                .focusSection()
            }
            if let seasonId, episodesFailed.contains(seasonId) {
                RetryMessage("No se han podido cargar los episodios.") { Task { await loadEpisodes(force: true) } }
            }
            // The dice stay put at the row's start, however far along the row
            // opens (it opens on the episode Play would start).
            HStack(alignment: .top, spacing: 32) {
            if episodes.count > 1 {
                SurpriseCard {
                    guard let pick = episodes.randomElement() else { return }
                    playing = PlayRequest(item: pick, startTicks: pick.resumeTicks)
                }
                .padding(.vertical, 24)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 32) {
                    ForEach(episodes) { episode in
                        NavigationLink(value: Route.item(episode)) {
                            EpisodeCard(episode: episode, client: client, title: episodeTitle(episode), isNext: episode.id == nextId)
                        }
                        .buttonStyle(.borderless)
                        // Down from the buttons lands on the episode Play would start.
                        .prefersDefaultFocus(episode.id == nextId, in: episodesScope)
                    }
                }
                .scrollTargetLayout()
                // Room for a focused tile's growth and shadow.
                .padding(.vertical, 24)
            }
            // Clipped at its left edge, so tiles slide under it rather than
            // over the dice; the margins leave a focused tile room to grow.
            // The right side runs on to the screen's edge, as the other rows do.
            .contentMargins(.leading, 24, for: .scrollContent)
            .contentMargins(.trailing, 104, for: .scrollContent)
            .padding(.leading, -24)
            .padding(.trailing, -104)
            .scrollPosition(id: .constant(nextId), anchor: .leading)
            .focusSection()
            .focusScope(episodesScope)
            }
            .focusSection()
        }
        .task(id: seasonId) { await loadEpisodes(force: false) }
    }

    /// One season's episodes; a season already fetched is only fetched again
    /// when forced (after a playback, or Reintentar).
    private func loadEpisodes(force: Bool) async {
        guard let seasonId, force || episodesBySeason[seasonId] == nil else { return }
        do {
            episodesBySeason[seasonId] = try await client.seasonEpisodes(seriesId: item.id, seasonId: seasonId, userId: userId)
            episodesFailed.remove(seasonId)
        } catch {
            if !model.sessionExpired(error, userId: userId) { episodesFailed.insert(seasonId) }
        }
    }

    /// The item and (for a series) the episode to play, fetched at once.
    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let isSeries = item.kind == .series
        async let fetchedItem = attempt { try await client.item(item.id, userId: userId) }
        async let fetchedEpisode = attempt { isSeries ? try await client.episodeToPlay(seriesId: item.id, userId: userId) : nil }
        async let fetchedSeasons = attempt { isSeries ? try await client.seasons(seriesId: item.id, userId: userId) : [] }
        let (newItem, newEpisode, newSeasons) = await (fetchedItem, fetchedEpisode, fetchedSeasons)
        guard generation == loadGeneration else { return }
        let errors = [newItem.error, newEpisode.error, newSeasons.error].compactMap { $0 }
        if let error = errors.first, model.sessionExpired(error, userId: userId) { return }
        // A failed call says so; a series with nothing next (nil) is not a failure.
        loadFailed = !errors.isEmpty
        full = (try? newItem.get()) ?? full
        if case .success(let next) = newEpisode { episode = next ?? episode }
        seasons = (try? newSeasons.get()) ?? seasons
        // The season Play would start, unless the viewer picked one that still exists.
        let target = seasonPicked && seasons.contains(where: { $0.id == seasonId }) ? seasonId : Item.defaultSeason(seasons, next: episode)?.id
        if target == seasonId {
            // The same season after a playback: its progress has moved.
            await loadEpisodes(force: true)
        } else {
            seasonId = target
        }
    }

    private func togglePin() async {
        guard !pinBusy else { return }
        pinBusy = true
        defer { pinBusy = false }
        let wanted = !isPinned
        do {
            try await client.setPinned(wanted, itemId: shown.id, userId: userId)
            // Kept over whatever a load fetched before the change.
            pinned = wanted
            pinFailed = false
            model.homeIsStale = true
        } catch {
            if !model.sessionExpired(error, userId: userId) { pinFailed = true }
        }
    }
}

/// One episode: wide still, "T1 · E3" and its name, progress, a check once watched.
struct EpisodeCard: View {
    @Environment(\.locale) private var locale
    let episode: Item
    let client: JellyfinClient
    /// "T1 · E3 · Name" ("S1 · E3" in English), tidied by the page (see `DetailView.episodeTitle`).
    let title: String
    /// The one Play starts: a "Siguiente" badge on its still.
    var isNext = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EpisodeStill(episode: episode, client: client, isNext: isNext)
                .hoverEffect(.highlight)
            Text(verbatim: title)
                .font(.callout)
                .lineLimit(2)
                .frame(width: EpisodeStill.size.width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TileDescription.text(episode, language: AppLanguage(locale: locale), caption: title))
    }
}

/// An episode in the page's list: its still on the left, its name, length
/// and the start of its synopsis on the right.
struct EpisodeLine: View {
    @Environment(\.locale) private var locale
    let episode: Item
    let client: JellyfinClient
    let title: String
    var isNext = false

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            EpisodeStill(episode: episode, client: client, isNext: isNext)
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: title).font(.headline).lineLimit(2)
                ItemFacts(item: episode, showsName: false)
                if let overview = episode.overview, !overview.isEmpty {
                    Text(verbatim: overview).font(.callout).foregroundStyle(.white.opacity(0.75)).lineLimit(4)
                }
            }
            .padding(.vertical, 16)
            .padding(.trailing, 32)
            .frame(maxWidth: .infinity, maxHeight: EpisodeStill.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TileDescription.text(episode, language: AppLanguage(locale: locale), caption: title))
    }
}

/// Half an episode wide, ahead of the row: plays one of the season's
/// episodes at random.
struct SurpriseCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "dice.fill").font(.system(size: 72)).foregroundStyle(.white)
                }
                .frame(width: EpisodeStill.size.width / 2, height: EpisodeStill.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .hoverEffect(.highlight)
                Text("Sorpresa")
                    .font(.callout)
                    .frame(width: EpisodeStill.size.width / 2, alignment: .leading)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Text("Un episodio al azar"))
    }
}

/// An episode's still with its progress, a check once watched, and the
/// "Siguiente" badge on the one Play starts.
struct EpisodeStill: View {
    let episode: Item
    let client: JellyfinClient
    var isNext = false

    static let size = CGSize(width: 400, height: 225)

    var body: some View {
        still
            .frame(width: Self.size.width, height: Self.size.height)
            .overlay(alignment: .bottom) { ProgressBar(percent: episode.progressPercent) }
            .overlay(alignment: .topTrailing) {
                if episode.userData?.played == true {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.white, .tint).padding(10)
                }
            }
            .overlay(alignment: .topLeading) {
                if isNext {
                    Text("Siguiente").font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(.tint)).padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var still: some View {
        // An episode's own still (never the series backdrop it inherits:
        // without a still, its number); a film's or video's wide art, else
        // its poster whole on a dark band, where the library page lists them.
        if let ref = episode.kind == .episode ? episode.ownPrimaryImage : episode.wideImage {
            RemoteImage(url: client.imageURL(ref, maxHeight: Int(Self.size.height * 2)), blurHash: episode.blurHash(for: ref)) { placeholder }
        } else if episode.kind != .episode, let ref = episode.posterImage {
            ZStack {
                Rectangle().fill(.quaternary)
                RemoteImage(url: client.imageURL(ref, maxHeight: Int(Self.size.height * 2)), blurHash: episode.blurHash(for: ref)) { placeholder }
                    .frame(width: Self.size.height * 2 / 3, height: Self.size.height)
            }
        } else {
            placeholder
        }
    }

    /// No still: the episode's number, big, so the row still reads in order.
    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let number = episode.episodeNumber { Text(verbatim: String(number)).font(.system(size: 80, weight: .bold)).foregroundStyle(.secondary) }
        }
    }
}

/// One library as a poster grid, loaded a page at a time as it scrolls.
/// `LibraryListing` (MatineKit) drops pages for an older sort.
struct LibraryView: View {
    let library: Item
    let client: JellyfinClient
    let userId: String
    @Environment(AppModel.self) private var model

    @State private var sort: LibrarySort = .title
    @State private var listing = LibraryListing(sort: .title)
    @State private var pageTask: Task<Void, Never>?
    /// Bumped on each sort change: a cancelled task mustn't clear the newer one's handle.
    @State private var generation = 0
    @State private var failed = false
    /// Below the titles: what's partway through in this library, and a
    /// random handful (a library of one series is otherwise a lone tile in
    /// the dark). Read once per visit; Otros al azar draws again.
    @State private var watching: [Item] = []
    @State private var random: [Item] = []
    @State private var extrasLoaded = false
    @State private var arts: [SpotlightBackdrop.Art] = []
    @State private var randomTask: Task<Void, Never>?
    /// A playback ended while this tab was out of sight: Seguir viendo is
    /// read again when it's back, not by every library tab at once.
    @State private var watchingStale = false
    @State private var visible = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Text(verbatim: library.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    if let total = listing.total {
                        Text("\(total) títulos").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Picker("Orden", selection: $sort) {
                            Text("Título").tag(LibrarySort.title)
                            Text("Más recientes").tag(LibrarySort.dateAdded)
                        }
                    } label: {
                        Label(sort == .title ? "Ordenar: Título" : "Ordenar: Más recientes", systemImage: "arrow.up.arrow.down")
                    }
                }
                .focusSection()
                if failed {
                    RetryMessage("No se ha podido cargar la biblioteca.") { loadMore() }
                }
                if listing.items.isEmpty, pageTask != nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if listing.items.isEmpty, listing.exhausted {
                    Text("Esta biblioteca está vacía.").font(.title3).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300)
                }
                ItemGrid(items: listing.items, client: client) { item in
                    // A page ahead: the next one arrives before the end is reached.
                    if listing.items.suffix(12).contains(where: { $0.id == item.id }) { loadMore() }
                }
                // Once the titles are all there: below a grid still paging in,
                // these would keep moving down.
                if listing.exhausted { extras }
            }
            .padding(.top, SidebarRoom.top)
            .padding(.bottom, 40)
        }
        .background { CyclingBackdrop(arts: arts, client: client).opacity(0.7) }
        .task {
            guard !extrasLoaded else { return }
            extrasLoaded = true
            await loadExtras()
        }
        .onAppear {
            visible = true
            if watchingStale {
                watchingStale = false
                Task { await loadWatching() }
            }
        }
        .onDisappear { visible = false }
        .onChange(of: model.playbackEndedCount) {
            if visible { Task { await loadWatching() } } else { watchingStale = true }
        }
        .onChange(of: sort, initial: true) {
            pageTask?.cancel()
            pageTask = nil
            generation += 1
            failed = false
            listing.reset(sort: sort)
            loadMore()
        }
    }

    @ViewBuilder private var extras: some View {
        if !watching.isEmpty {
            VStack(alignment: .leading, spacing: 16) {
                Text("Seguir viendo").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: PosterCard.spacing) {
                        ForEach(watching) { item in
                            NavigationLink(value: Route.item(item)) { PosterCard(item: item, client: client, caption: item.searchCaption) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .padding(.vertical, 24)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
        if !random.isEmpty {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 32) {
                    Text("Al azar").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                    Button(action: drawAgain) { Label("Otros al azar", systemImage: "shuffle") }
                        .font(.callout)
                }
                .focusSection()
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(random) { item in
                        NavigationLink(value: Route.item(item)) {
                            EpisodeLine(episode: item, client: client, title: item.searchCaption)
                        }
                        .buttonStyle(.card)
                    }
                }
                .focusSection()
            }
        }
    }

    /// A new draw replaces one still on its way: the last press wins.
    private func drawAgain() {
        randomTask?.cancel()
        randomTask = Task { await loadRandom() }
    }

    private func loadExtras() async {
        async let watched: Void = loadWatching()
        async let drawn: Void = loadRandom()
        _ = await (watched, drawn)
    }

    private func loadWatching() async {
        do {
            watching = try await client.resume(userId: userId, libraryId: library.id, limit: 12)
        } catch {
            // Other errors leave the row as it was; an ended session goes to sign-in.
            model.sessionExpired(error, userId: userId)
        }
    }

    /// A new random handful, and the backdrops drawn from it.
    private func loadRandom() async {
        let items: [Item]
        do {
            items = try await client.shuffled(userId: userId, libraryId: library.id)
        } catch {
            model.sessionExpired(error, userId: userId)
            return
        }
        guard !Task.isCancelled else { return }
        random = items
        // Each title's own picture (an episode's still, not the series
        // backdrop every episode inherits), so a library of one series turns too.
        var seen = Set<SpotlightBackdrop.Art>()
        arts = items.compactMap { $0.kind == .episode ? $0.ownPrimaryImage : $0.wideImage }
            .map { SpotlightBackdrop.Art(ref: $0, soft: false) }
            .filter { seen.insert($0).inserted }
            .prefix(12).map { $0 }
    }

    /// One page at a time; a page that arrives after a sort change is dropped.
    private func loadMore() {
        guard pageTask == nil, let start = listing.nextStart else { return }
        let sort = sort, mine = generation
        pageTask = Task {
            defer { if generation == mine { pageTask = nil } }
            do {
                let page = try await client.libraryPage(userId: userId, libraryId: library.id, sort: sort, start: start, countTotal: start == 0)
                guard !Task.isCancelled else { return }
                listing.accept(page, for: sort)
                failed = false
            } catch {
                if !Task.isCancelled, !model.sessionExpired(error, userId: userId) { failed = true }
            }
        }
    }
}

/// Tiles in a wrapping grid; each opens its detail page.
struct ItemGrid: View {
    let items: [Item]
    let client: JellyfinClient
    var onAppear: (Item) -> Void = { _ in }
    /// Opening a tile through the caller (Search remembers what led there);
    /// nil: a plain link into the stack.
    var open: ((Item) -> Void)?

    /// Mostly 16:9 art (a library of videos, say) gets wide columns, so the
    /// pictures stay big enough to recognize; posters get portrait ones.
    private var columnWidth: CGFloat {
        items.filter(\.hasWidePoster).count * 2 > items.count ? 360 : 200
    }

    var body: some View {
        let width = columnWidth
        LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 48, alignment: .top)], alignment: .leading, spacing: 56) {
            ForEach(items) { item in
                Group {
                    if let open {
                        Button { open(item) } label: { PosterCard(item: item, client: client, columnWidth: width) }
                    } else {
                        NavigationLink(value: Route.item(item)) { PosterCard(item: item, client: client, columnWidth: width) }
                    }
                }
                .buttonStyle(.borderless)
                .onAppear { onAppear(item) }
            }
        }
        .focusSection()
    }
}

/// A call's value or its error: "it failed" (and why: an expired session)
/// stays apart from a call that succeeded with nothing in it.
func attempt<T: Sendable>(_ call: () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await call()) } catch { return .failure(error) }
}

extension Result {
    var error: Failure? { if case .failure(let error) = self { error } else { nil } }
}

/// What a screen says when its content couldn't load, with the way to try again.
struct RetryMessage: View {
    let text: LocalizedStringKey
    let retry: () -> Void

    init(_ text: LocalizedStringKey, retry: @escaping () -> Void) {
        self.text = text
        self.retry = retry
    }

    var body: some View {
        HStack(spacing: 24) {
            Text(text).foregroundStyle(.red)
            Button("Reintentar", action: retry)
        }
        .focusSection()
    }
}
