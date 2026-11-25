import MatineKit
import SwiftUI

/// A title's credits: a heading over one row of round photos, each with a
/// name and (for an actor) the character. Selecting one opens their page.
struct CastRow: View {
    let title: LocalizedStringKey
    let people: [Person]
    let client: JellyfinClient

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 36) {
                    ForEach(people) { person in
                        NavigationLink(value: Route.person(person)) { CastTile(person: person, client: client) }
                            .buttonStyle(.borderless)
                            .buttonBorderShape(.circle)
                    }
                }
                // Room for a focused tile's growth and shadow.
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

/// A round photo (their initials until, or without, one), name and character.
struct CastTile: View {
    let person: Person
    let client: JellyfinClient
    var diameter: CGFloat = 170

    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            PersonPhoto(person: person, client: client, diameter: diameter)
                .hoverEffect(.highlight)
            // Fixed room for two lines of name and two of character: every tile, and so the row, keeps one height.
            Text(verbatim: person.name)
                .font(.callout.weight(.medium))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
            Text(verbatim: person.role ?? " ")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.center)
        }
        .frame(width: diameter + 40)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(Text("Pulsa para ver sus títulos."))
    }

    private var label: Text {
        if let role = person.role { return Text("\(person.name), como \(role)") }
        return Text(verbatim: person.name)
    }
}

struct PersonPhoto: View {
    let person: Person
    let client: JellyfinClient
    let diameter: CGFloat

    var body: some View {
        Group {
            if let ref = person.image {
                RemoteImage(url: client.imageURL(ref, maxHeight: Int(diameter * 2)), blurHash: nil) { initials }
            } else {
                initials
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
    }

    private var initials: some View {
        ZStack {
            Circle().fill(.quaternary)
            Text(verbatim: person.initials).font(.system(size: diameter * 0.36, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// A person's page: who they are and what the library holds with them in it
/// (each series once, however many of its episodes they are in).
struct PersonView: View {
    let person: Person
    let client: JellyfinClient
    let account: Account
    @Environment(AppModel.self) private var model

    private enum Phase { case loading, loaded([Item]), failed }
    @State private var phase = Phase.loading

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 48) {
                HStack(spacing: 40) {
                    PersonPhoto(person: person, client: client, diameter: 240)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(verbatim: person.name).font(.system(size: 72, weight: .bold)).lineLimit(2)
                        if case .loaded(let items) = phase, !items.isEmpty {
                            Text("\(items.count) títulos en tu biblioteca").font(.callout.weight(.medium)).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                VStack(alignment: .leading, spacing: 24) {
                    switch phase {
                    case .loading:
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    case .failed:
                        RetryMessage("No se puede conectar con el servidor.") { Task { await load() } }
                    case .loaded(let items) where items.isEmpty:
                        Text("No hay nada con esta persona en tu biblioteca.").foregroundStyle(.white.opacity(0.75))
                    case .loaded(let items) where items.count <= 5:
                        // A lone tile or two belong in a row, as Home's do.
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: PosterCard.spacing) {
                                ForEach(items) { item in
                                    NavigationLink(value: Route.item(item)) { PosterCard(item: item, client: client) }
                                        .buttonStyle(.borderless)
                                }
                            }
                            .padding(.vertical, 24)
                        }
                        .scrollClipDisabled()
                        .focusSection()
                    case .loaded(let items):
                        ItemGrid(items: items, client: client).padding(.top, 16)
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.top, 80)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        .task { await load() }
    }

    private func load() async {
        phase = .loading
        do {
            let found = try await client.personItems(personId: person.id, userId: account.id)
            phase = .loaded(Item.grouped(byPerson: found))
        } catch {
            if !model.sessionExpired(error, userId: account.id) { phase = .failed }
        }
    }
}
