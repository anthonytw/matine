import MatineKit
import SwiftUI

/// Search as you type, on the device: the profile's whole catalog is read
/// once (again after a while), then every keystroke searches it here, with
/// titles related by meaning when the on-device language model is there.
/// Everything comes through the `LibrarySource`, so a downloaded-only source
/// searches just what is downloaded, with no change here.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    let account: Account
    let source: any LibrarySource
    let open: (Item) -> Void

    @State private var text = ""
    /// Everything but drawing (the catalog, the index, the meaning model, each
    /// query) lives in the kit's `SearchSession`; made on appear, as it needs `model`.
    @State private var session: SearchSession?
    @State private var attempt = 0
    @State private var recent: [String] = []

    private var recentStore: RecentSearches { model.profiles.store.recentSearches(for: account.id) }
    private var results: SearchResults { session?.results ?? SearchResults() }
    private var typed: String { text.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if session?.failed == true, session?.index == nil {
                    RetryMessage("No se puede conectar con el servidor.") { attempt += 1 }
                } else if typed.isEmpty {
                    if recent.isEmpty {
                        ContentUnavailableView("Buscar", systemImage: "magnifyingglass", description: Text("Busca películas, series y episodios, en español o en inglés."))
                    } else {
                        recentList
                    }
                } else if session?.index == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: typed)
                } else {
                    ForEach(results.sections) { section in
                        Shelf(title: Self.title(section.group), items: section.items, source: source, wide: section.group == .episodes, searchCaptions: true) { item in
                            recentStore.add(typed)
                            recent = recentStore.list()
                            open(item)
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Buscar")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Buscar"))
        .onAppear {
            recent = recentStore.list()
            if session == nil { session = makeSession() }
            #if DEBUG
            // -MatineDevSearch TEXT: start with this search typed (debug only, for screenshots).
            if text.isEmpty, let typed = UserDefaults.standard.string(forKey: "MatineDevSearch") { text = typed }
            #endif
        }
        .onChange(of: model.keywords.version) { session?.keywordsChanged() }
        .task(id: attempt) {
            if session == nil { session = makeSession() }
            await session?.load()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { attempt += 1 } }
        // Offline the catalog is the downloaded titles; back online, the whole library.
        .onChange(of: model.isOffline) { session?.reset(); attempt += 1 }
        // Word matches come at once, the related titles after a pause: see `SearchSession.search`.
        .task(id: "\(text)|\(session?.revision ?? 0)") { await session?.search(typed) }
    }

    static func title(_ group: SearchResults.Group) -> Text {
        switch group {
        case .movies: Text("Películas")
        case .series: Text("Series")
        case .episodes: Text("Episodios")
        case .videos: Text("Vídeos")
        case .related: Text("Relacionado")
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Búsquedas recientes").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Borrar") {
                    recentStore.clear()
                    recent = []
                }
                .font(.callout)
            }
            .padding(.horizontal)
            ForEach(recent, id: \.self) { search in
                Button { text = search } label: {
                    Label { Text(verbatim: search) } icon: { Image(systemName: "clock.arrow.circlepath") }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10).padding(.horizontal)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func makeSession() -> SearchSession {
        let source = source, account = account, model = model
        return SearchSession(
            // Online, the keyword run and Search read the catalog once between them.
            // Only the server's own answers are shared: never the mirror's list.
            catalog: { _ in
                guard !(await model.isOffline), let server = (source as? HybridLibrarySource)?.server else { return try await source.catalog() }
                do {
                    return try await model.keywords.sharedCatalog(key: KeywordsModel.catalogKey(account)) { try await server.catalog() }
                } catch let error as JellyfinError where error.isConnectivity {
                    return try await source.catalog()
                }
            },
            supportsCredits: false,
            keywords: { items in await model.keywords.store(for: items, account: account, profiles: model.profiles) },
            keywordVersion: { model.keywords.version },
            sessionExpired: { model.sessionExpired($0, userId: account.id) },
            makeModel: { await ContextualVectors.make() },
            cache: MeaningCache.standard(accountId: account.id)
        )
    }
}
