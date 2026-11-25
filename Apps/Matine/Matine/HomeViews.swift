import MatineKit
import SwiftUI

/// Inicio: what to watch now (Seguir viendo, Fijados),
/// then what's new in each library. Behind the rows, the focused tile's
/// backdrop fades in, so the screen follows the remote.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let client: JellyfinClient
    /// Handed up for the library tabs: the list this load's rows came from.
    @Binding var libraries: [Item]
    @Binding var playing: PlayRequest?
    /// The notice's "Poner un PIN": to the profile tab.
    let openSettings: () -> Void

    enum Load { case loading, loaded([HomeRow]), failed(JellyfinError?) }
    @State private var load: Load = .loading
    @State private var loading = false
    /// The first load has started: coming back to this tab or page (which restarts `.task`) doesn't load again.
    @State private var startedOnce = false
    @State private var reloadAgain = false
    /// A refresh failed but the last rows are still shown: a line says so.
    @State private var refreshFailed = false
    /// The item whose backdrop is behind the rows: the focused tile's, once
    /// focus has rested on it a moment (scrolling past tiles doesn't flicker).
    @State private var spotlight: Item?
    /// The focused tile, as "row id|item id" (one item can sit in two rows).
    /// Set once the rows arrive, so focus opens on the first tile rather than
    /// on the tab bar, the only thing on screen while loading.
    @FocusState private var focusedTile: String?
    /// The row whose heading sits at the top of the rows: the focused
    /// tile's. Moving along a row never scrolls; moving down a row brings
    /// that row, heading and all, to the top (as the TV app does), so a
    /// heading never slides under the synopsis.
    @State private var topRow: String?

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpotlightBackdrop(art: Spotlight.art(spotlight), client: client)
            VStack(alignment: .leading, spacing: 24) {
                // What the focused tile is, above the rows (as the TV app and
                // Netflix do): its logo or title, a line of facts, the synopsis.
                HomeHero(item: spotlight, client: client)
                    .frame(height: HomeHero.height, alignment: .bottomLeading)
                    .padding(.top, SidebarRoom.top - 30)
                // Clipped at the top, so rows never slide over the hero; the
                // margin leaves room for a focused tile's lift and shadow.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 36) {
                        notice
                        content
                    }
                    .scrollTargetLayout()
                    .padding(.bottom, 60)
                }
                .scrollPosition(id: $topRow, anchor: .top)
                .contentMargins(.top, 24, for: .scrollContent)
                .padding(.top, -24)
            }
        }
        .onChange(of: focusedTile) {
            guard let tile = focusedTile, !tile.hasPrefix("skeleton|") else { return }
            let row = String(tile.prefix { $0 != "|" })
            if row != topRow { withAnimation(.easeInOut(duration: 0.25)) { topRow = row } }
        }
        .task(id: focusedTile) {
            guard let focusedTile, let item = item(for: focusedTile) else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            spotlight = item
        }
        // Back after hours away (the next morning): the top, on fresh rows.
        .onChange(of: model.returnedAfterLongAwayCount) {
            Task { await reloadIfStale() }
        }
        .task {
            guard !startedOnce else { return }
            startedOnce = true
            await reload()
        }
        // Back on Home (from a page, a tab or the player): refresh only if a
        // pin or a playback changed something.
        .onAppear { Task { await reloadIfStale() } }
        .onChange(of: model.playbackEndedCount) { Task { await reloadIfStale() } }
    }

    /// With a kid profile on this Apple TV, an adult profile without a PIN is
    /// one click away for the kid: say so, with the fix.
    @ViewBuilder private var notice: some View {
        if model.rules.unguardedAdults.contains(where: { $0.id == account.id }) {
            HStack(spacing: 24) {
                Image(systemName: "exclamationmark.shield.fill").font(.title2).foregroundStyle(.yellow)
                Text("Hay perfiles infantiles y este perfil no tiene PIN: cualquiera puede entrar en él.")
                    .font(.callout)
                Button("Poner un PIN", action: openSettings)
            }
            .frame(maxWidth: 1400, alignment: .leading)
            .focusSection()
        }
    }

    @ViewBuilder private var content: some View {
        switch load {
        case .loading:
            skeleton
        case .failed(let error):
            VStack(spacing: 24) {
                Text(error == .unauthorized ? "La sesión ha caducado." : "No se ha podido cargar el inicio.")
                    .font(.title3)
                if error == .unauthorized {
                    Button("Iniciar sesión de nuevo") { model.screen = .addProfile(account) }
                } else {
                    Button("Reintentar") { Task { await reload() } }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 400)
        case .loaded(let rows) where rows.isEmpty:
            Text("Todavía no hay nada que ver.").font(.title3).frame(maxWidth: .infinity, minHeight: 400)
        case .loaded(let rows):
            if refreshFailed {
                RetryMessage("No se ha podido actualizar el inicio.") { Task { await reload() } }
            }
            ForEach(rows) { row in
                ItemRow(rowId: row.id, title: title(for: row), items: row.items, client: client, focusedTile: $focusedTile, play: play)
                    .id(row.id)
            }
        }
    }

    /// Gray tiles where the rows will be. They can hold focus, so the remote
    /// starts in the content (not the sidebar) and moves to the first real
    /// tile when the rows replace them.
    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 36) {
            ForEach(0..<2, id: \.self) { row in
                VStack(alignment: .leading, spacing: 20) {
                    RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.12)).frame(width: 280, height: 30)
                    HStack(spacing: PosterCard.spacing) {
                        ForEach(0..<5, id: \.self) { index in
                            Button {} label: {
                                RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.08))
                                    .frame(width: PosterCard.wide.width, height: PosterCard.wide.height)
                            }
                            .buttonStyle(.borderless)
                            .focused($focusedTile, equals: "skeleton|\(row)|\(index)")
                            .accessibilityLabel(Text("Cargando…"))
                        }
                    }
                    .padding(.vertical, 20)
                }
            }
        }
        .focusSection()
        .defaultFocus($focusedTile, "skeleton|0|0")
    }

    private func item(for tile: String) -> Item? {
        guard case .loaded(let rows) = load else { return nil }
        let parts = tile.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return rows.first { $0.id == parts[0] }?.items.first { $0.id == parts[1] }
    }

    /// Play/Pause on a tile: straight into playback, resuming; a series plays
    /// the episode its page would.
    private func play(_ item: Item) {
        Task {
            if item.kind == .series {
                do {
                    guard let episode = try await client.episodeToPlay(seriesId: item.id, userId: account.id) else { return }
                    playing = PlayRequest(item: episode, startTicks: episode.resumeTicks)
                } catch {
                    model.sessionExpired(error, userId: account.id)
                }
            } else if item.kind != .folder, item.kind != .boxSet {
                playing = PlayRequest(item: item, startTicks: item.resumeTicks)
            }
        }
    }

    private func title(for row: HomeRow) -> LocalizedStringKey {
        switch row.kind {
        case .pinned: "Fijados"
        case .continueWatching: "Seguir viendo"
        case .latest(_, let name): "Novedades en \(name)"
        }
    }

    private func reloadIfStale() async {
        guard model.homeIsStale else { return }
        model.homeIsStale = false
        await reload()
    }

    private func reload() async {
        // One load at a time; a request during it runs once it's done, so a
        // change that came in mid-load isn't missed.
        guard !loading else { reloadAgain = true; return }
        loading = true
        defer {
            loading = false
            if reloadAgain {
                reloadAgain = false
                Task { await reload() }
            }
        }
        do {
            let content = try await HomeLoader(client: client, userId: account.id).load()
            let rows = content.rows
            model.updateTopShelf(for: account, client: client, rows: rows)
            if libraries != content.libraries { libraries = content.libraries }
            let keys = Set(rows.flatMap { row in row.items.map { "\(row.id)|\($0.id)" } })
            let first = rows.first.flatMap { row in row.items.first.map { "\(row.id)|\($0.id)" } }
            load = .loaded(rows)
            refreshFailed = false
            if spotlight == nil { spotlight = rows.first?.items.first }
            // From a skeleton tile (the first load) to the first real one; a
            // tile that has gone (a finished episode leaving Seguir viendo)
            // to the first of its row. Focus in the sidebar stays there.
            guard let tile = focusedTile, !keys.contains(tile) else { return }
            if tile.hasPrefix("skeleton|") {
                await Task.yield()
                focusedTile = first
            } else {
                let rowId = String(tile.prefix { $0 != "|" })
                let row = rows.first { $0.id == rowId && !$0.items.isEmpty } ?? rows.first
                await Task.yield()
                focusedTile = row.flatMap { row in row.items.first.map { "\(row.id)|\($0.id)" } }
            }
        } catch {
            // Leaving the screen mid-load cancels it: not a failure. A first load that was
            // cut short starts again the next time Home appears.
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                if case .loaded = load {} else { startedOnce = false }
                return
            }
            if model.sessionExpired(error, userId: account.id) { return }
            // A refresh that fails keeps what's on screen.
            if case .loaded = load { refreshFailed = true } else { load = .failed(error as? JellyfinError) }
        }
    }
}

