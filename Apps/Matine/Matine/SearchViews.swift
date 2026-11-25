import MatineKit
import SwiftUI

/// Search as you type, on the device: the profile's whole catalog is read
/// once (and again after a while away, on coming back to the tab or to the
/// app), then every keystroke searches it
/// here. Results come in rows by kind, then titles related by meaning when
/// the on-device language model is there. With the field empty, the
/// profile's recent searches.
struct SearchView: View {
    let client: JellyfinClient
    let account: Account
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    /// Everything but drawing (the catalog, the index, the meaning model, each
    /// query) lives in the kit's `SearchSession`; made on appear, as it needs `model`.
    @State private var session: SearchSession?
    /// Bumped by Reintentar, and on returning to the app, to read the
    /// catalog again if it's stale (and pick up a newly arrived model).
    @State private var attempt = 0
    @State private var recent: [String] = []
    /// Opens a result in the tab's stack (and remembers the search).
    let open: (Item) -> Void

    private var recentStore: RecentSearches { model.profiles.store.recentSearches(for: account.id) }
    private var results: SearchResults { session?.results ?? SearchResults() }
    private var typed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                if session?.failed == true, session?.index == nil {
                    RetryMessage("No se puede conectar con el servidor.") { attempt += 1 }
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else if typed.isEmpty {
                    if recent.isEmpty {
                        placeholder(Text("Busca películas, series y episodios, en español o en inglés."))
                    } else {
                        recentList
                    }
                } else if session?.index == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                } else if results.isEmpty {
                    placeholder(Text("Sin resultados para «\(typed)»."))
                } else {
                    ForEach(results.sections) { section in
                        SearchRow(section: section, reasons: results.reasons, client: client) { item in
                            recentStore.add(typed)
                            recent = recentStore.list()
                            open(item)
                        }
                    }
                }
            }
            .padding(.top, SidebarRoom.top)
            .padding(.bottom, 40)
        }
        .scrollClipDisabled()
        .searchable(text: $text, prompt: Text("Buscar"))
        .onAppear {
            recent = recentStore.list()
            if session == nil { session = makeSession() }
        }
        .task(id: attempt) {
            if session == nil { session = makeSession() }
            await session?.load()
        }
        .onChange(of: model.keywords.version) { session?.keywordsChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { attempt += 1 }
        }
        // Word matches come at once, the related titles after a pause: see `SearchSession.search`.
        .task(id: "\(text)|\(session?.revision ?? 0)") { await session?.search(typed) }
    }

    private func placeholder(_ text: Text) -> some View {
        text.font(.title3)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 300)
    }

    private func makeSession() -> SearchSession {
        let client = client, account = account, model = model
        return SearchSession(
            catalog: { credits in try await client.catalog(userId: account.id, credits: credits) },
            supportsCredits: true,
            keywords: { items in await model.keywords.store(for: items, account: account, profiles: model.profiles) },
            keywordVersion: { model.keywords.version },
            // iCloud's news arrives a moment later, without holding the search up.
            catalogRead: { items in Task { await model.keywords.refresh(account: account, items: items, profiles: model.profiles) } },
            sessionExpired: { model.sessionExpired($0, userId: account.id) },
            makeModel: { await ContextualVectors.make() },
            cache: MeaningCache.standard(accountId: account.id)
        )
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 24) {
                Text("Búsquedas recientes").font(.title3.bold())
                Button("Borrar") {
                    recentStore.clear()
                    recent = []
                }
                .font(.callout)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 24) {
                    ForEach(recent, id: \.self) { search in
                        Button { text = search } label: {
                            Label(search, systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 80)
        .focusSection()
    }
}

/// One kind of result, in a row of tiles (as Home's rows).
private struct SearchRow: View {
    let section: SearchResults.Section
    /// Why a tile matched, where its title doesn't say.
    let reasons: [String: SearchResults.Reason]
    let client: JellyfinClient
    let open: (Item) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                switch section.group {
                case .movies: Text("Películas")
                case .series: Text("Series")
                case .episodes: Text("Episodios")
                case .videos: Text("Vídeos")
                case .related: Text("Relacionado")
                }
            }
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: PosterCard.spacing) {
                    ForEach(section.items) { item in
                        Button {
                            open(item)
                        } label: {
                            PosterCard(
                                item: item, client: client, caption: item.searchCaption,
                                detail: reasons[item.id]?.text, reservesDetail: section.items.contains { reasons[$0.id] != nil }
                            )
                        }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .padding(.horizontal, 80)
        .focusSection()
    }
}
