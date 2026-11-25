import MatineKit
import SwiftUI

/// Inicio: what to watch now (Seguir viendo, Fijados), then what's new in
/// each library. A hero card for the first thing worth watching tops it.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.play) private var play
    let account: Account
    let source: any LibrarySource
    let open: (Item) -> Void

    enum Load { case loading, loaded(HomeContent), failed }
    @State private var load: Load = .loading
    /// A refresh failed but the last rows are still shown.
    @State private var refreshFailed = false

    var body: some View {
        Group {
            switch load {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                RetryMessage("No se puede conectar con el servidor.") { Task { await reload() } }
            case .loaded(let content):
                if content.rows.isEmpty {
                    ContentUnavailableView("Todavía no hay nada que ver.", systemImage: "film.stack")
                } else {
                    rows(content.rows)
                }
            }
        }
        .navigationTitle("Inicio")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .onChange(of: model.playbackEndedCount) { Task { await reload() } }
    }

    private func rows(_ rows: [HomeRow]) -> some View {
        let hero = rows.first?.items.first
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if refreshFailed {
                    Label("No se ha podido actualizar el inicio.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                if let hero { Hero(item: hero, source: source, open: open) }
                ForEach(rows) { row in
                    Shelf(title: Self.title(row.kind), items: row.items, source: source, wide: row.kind == .continueWatching, open: open)
                }
                if model.rules.unguardedAdults.contains(where: { $0.id == account.id }) {
                    Label("Cualquiera puede abrir este perfil: ponle un PIN.", systemImage: "lock.open")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await reload() }
    }

    static func title(_ kind: HomeRow.Kind) -> Text {
        switch kind {
        case .pinned: Text("Fijados")
        case .continueWatching: Text("Seguir viendo")
        case .latest(_, let name): Text("Novedades en \(name)")
        }
    }

    private func reload() async {
        do {
            let content = try await source.home()
            guard !Task.isCancelled else { return }
            load = .loaded(content)
            refreshFailed = false
        } catch {
            guard !Task.isCancelled, !model.sessionExpired(error, userId: account.id) else { return }
            if case .loaded = load { refreshFailed = true } else { load = .failed }
        }
    }
}

/// The first thing worth watching, big: its backdrop, title and a Play button.
private struct Hero: View {
    @Environment(\.locale) private var locale
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.play) private var play
    let item: Item
    let source: any LibrarySource
    let open: (Item) -> Void

    private var art: ImageRef? { item.backdropImage ?? item.wideImage ?? item.posterImage }

    var body: some View {
        ArtView(item: item, ref: art, source: source, aspect: sizeClass == .regular ? 21 / 9 : 4 / 3, maxHeight: 900)
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.2), .init(color: .black.opacity(0.9), location: 1)], startPoint: .top, endPoint: .bottom)
            }
            // The card opens the item's page; Play is its own button beside that
            // (not inside it), so VoiceOver and Switch Control reach both.
            .overlay {
                Button { open(item) } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: item.tileCaption(AppLanguage(locale: locale))))
                    .accessibilityHint(Text("Abre la ficha"))
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: item.kind == .episode ? (item.seriesName ?? item.displayName) : item.displayName)
                        .font(.title.bold()).lineLimit(2)
                    if item.kind == .episode { Text(verbatim: item.episodeTitle(AppLanguage(locale: locale))).font(.subheadline) }
                    Button { play(item, from: item.resumeTicks) } label: {
                        Label(item.resumeTicks > 0 ? "Continuar" : "Reproducir", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white).foregroundStyle(.black)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                .padding()
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal)
    }
}