/// Room the content of each tab leaves for the collapsed sidebar, which
/// floats over the top-left corner.
enum SidebarRoom {
    static let top: CGFloat = 150
}

/// The hero's text: the focused item's logo (or its title), a line of
/// facts and three lines of synopsis. Crossfades as focus moves.
struct HomeHero: View {
    let item: Item?
    let client: JellyfinClient
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 330

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let item {
                VStack(alignment: .leading, spacing: 14) {
                    title(item)
                    ItemFacts(item: item)
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.callout)
                            .lineLimit(3)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: 980, alignment: .leading)
                    }
                }
                .id(item.id)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: item?.id)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func title(_ item: Item) -> some View {
        Title(item: item, client: client, size: 60)
    }

    /// The show's logo when it has one, else its name in big type.
    struct Title: View {
        let item: Item
        let client: JellyfinClient
        let size: CGFloat

        var body: some View {
            let name = item.seriesName ?? item.displayName
            if let logo = item.logoImage {
                AsyncImage(url: client.imageURL(logo, maxHeight: 300)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        text(name)
                    }
                }
                .frame(maxWidth: size * 10, maxHeight: size * 2.3, alignment: .bottomLeading)
                .accessibilityLabel(Text(verbatim: name))
                .accessibilityAddTraits(.isHeader)
            } else {
                text(name).frame(maxWidth: 1100, alignment: .leading).accessibilityAddTraits(.isHeader)
            }
        }

        private func text(_ name: String) -> some View {
            Text(verbatim: name).font(.system(size: size, weight: .bold)).lineLimit(2).minimumScaleFactor(0.7)
        }
    }
}

