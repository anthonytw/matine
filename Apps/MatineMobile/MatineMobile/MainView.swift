import MatineKit
import SwiftUI

/// Something to play, and where to start (ticks of 100 ns; 0 is the start).
struct PlayRequest: Identifiable {
    let item: Item
    let startTicks: Int64
    var id: String { "\(item.id)@\(startTicks)" }
}

/// Screens ask to play through the environment, so only `MainView` owns the player.
struct PlayAction {
    let run: @MainActor (Item, Int64) -> Void
    @MainActor func callAsFunction(_ item: Item, from ticks: Int64 = 0) { run(item, ticks) }
}

private struct PlayActionKey: EnvironmentKey {
    static let defaultValue = PlayAction { _, _ in }
}

extension EnvironmentValues {
    var play: PlayAction {
        get { self[PlayActionKey.self] }
        set { self[PlayActionKey.self] = newValue }
    }
}

enum Place: Hashable {
    case home, search, libraries, library(String), downloads, profile
}

/// The signed-in app: a sidebar on a wide screen (iPad), tabs on a narrow one
/// (iPhone, or an iPad squeezed into a slice of the screen). Each place keeps
/// its own navigation stack; the player covers them all.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let account: Account
    let source: any LibrarySource

    @State private var section: Place = .home
    @State private var paths: [Place: [Item]] = [:]
    /// The iPad's places seen so far (see `splitView`).
    @State private var visited: [Place] = []
    @State private var libraries: [Item] = []
    @State private var playing: PlayRequest?
    @State private var loadedLibraries = false

    private var shown: Account { model.current(account) }

    var body: some View {
        Group {
            if sizeClass == .regular { splitView } else { tabs }
        }
        .environment(\.play, PlayAction { item, ticks in playing = PlayRequest(item: item, startTicks: ticks) })
        .fullScreenCover(item: $playing) { request in
            PlayerView(item: request.item, account: shown, source: source, language: shown.language, startTicks: request.startTicks)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.isOffline {
                Label("Sin conexión: se muestran las descargas.", systemImage: "icloud.slash")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(.bar)
                    .accessibilityIdentifier("offline.banner")
            }
        }
        .alert("No se ha podido descargar.", isPresented: Binding(get: { model.downloads.problem }, set: { model.downloads.problem = $0 })) {
            Button("Vale", role: .cancel) {}
        } message: {
            Text("Hace falta conexión con el servidor.")
        }
        .task { await model.profileOpened(account) }
        .task(id: model.playbackEndedCount) { await loadLibraries() }
        #if DEBUG
        .task { await openDebugRoute() }
        #endif
    }

    private func loadLibraries() async {
        do {
            libraries = try await source.libraries()
            loadedLibraries = true
        } catch {
            _ = model.sessionExpired(error, userId: account.id)
        }
    }

    // MARK: iPhone

    private var tabs: some View {
        TabView(selection: $section) {
            Tab("Inicio", systemImage: "house.fill", value: Place.home) { stack(.home) }
            if !shown.isKid {
                Tab("Buscar", systemImage: "magnifyingglass", value: Place.search, role: .search) { stack(.search) }
            }
            Tab("Bibliotecas", systemImage: "rectangle.stack.fill", value: Place.libraries) { stack(.libraries) }
            Tab("Descargas", systemImage: "arrow.down.circle.fill", value: Place.downloads) { stack(.downloads) }
            Tab("Perfil", systemImage: "person.crop.circle.fill", value: Place.profile) { stack(.profile) }
        }
    }

    // MARK: iPad

    private var splitView: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { if let new = $0 { section = new } })) {
                Label("Inicio", systemImage: "house.fill").tag(Place.home)
                if !shown.isKid { Label("Buscar", systemImage: "magnifyingglass").tag(Place.search) }
                if !libraries.isEmpty {
                    Section("Bibliotecas") {
                        ForEach(libraries) { library in
                            Label { Text(verbatim: library.name) } icon: { Image(systemName: Self.icon(library)) }
                                .tag(Place.library(library.id))
                        }
                    }
                }
                Label("Descargas", systemImage: "arrow.down.circle.fill").tag(Place.downloads)
                Section {
                    Label {
                        Text(verbatim: shown.shownName)
                    } icon: {
                        AvatarView(avatar: shown.avatar, size: 28)
                    }
                    .tag(Place.profile)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Matiné")
        } detail: {
            // Every place visited stays alive, only the chosen one is shown: going back to
            // Buscar keeps its catalog, its index and its scroll, as a tab does on the iPhone.
            ZStack {
                ForEach(visited.contains(section) ? visited : visited + [section], id: \.self) { place in
                    stack(place)
                        .opacity(place == section ? 1 : 0)
                        .allowsHitTesting(place == section)
                        .accessibilityHidden(place != section)
                }
            }
            .onChange(of: section, initial: true) { if !visited.contains(section) { visited.append(section) } }
        }
    }

    // MARK: Stacks

    private func stack(_ key: Place) -> some View {
        NavigationStack(path: Binding(get: { paths[key] ?? [] }, set: { paths[key] = $0 })) {
            root(key)
                .navigationDestination(for: Item.self) { item in
                    // Inside Descargas everything reads the mirror, online or not.
                    let shown: any LibrarySource = key == .downloads ? model.localSource(for: account) : source
                    if item.kind == .collectionFolder {
                        LibraryView(library: item, source: shown)
                    } else {
                        DetailView(item: item, source: shown, account: account)
                    }
                }
        }
    }

    @ViewBuilder private func root(_ key: Place) -> some View {
        switch key {
        case .home:
            HomeView(account: account, source: source, open: { open($0) })
        case .search:
            SearchView(account: account, source: source, open: { open($0) })
        case .libraries:
            LibraryListView(libraries: libraries, loaded: loadedLibraries, source: source) { Task { await loadLibraries() } }
        case .library(let id):
            if let library = libraries.first(where: { $0.id == id }) {
                LibraryView(library: library, source: source)
            }
        case .downloads:
            DownloadsView(account: account, source: model.localSource(for: account), open: { open($0) })
        case .profile:
            ProfileView(account: account)
        }
    }

    /// Opens an item's page in the current place.
    private func open(_ item: Item) {
        paths[section, default: []].append(item)
    }

    static func icon(_ library: Item) -> String {
        let symbols = ["movies": "film.fill", "tvshows": "tv.fill"]
        return library.collectionType.flatMap { symbols[$0] } ?? "play.rectangle.fill"
    }

    #if DEBUG
    private func openDebugRoute() async {
        guard let route = model.debugRoute else { return }
        model.debugRoute = nil
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "search": section = .search
        case "profile": section = .profile
        case "downloads": section = .downloads
        case "libraries": section = .libraries
        case "library":
            for _ in 0..<50 where libraries.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            if sizeClass == .regular {
                section = .library(id)
            } else if let library = libraries.first(where: { $0.id == id }) {
                section = .libraries
                paths[.libraries] = [library]
            }
        case "item": if let item = try? await source.item(id) { paths[.home] = [item]; section = .home }
        case "play": if let item = try? await source.item(id) { playing = PlayRequest(item: item, startTicks: 0) }
        case "resume": if let item = try? await source.item(id) { playing = PlayRequest(item: item, startTicks: item.resumeTicks) }
        default: break
        }
    }
    #endif
}

/// The libraries as a list (the phone's third tab).
struct LibraryListView: View {
    let libraries: [Item]
    let loaded: Bool
    let source: any LibrarySource
    let retry: () -> Void

    var body: some View {
        Group {
            if !libraries.isEmpty {
                List(libraries) { library in
                    NavigationLink(value: library) {
                        Label { Text(verbatim: library.name) } icon: { Image(systemName: MainView.icon(library)) }
                    }
                }
            } else if loaded {
                ContentUnavailableView("No hay bibliotecas.", systemImage: "rectangle.stack")
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Bibliotecas")
    }
}
