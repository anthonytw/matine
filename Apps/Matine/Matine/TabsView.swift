import MatineKit
import SwiftUI

/// The sidebar, the way tvOS apps are laid out now: Inicio, Buscar, one
/// entry per library, and the profile (its avatar) for settings. Each tab keeps
/// its own navigation stack; the player covers them all.
struct MainTabs: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let client: JellyfinClient

    enum Key: Hashable {
        case home, library(String), search, profile
    }

    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: Key = .home
    @State private var paths: [Key: [Route]] = [:]
    /// Filled by Home's first load (the same call that builds its rows).
    @State private var libraries: [Item] = []
    @State private var playing: PlayRequest?
    /// A Play from the phone that arrived while another player was up.
    @State private var queuedPlay: PlayRequest?
    @State private var avatarIcon: Image?
    /// Phones announcing a sign-in code nearby (see NearbyJoinSheet).
    @State private var nearby = NearbyCenter()
    @AppStorage(NearbyCenter.enabledKey) private var nearbyEnabled = true

    var body: some View {
        TabView(selection: $tab) {
            Tab("Inicio", systemImage: "house.fill", value: Key.home) {
                stack(.home) {
                    HomeView(account: account, client: client, libraries: $libraries, playing: $playing) { tab = .profile }
                }
            }
            // Kids who can't type yet get no keyboard to stare at.
            if !model.current(account).isKid {
                Tab(value: Key.search, role: .search) {
                    stack(.search) {
                        SearchView(client: client, account: account) { paths[.search, default: []].append(.item($0)) }
                    }
                }
            }
            TabSection("Bibliotecas") {
                ForEach(libraries) { library in
                    Tab(library.name, systemImage: Self.icon(library), value: Key.library(library.id)) {
                        stack(.library(library.id)) { LibraryView(library: library, client: client, userId: account.id) }
                    }
                }
            }
            Tab(value: Key.profile) {
                SettingsView(account: account)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.ignoresSafeArea())
            } label: {
                Label {
                    Text(verbatim: model.current(account).shownName)
                } icon: {
                    avatarIcon ?? Image(systemName: "person.crop.circle")
                }
            }
        }
        // A sidebar (Menu or left from the content opens it), as the TV app
        // has: room for any number of libraries, with the profile on it too.
        .tabViewStyle(.sidebarAdaptable)
        .fullScreenCover(item: $playing, onDismiss: presentQueuedPlay) { request in
            PlayerView(item: request.item, source: ServerLibrarySource(client: client, userId: account.id), startTicks: request.startTicks, language: model.current(account).language)
        }
        // The phone's remote control, while this profile is open and the app is
        // in front (tvOS suspends it otherwise): the listener stops with the
        // task and starts again when the app is active.
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            for await event in RemoteListener.events(client: client) {
                if case .command(let command) = event { await handle(command) }
            }
        }
        // Phones showing a sign-in code announce it on the network. Listened for
        // only while this profile is open, the app is in front and the person
        // hasn't switched it off. An announcement only ever offers a choice:
        // nothing is approved without a profile picked, a confirm or a PIN.
        .task(id: scenePhase == .active && nearbyEnabled) {
            guard scenePhase == .active, nearbyEnabled else {
                nearby.close()
                return
            }
            for await joins in NearbyBrowser.joins() {
                nearby.hear(joins)
                nearby.present(allowed: nearbyAllowed)
            }
        }
        // Never over a player, the profile tab (PIN pads, the code pad) or
        // the search keyboard: only while browsing Home, a library or a page.
        .onChange(of: nearbyAllowed) {
            if nearbyAllowed { nearby.present(allowed: true) } else { nearby.close() }
        }
        // Menu on the sheet is "Ahora no".
        .sheet(isPresented: Binding(get: { nearby.presented }, set: { if !$0 { nearby.declineAll() } })) {
            NearbyJoinSheet(center: nearby, generation: nearby.generation, open: account)
                // Menu mid-approval would cancel it half done: the approval finishes.
                .interactiveDismissDisabled(nearby.busy)
        }
        .task(id: model.current(account).avatar) { avatarIcon = AvatarView.image(model.current(account).avatar, size: 40) }
        .task {
            await openPendingLink()
            #if DEBUG
            await openDebugRoute()
            #endif
        }
        // A Top Shelf link while this profile is already open.
        .onChange(of: model.pendingLink) { Task { await openPendingLink() } }
        // Back after hours away (the next morning): Home, at its top.
        .onChange(of: model.returnedAfterLongAwayCount) {
            paths = [:]
            tab = .home
        }
    }

    /// What the phone asked for. Play opens the player on that item for this
    /// profile only (`client.item` with this profile's own user fails for
    /// anything it may not see); the rest steer the open player. A series
    /// plays its own next episode, and nothing here ever queues another.
    private func handle(_ command: RemoteCommand) async {
        guard case .play = command else {
            model.deliver(command)
            return
        }
        guard let target = await client.remotePlayTarget(command, userId: account.id), !Task.isCancelled else { return }
        // A sheet asking about a phone never blocks a Play: it counts as "Ahora no".
        if nearby.presented {
            // (A no-op while an approval is going through: wait for it to close.)
            for _ in 0..<60 where nearby.presented {
                nearby.declineAll()
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
        let request = PlayRequest(item: target.item, startTicks: target.startTicks)
        let appearances = model.playerAppearances
        if playing != nil {
            // The old player goes first; the cover's onDismiss presents this one.
            queuedPlay = request
            playing = nil
        } else {
            playing = request
        }
        // Something else on screen (a confirmation dialog) can keep a player
        // from appearing: then forget the request rather than leave `playing`
        // set with nothing showing.
        // Generous: an old player's dismissal plus the new presentation on a
        // busy main thread must not be mistaken for "never appeared".
        for _ in 0..<60 where model.playerAppearances == appearances {
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
        }
        if model.playerAppearances == appearances {
            queuedPlay = nil
            playing = nil
        }
    }

    private var nearbyAllowed: Bool { playing == nil && tab != .profile && tab != .search }

    private func presentQueuedPlay() {
        guard let next = queuedPlay else { return }
        queuedPlay = nil
        // A player closed for a relock (back past the grace): the profile locks, nothing new opens.
        guard !model.playerMustClose else { return }
        playing = next
    }

    private func stack(_ key: Key, @ViewBuilder root: () -> some View) -> some View {
        NavigationStack(path: Binding(get: { paths[key] ?? [] }, set: { paths[key] = $0 })) {
            root()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.ignoresSafeArea())
                .navigationDestination(for: Route.self) { route in
                switch route {
                case .item(let item): DetailView(item: item, client: client, account: account, playing: $playing)
                case .person(let person): PersonView(person: person, client: client, account: account)
                }
            }
        }
    }

    private static func icon(_ library: Item) -> String {
        let symbols = ["movies": "film.fill", "tvshows": "tv.fill"]
        return library.collectionType.flatMap { symbols[$0] } ?? "play.rectangle.fill"
    }

    /// Opens a Top Shelf tile: its page, or straight into playback (Play on
    /// the remote), resuming where it was left.
    private func openPendingLink() async {
        guard let link = model.pendingLink else { return }
        model.pendingLink = nil
        // A link for another profile never waits around to fire later.
        guard link.accountId == account.id else { return }
        guard let item = try? await client.item(link.itemId, userId: account.id) else { return }
        switch link {
        case .item:
            tab = .home
            paths[.home] = [.item(item)]
        case .play:
            playing = PlayRequest(item: item, startTicks: item.resumeTicks)
        }
    }

    #if DEBUG
    private func openDebugRoute() async {
        guard let route = model.debugRoute else { return }
        model.debugRoute = nil
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "search": tab = .search
        case "settings": tab = .profile
        case "manage":
            model.debugOpensManage = true
            tab = .profile
        case "library":
            // The library tabs arrive with Home's first load.
            for _ in 0..<50 where !libraries.contains(where: { $0.id == id }) { try? await Task.sleep(for: .milliseconds(100)) }
            tab = .library(id)
        case "item": if let item = try? await client.item(id, userId: account.id) { paths[.home] = [.item(item)] }
        case "play": if let item = try? await client.item(id, userId: account.id) { playing = PlayRequest(item: item, startTicks: 0) }
        case "resume": if let item = try? await client.item(id, userId: account.id) { playing = PlayRequest(item: item, startTicks: item.resumeTicks) }
        default: break
        }
    }
    #endif
}