/// "T1 · E3 · Name · 2019 · 42 min", as much of it as the item has.
struct ItemFacts: View {
    @Environment(\.locale) private var locale
    let item: Item
    /// An episode's label and name lead (off where the name is shown already).
    var showsName = true
    /// The age rating, score and studio: a title's own page shows them,
    /// rows and lists of episodes don't.
    var showsRatings = false

    private enum Part {
        case text(Text)
        /// The age rating, in a small outline.
        case badge(String)
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 { Text(verbatim: "·").accessibilityHidden(true) }
                switch part {
                case .text(let text): text
                case .badge(let rating):
                    Text(verbatim: rating)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.6), lineWidth: 1.5))
                }
            }
        }
        .accessibilityElement(children: .combine)
        .font(.callout.weight(.medium))
        .foregroundStyle(.white.opacity(0.75))
        .lineLimit(1)
    }

    private var parts: [Part] {
        var parts: [Part] = []
        if item.kind == .episode, showsName {
            if let label = item.episodeLabel(AppLanguage(locale: locale)) { parts.append(.text(Text(verbatim: label))) }
            parts.append(.text(Text(verbatim: item.displayName)))
        }
        if let year = item.productionYear, item.kind != .episode { parts.append(.text(Text(verbatim: String(year)))) }
        if let ticks = item.runTimeTicks, ticks > 0 {
            let seconds = Int64(ticks / 10_000_000)
            parts.append(.text(Text(Duration.seconds(seconds), format: .units(allowed: [.hours, .minutes], width: .abbreviated))))
        }
        // Only where asked for (a title's own page): rows and episode lists stay as they were.
        if showsRatings {
            if let rating = item.officialRating, !rating.isEmpty { parts.append(.badge(rating)) }
            if let score = item.ratingText { parts.append(.text(Text(verbatim: score))) }
            if let studio = item.studios?.first, !studio.isEmpty { parts.append(.text(Text(verbatim: studio))) }
        }
        if item.userData?.played == true { parts.append(.text(Text("Visto"))) }
        return parts
    }
}

