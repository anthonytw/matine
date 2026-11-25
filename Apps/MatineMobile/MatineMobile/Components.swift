import MatineKit
import SwiftUI

// MARK: Images

/// A server image that arrives without a pop: its BlurHash shows at once and
/// the real image fades in over it.
struct RemoteImage<Fallback: View>: View {
    let url: URL?
    let blurHash: String?
    @ViewBuilder var fallback: () -> Fallback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.25))) { phase in
            ZStack {
                preview
                if let image = phase.image {
                    Self.fill(image).transition(.opacity)
                } else if case .failure = phase {
                    fallback()
                }
            }
        }
    }

    /// An image filling the space it is given, never growing it: the clear
    /// base takes the proposed size and the picture is cropped to it.
    private static func fill(_ image: Image) -> some View {
        Color.clear.overlay { image.resizable().scaledToFill() }.clipped()
    }

    @ViewBuilder private var preview: some View {
        if let blurHash, let image = BlurImage.image(blurHash) {
            Self.fill(image)
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

extension Item {
    /// The BlurHash that goes with an image (by its type and tag).
    func blurHash(for ref: ImageRef) -> String? {
        imageBlurHashes?[ref.kind.rawValue]?[ref.tag]
    }
}

/// An item's picture at a fixed aspect ratio, from whichever `ImageRef` is chosen.
struct ArtView: View {
    let item: Item
    let ref: ImageRef?
    let source: any LibrarySource
    let aspect: CGFloat
    /// Pixels asked of the server (the height); a little over what is shown.
    var maxHeight = 480

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay {
                if let ref {
                    RemoteImage(url: source.imageURL(ref, maxHeight: maxHeight), blurHash: item.blurHash(for: ref)) { TitleCard(item: item) }
                } else {
                    TitleCard(item: item)
                }
            }
            .clipped()
    }
}

/// A tile with no picture: the title on a soft fill.
struct TitleCard: View {
    let item: Item

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Text(verbatim: item.displayName)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)
                .padding(8)
                .minimumScaleFactor(0.7)
        }
    }
}

/// A thin bar along the bottom edge: how far through an item you are.
struct WatchedBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.55))
                Rectangle().fill(Color.accentColor).frame(width: proxy.size.width * percent / 100)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: Tiles

/// One poster (or wide still) with its caption, as a button-sized tile.
struct PosterTile: View {
    @Environment(\.locale) private var locale
    let item: Item
    let source: any LibrarySource
    var width: CGFloat = 120
    var caption: String?
    /// A smaller line under the caption (Search: an episode's series and number).
    var subtitle: String?
    /// Wide tiles for episodes and stills; posters otherwise.
    var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ArtView(item: item, ref: wide ? (item.wideImage ?? item.posterImage) : item.posterImage, source: source, aspect: wide ? 16 / 9 : 2 / 3)
                .frame(width: width)
                .overlay(alignment: .bottom) { if let percent = item.progressPercent { WatchedBar(percent: percent) } }
                .overlay(alignment: .topTrailing) { if item.userData?.played == true { watchedBadge } }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: caption ?? item.tileCaption(AppLanguage(locale: locale)))
                    .font(.caption)
                    .foregroundStyle(subtitle == nil ? .secondary : .primary)
                    .lineLimit(subtitle == nil ? 2 : 3)
                if let subtitle {
                    Text(verbatim: subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(width: width, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: [caption ?? item.tileCaption(AppLanguage(locale: locale)), subtitle].compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(statusText)
    }

    private var watchedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.callout)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, Color.accentColor)
            .padding(5)
    }

    private var statusText: Text {
        if item.userData?.played == true { return Text("visto") }
        if item.progressPercent != nil { return Text("empezado") }
        return Text(verbatim: "")
    }
}

/// A titled shelf of tiles that scrolls sideways.
struct Shelf: View {
    @Environment(\.locale) private var locale
    let title: Text
    let items: [Item]
    let source: any LibrarySource
    var wide = false
    /// Search's captions: the item's own name, then where it is from
    /// (`Item.searchSubtitle`), instead of `tileCaption`.
    var searchCaptions = false
    let open: (Item) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var tileWidth: CGFloat {
        let regular = sizeClass == .regular
        return wide ? (regular ? 260 : 200) : (regular ? 150 : 120)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title.font(.title3.bold()).padding(.horizontal).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            PosterTile(
                                item: item, source: source, width: tileWidth,
                                caption: searchCaptions ? item.displayName : nil, subtitle: searchCaptions ? item.searchSubtitle(AppLanguage(locale: locale)) : nil,
                                wide: wide || item.hasWidePoster
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .scrollIndicators(.hidden)
        }
    }
}

// MARK: Messages

/// A failure with a way to try again.
struct RetryMessage: View {
    let message: LocalizedStringKey
    let retry: () -> Void

    init(_ message: LocalizedStringKey, retry: @escaping () -> Void) {
        self.message = message
        self.retry = retry
    }

    var body: some View {
        ContentUnavailableView {
            Label(message, systemImage: "wifi.exclamationmark")
        } actions: {
            Button("Reintentar", action: retry).buttonStyle(.borderedProminent)
        }
    }
}

extension Item {
    /// "2019 · 1 h 42 min": the line of facts under a title.
    var facts: String {
        var parts: [String] = []
        if let productionYear { parts.append(String(productionYear)) }
        if let runTimeTicks, runTimeTicks > 0 {
            let minutes = Int((Ticks.seconds(runTimeTicks) / 60).rounded())
            parts.append(minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min")
        }
        return parts.joined(separator: " · ")
    }
}
