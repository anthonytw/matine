import MatineKit
import SwiftUI

/// ¿Quién mira? One tile per saved profile; a PIN shows as a lock.
struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 180), spacing: 20, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                Text("¿Quién mira?").font(.largeTitle.bold()).padding(.top, 48)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(model.accounts) { account in
                        Button { model.choose(account) } label: { tile(account) }
                            .buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(model.hasPin(account) ? Text("\(account.shownName), con PIN") : Text(verbatim: account.shownName))
                    }
                    Button { model.addProfile() } label: { addTile }
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: 640)
                .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func tile(_ account: Account) -> some View {
        VStack(spacing: 10) {
            AvatarView(avatar: account.avatar, size: 110)
                .overlay(alignment: .bottomTrailing) {
                    if model.hasPin(account) {
                        Image(systemName: "lock.fill").font(.footnote).padding(7)
                            .background(.regularMaterial, in: Circle())
                    }
                }
            Text(verbatim: account.shownName).font(.headline).lineLimit(1)
            if account.isKid { Text("Infantil").font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
    }

    private var addTile: some View {
        VStack(spacing: 10) {
            Image(systemName: "plus").font(.largeTitle)
                .frame(width: 110, height: 110)
                .background(.quaternary, in: Circle())
            Text("Añadir perfil").font(.headline).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