/// `SpotlightBackdrop` taking each of `arts` in turn, a slow crossfade
/// every few seconds (one picture, or Reduce Motion: it stays).
struct CyclingBackdrop: View {
    let arts: [SpotlightBackdrop.Art]
    let client: JellyfinClient
    var every: Duration = .seconds(9)
    @State private var index = 0
    @State private var onScreen = false
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Turning only while someone can see it: not behind the player, another
    /// tab, the screensaver, or with the art hidden (Reduce Transparency).
    private var turning: Bool {
        arts.count > 1 && onScreen && scenePhase == .active && !model.playerIsOpen && !reduceMotion && !reduceTransparency
    }

    var body: some View {
        SpotlightBackdrop(art: arts.isEmpty ? nil : arts[index % arts.count], client: client)
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .onChange(of: arts) { index = 0 }
            .task(id: "\(arts.hashValue)|\(turning)") {
                guard turning else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: every)
                    guard !Task.isCancelled else { return }
                    index += 1
                }
            }
    }
}

/// Which art goes behind Home for an item, and how.
enum Spotlight {
    static func art(_ item: Item?) -> SpotlightBackdrop.Art? {
        guard let item else { return nil }
        if let ref = item.backdropImage { return .init(ref: ref, soft: false) }
        if let ref = item.wideImage { return .init(ref: ref, soft: false) }
        return item.posterImage.map { .init(ref: $0, soft: true) }
    }
}

/// Art behind a screen, sharp on the right ~two thirds and fading into black
/// toward the left and the bottom, where the text and rows sit. A new image
/// replaces the old only once it has loaded, then crossfades, so moving
/// along a row never flashes a blur. Portrait art (no wide image at all) is
/// softened, since it's cropped to a wide frame.
struct SpotlightBackdrop: View {
    struct Art: Hashable {
        let ref: ImageRef
        let soft: Bool
    }

    let art: Art?
    let client: JellyfinClient
    @State private var shown: (art: Art, image: Image)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if let shown, !reduceTransparency {
                shown.image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 1300, height: 1300 * 9 / 16)
                    .clipped()
                    .blur(radius: shown.art.soft ? 24 : 0)
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.4)], startPoint: .leading, endPoint: .trailing)
                    }
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                    .opacity(0.9)
                    .id(shown.art)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: shown?.art)
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .task(id: art) {
            guard let art else { return }
            let url = client.imageURL(art.ref, maxHeight: art.soft ? 480 : 1080)
            // Through the shared cache the tiles also use: tokenless URLs.
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled, let decoded = UIImage(data: data) else { return }
            // Decoded here, off the main thread, not at the first draw (a hitch in the focus animation).
            let image = await decoded.byPreparingForDisplay() ?? decoded
            guard !Task.isCancelled else { return }
            shown = (art, Image(uiImage: image))
        }
    }
}

