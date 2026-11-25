import MatineKit
import SwiftUI

/// A library's films or series as a grid of posters, a page at a time.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    let library: Item
    let source: any LibrarySource

    @State private var sort: LibrarySort = .title
    @State private var listing = LibraryListing(sort: .title)
    @State private var loading = false
    @State private var failed = false

    private static let pageSize = 60

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 108, maximum: 220), spacing: 14, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            if failed, listing.items.isEmpty {
                RetryMessage("No se puede conectar con el servidor.") { Task { await loadMore() } }
            } else if listing.items.isEmpty, listing.exhausted {
                ContentUnavailableView("Esta biblioteca está vacía.", systemImage: "film.stack")
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(listing.items) { item in
                        NavigationLink(value: item) { cell(item) }
                            .buttonStyle(.plain)
                            .onAppear { if item.id == listing.items.last?.id { Task { await loadMore() } } }
                    }
                }
                .padding(.horizontal)
                if loading { ProgressView().padding() }
            }
        }
        .navigationTitle(Text(verbatim: library.name))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Ordenar", selection: $sort) {
                        Text("Título").tag(LibrarySort.title)
                        Text("Añadido").tag(LibrarySort.dateAdded)
                    }
                } label: {
                    Label("Ordenar", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .task(id: sort) {
            listing.reset(sort: sort)
            failed = false
            await loadMore()
        }
        .refreshable {
            listing.reset(sort: sort)
            await loadMore()
        }
        // After a playback (or a change of connection) the progress marks may have moved:
        // read what is listed again and swap it in, so the grid keeps its scroll position.
        .onChange(of: model.playbackEndedCount) { Task { await refreshInPlace() } }
    }

    private func cell(_ item: Item) -> some View {
        GeometryReader { proxy in
            PosterTile(item: item, source: source, width: proxy.size.width, caption: item.displayName)
        }
        // A poster's height is 1.5 × its width, plus two lines of caption.
        .aspectRatio(2 / 3.55, contentMode: .fit)
    }

    private func refreshInPlace() async {
        guard !listing.items.isEmpty else {
            listing.reset(sort: sort)
            await loadMore()
            return
        }
        let asked = sort
        do {
            let page = try await source.libraryPage(
                libraryId: library.id, sort: asked, start: 0, limit: max(Self.pageSize, listing.items.count), countTotal: true
            )
            listing.refresh(with: page, for: asked)
        } catch {
            // The list on screen is still good; only an ended session matters.
            _ = model.sessionExpired(error, userId: source.userId)
        }
    }

    private func loadMore() async {
        // A second call for the same page is harmless: `accept` ignores a page
        // that doesn't continue where the list ends.
        guard let start = listing.nextStart else { return }
        let asked = sort
        loading = true
        defer { loading = false }
        do {
            let page = try await source.libraryPage(
                libraryId: library.id, sort: asked, start: start, limit: Self.pageSize, countTotal: start == 0
            )
            listing.accept(page, for: asked)
            failed = false
        } catch {
            if !model.sessionExpired(error, userId: source.userId) { failed = true }
        }
    }
}
