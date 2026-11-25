import MatineKit
import SwiftUI

/// Download, progress, delete, for one film, video or episode. The icon is
/// the state: an arrow to download, a ring while it comes, a check once it is
/// on the device (tap for "Eliminar descarga"), a warning to try again.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let account: Account
    /// A round bordered button beside Play (a detail page) or a plain icon (an episode row).
    var round = true
    @State private var confirmDelete = false

    private var status: DownloadsModel.Status? { model.downloads.status(item.id, userId: account.id) }

    var body: some View {
        if [.movie, .video, .episode].contains(item.kind), status != nil || !model.isOffline {
            control
                .accessibilityIdentifier("detail.download")
                .confirmationDialog("¿Eliminar la descarga de \(item.displayName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("Eliminar descarga", role: .destructive) { model.downloads.remove(item.id, userId: account.id) }
                }
        }
    }

    @ViewBuilder private var control: some View {
        switch status?.state {
        case nil:
            styled { model.download(item, account: account) } label: { icon("arrow.down.circle") }
                .accessibilityLabel(Text("Descargar"))
        case .downloading:
            styled { confirmDelete = true } label: { ring }
                .accessibilityLabel(Text("Descargando"))
                .accessibilityValue(Text(verbatim: status?.fraction.map { "\(Int($0 * 100)) %" } ?? ""))
                .accessibilityHint(Text("Toca para cancelar"))
        case .complete:
            styled { confirmDelete = true } label: { icon("checkmark.circle.fill") }
                .accessibilityLabel(Text("Descargado"))
                .accessibilityHint(Text("Toca para eliminar la descarga"))
        case .failed:
            styled { model.retryDownloads(account: account) } label: { icon("exclamationmark.arrow.circlepath") }
                .accessibilityLabel(Text("Reintentar la descarga"))
        }
    }

    private var ring: some View {
        ZStack {
            if let fraction = status?.fraction {
                ProgressView(value: fraction).progressViewStyle(.circular)
            } else {
                ProgressView()
            }
            Image(systemName: "stop.fill").font(.system(size: 8))
        }
        .frame(width: 28, height: 28)
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).frame(width: 28, height: 28)
    }

    @ViewBuilder private func styled(_ action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
        if round {
            Button(action: action, label: label).buttonStyle(.bordered).buttonBorderShape(.circle)
        } else {
            Button(action: action, label: label).buttonStyle(.borderless)
        }
    }
}

/// "Descargar temporada": every episode of the season shown, or (once they
/// all are) a way to remove them.
struct SeasonDownloadButton: View {
    @Environment(AppModel.self) private var model
    let seriesId: String
    let seasonId: String
    let episodes: [Item]
    let account: Account
    @State private var confirmDelete = false

    private var missing: Bool { episodes.contains { model.downloads.status($0.id, userId: account.id) == nil } }
    private var anyDownloaded: Bool { episodes.contains { model.downloads.status($0.id, userId: account.id) != nil } }

    var body: some View {
        if !episodes.isEmpty, !model.isOffline {
            Group {
                if missing {
                    Button { model.downloadSeason(seriesId: seriesId, seasonId: seasonId, episodes: episodes, account: account) } label: {
                        Label("Descargar temporada", systemImage: "arrow.down.circle")
                    }
                } else if anyDownloaded {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Eliminar descargas de la temporada", systemImage: "trash")
                    }
                }
            }
            .buttonStyle(.bordered)
            .confirmationDialog("¿Eliminar las descargas de esta temporada?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Eliminar descargas", role: .destructive) {
                    for episode in episodes { model.downloads.remove(episode.id, userId: account.id) }
                }
            }
            .accessibilityIdentifier("detail.downloadSeason")
        }
    }
}

/// Descargas: the mirror. The same shelves and libraries as online, but
/// only what is on this device; what is still coming (or failed) is listed first.
struct DownloadsView: View {
    @Environment(\.locale) private var locale
    @Environment(AppModel.self) private var model
    let account: Account
    let source: LocalLibrarySource
    let open: (Item) -> Void

    @State private var content: HomeContent?
    @State private var pending: [DownloadedItem] = []
    @State private var bytes: Int64 = 0
    @State private var confirmDeleteAll = false

    private var store: DownloadStore { source.store }

    var body: some View {
        Group {
            if let content {
                if content.libraries.isEmpty, pending.isEmpty {
                    ContentUnavailableView("No hay descargas.", systemImage: "arrow.down.circle", description: Text("Descarga películas y episodios para verlos sin conexión."))
                } else {
                    list(content)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Descargas")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.downloads.changes + model.playbackEndedCount) { await reload() }
        .confirmationDialog("¿Eliminar todas las descargas de \(model.current(account).shownName)?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Eliminar todas", role: .destructive) { model.downloads.removeAll(userId: account.id) }
        }
    }

    private func list(_ content: HomeContent) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !pending.isEmpty { inFlight }
                if !content.libraries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bibliotecas").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        ForEach(content.libraries) { library in
                            NavigationLink(value: library) {
                                Label { Text(verbatim: library.name) } icon: { Image(systemName: MainView.icon(library)) }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                ForEach(content.rows) { row in
                    Shelf(title: HomeView.title(row.kind), items: row.items, source: source, wide: row.kind == .continueWatching, open: open)
                }
                footer
            }
            .padding(.vertical)
        }
        .refreshable { await reload() }
    }

    private var inFlight: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("En curso").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            ForEach(pending, id: \.item.id) { entry in
                HStack(spacing: 12) {
                    Text(verbatim: entry.item.tileCaption(AppLanguage(locale: locale))).lineLimit(2)
                    Spacer(minLength: 0)
                    if let status = model.downloads.status(entry.item.id, userId: account.id), status.state == .downloading {
                        if let fraction = status.fraction { ProgressView(value: fraction).frame(width: 60) } else { ProgressView() }
                    } else {
                        Button("Reintentar") { model.retryDownloads(account: account) }.buttonStyle(.bordered)
                    }
                    Button { model.downloads.remove(entry.item.id, userId: account.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Cancelar"))
                }
            }
        }
        .padding(.horizontal)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Las descargas ocupan \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) en este dispositivo.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Eliminar todas las descargas", role: .destructive) { confirmDeleteAll = true }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }

    private func reload() async {
        content = try? await source.home()
        let store = store
        pending = store.entries().filter { $0.state != .complete }
        // Walks the folder: off the main thread.
        bytes = await Task.detached { store.bytesUsed() }.value
    }
}