struct ItemRow: View {
    let rowId: String
    let title: LocalizedStringKey
    let items: [Item]
    let client: JellyfinClient
    var focusedTile: FocusState<String?>.Binding
    var play: (Item) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: PosterCard.spacing) {
                    ForEach(items) { item in
                        NavigationLink(value: Route.item(item)) { PosterCard(item: item, client: client) }
                            .buttonStyle(.borderless)
                            .focused(focusedTile, equals: "\(rowId)|\(item.id)")
                            .onPlayPauseCommand { play(item) }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

struct PosterCard: View {
    @Environment(\.locale) private var locale
    private var language: AppLanguage { AppLanguage(locale: locale) }
    let item: Item
    let client: JellyfinClient
    /// In a grid every tile is one column wide: the art keeps its shape at
    /// that width instead of spanning columns. Nil in a row (fixed height).
    var columnWidth: CGFloat?
    /// Instead of `tileCaption` (Search leads with the episode's own name).
    var caption: String?
    /// A second line in small type under the caption (why Search found it);
    /// `reservesDetail` keeps its room when other tiles of the row have one.
    var detail: String?
    var reservesDetail = false

    /// In a row every tile is one height, wide art or poster, so a row of
    /// both lines up (and a lazy row, sized by the tiles it has measured,
    /// never spills into the next): 16:9 at 444 × 250, 2:3 at 167 × 250.
    static let rowHeight: CGFloat = 250
    static let wide = CGSize(width: rowHeight * 16 / 9, height: rowHeight)
    static let portrait = CGSize(width: rowHeight * 2 / 3, height: rowHeight)
    static let spacing: CGFloat = 40

    /// Wide for 16:9 art, portrait otherwise (`Item.hasWidePoster`), so neither
    /// is cropped to the other's shape.
    private var size: CGSize {
        let ratio: CGFloat = item.hasWidePoster ? 16 / 9 : 2 / 3
        if let columnWidth { return CGSize(width: columnWidth, height: columnWidth / ratio) }
        return item.hasWidePoster ? Self.wide : Self.portrait
    }

    var body: some View {
        // In a grid a focused poster lifts into its caption: more room there.
        VStack(alignment: .leading, spacing: columnWidth == nil ? 12 : size.height * 0.06) {
            poster
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .bottom) { progress }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // The system's focus: the art lifts, tilts with the thumb
                // on the remote and catches the light.
                .hoverEffect(.highlight)
            // Two lines' room even for a one-line name: every tile, and so
            // every row, keeps one height.
            Text(caption ?? item.tileCaption(AppLanguage(locale: locale)))
                .font(.callout)
                .lineLimit(2, reservesSpace: true)
                .frame(width: size.width, alignment: .leading)
            if detail != nil || reservesDetail {
                Text(verbatim: detail ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: size.width, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { Text("\(TileDescription.text(item, language: language, caption: caption)), \($0)") } ?? TileDescription.text(item, language: language, caption: caption))
        .accessibilityHint(Text("Pulsa reproducir para empezar."))
    }

    @ViewBuilder private var poster: some View {
        if let ref = item.posterImage {
            // The size drawn, at the TV's 2x.
            RemoteImage(url: client.imageURL(ref, maxHeight: Int(size.height * 2)), blurHash: item.blurHash(for: ref)) { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Text(item.seriesName ?? item.displayName).font(.headline).multilineTextAlignment(.center).padding()
        }
    }

    private var progress: some View { ProgressBar(percent: item.progressPercent) }
}

/// The thin bar along a tile's bottom edge (nothing when `percent` is nil).
struct ProgressBar: View {
    let percent: Double?

    var body: some View {
        if let percent {
            GeometryReader { geometry in
                Capsule().fill(.tint).frame(width: geometry.size.width * percent / 100, height: 6)
            }
            .frame(height: 6)
            .padding(10)
        }
    }
}


/// What VoiceOver says for a tile: its caption, and how far it's watched.
enum TileDescription {
    static func text(_ item: Item, language: AppLanguage, caption: String? = nil) -> Text {
        let caption = caption ?? item.tileCaption(language)
        if item.userData?.played == true { return Text("\(caption), visto") }
        if item.progressPercent != nil { return Text("\(caption), empezado") }
        return Text(verbatim: caption)
    }
}
