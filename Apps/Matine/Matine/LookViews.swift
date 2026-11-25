import MatineKit
import SwiftUI

extension AvatarView {
    /// The avatar as a picture for places that only take images (the tab bar).
    @MainActor static func image(_ avatar: Avatar, size: CGFloat) -> Image? {
        let renderer = ImageRenderer(content: AvatarView(avatar: avatar, size: size))
        renderer.scale = 2
        return renderer.uiImage.map { Image(uiImage: $0).renderingMode(.original) }
    }
}

/// A server image that arrives without a pop: its BlurHash (a blurred
/// preview the server sends with the item) shows at once, and the real image
/// fades in over it. With no hash, a soft fill in the art's place.
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
                    image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                } else if case .failure = phase {
                    fallback()
                }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let blurHash, let image = BlurImage.image(blurHash) {
            image.resizable().aspectRatio(contentMode: .fill)
        } else {
            Rectangle().fill(.quaternary)
        }
    }
}

/// For round things (avatars, color dots): no platter; the focused one grows,
/// lifts on a shadow and gets a white ring. (The system's styles draw a
/// rounded square behind anything that isn't a plain image.)
struct CircleFocusStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Focusable(configuration: configuration) }

    private struct Focusable: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .overlay { Circle().strokeBorder(.white, lineWidth: focused ? 6 : 0) }
                .scaleEffect(configuration.isPressed ? 1.06 : focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.5 : 0), radius: focused ? 30 : 0, y: focused ? 20 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

/// A button whose label draws its own focus (reading `isFocused`).
struct BareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Choosing a look: a color, then one of a handful of robots ("Más robots"
/// draws new ones) or an animal. Every change saves at once.
struct AvatarEditor: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let done: () -> Void
    /// The robots on offer: the profile's own (if it wears one) first.
    @State private var robotSeeds: [UInt64] = []
    @Namespace private var namespace

    private var avatar: Avatar { model.current(account).avatar }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            AvatarView(avatar: avatar, size: 360)
                .animation(.easeOut(duration: 0.2), value: avatar)
            VStack(alignment: .leading, spacing: 36) {
                section("Color") {
                    HStack(spacing: 28) {
                        ForEach(ProfileColor.allCases, id: \.self) { color in
                            Button { set(Avatar(figure: avatar.figure, color: color)) } label: {
                                Circle().fill(Color(color.rgb)).frame(width: 80, height: 80)
                                    .overlay { if color == avatar.color { Image(systemName: "checkmark").font(.title2.bold()).foregroundStyle(.white) } }
                            }
                            .buttonStyle(CircleFocusStyle())
                            .accessibilityLabel(Text(Self.colorName(color)))
                            .accessibilityAddTraits(color == avatar.color ? .isSelected : [])
                            .prefersDefaultFocus(color == avatar.color, in: namespace)
                        }
                    }
                }
                section("Robots") {
                    HStack(spacing: 28) {
                        ForEach(robotSeeds, id: \.self) { seed in
                            let chosen = avatar.figure == .robot(seed: seed)
                            Button { set(Avatar(figure: .robot(seed: seed), color: avatar.color)) } label: {
                                AvatarView(avatar: Avatar(figure: .robot(seed: seed), color: avatar.color), size: 110)
                                    .overlay(alignment: .bottomTrailing) { if chosen { SelectedBadge() } }
                            }
                            .buttonStyle(CircleFocusStyle())
                            .accessibilityLabel(Text("Robot"))
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                        Button(action: drawRobots) {
                            Label("Más robots", systemImage: "dice.fill")
                        }
                    }
                }
                section("Animales") {
                    HStack(spacing: 24) {
                        ForEach(ProfileAnimal.allCases, id: \.self) { animal in
                            let chosen = avatar.figure == .animal(animal)
                            Button { set(Avatar(figure: .animal(animal), color: avatar.color)) } label: {
                                Image(systemName: animal.rawValue)
                                    .font(.system(size: 44))
                                    .foregroundStyle(.white)
                                    .frame(width: 96, height: 96)
                                    .background(Circle().fill(chosen ? Color(avatar.color.rgb) : .white.opacity(0.12)))
                                    .overlay(alignment: .bottomTrailing) { if chosen { SelectedBadge() } }
                            }
                            .buttonStyle(CircleFocusStyle())
                            .accessibilityLabel(Text(Self.animalName(animal)))
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                }
                Button("Listo", action: done)
                    .focusSection()
            }
        }
        .focusScope(namespace)
        .onAppear { if robotSeeds.isEmpty { drawRobots() } }
    }

    /// Five robots: the one worn (if any) and fresh ones.
    private func drawRobots() {
        var seeds: [UInt64] = []
        if case .robot(let worn) = avatar.figure { seeds.append(worn) }
        while seeds.count < 5 { seeds.append(.random(in: 0 ... .max)) }
        robotSeeds = seeds
    }

    private func set(_ avatar: Avatar) { model.setAvatar(avatar, for: account) }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.75)).accessibilityAddTraits(.isHeader)
            content()
        }
        .focusSection()
    }

    static func colorName(_ color: ProfileColor) -> LocalizedStringKey {
        switch color {
        case .tangerine: "Naranja"
        case .cherry: "Rojo"
        case .berry: "Fucsia"
        case .grape: "Morado"
        case .ocean: "Azul"
        case .teal: "Turquesa"
        case .forest: "Verde"
        case .cocoa: "Marrón"
        }
    }

    static func animalName(_ animal: ProfileAnimal) -> LocalizedStringKey {
        switch animal {
        case .cat: "Gato"
        case .dog: "Perro"
        case .hare: "Conejo"
        case .tortoise: "Tortuga"
        case .bird: "Colibrí"
        case .fish: "Pez"
        case .lizard: "Lagartija"
        case .ladybug: "Mariquita"
        case .teddy: "Osito"
        }
    }
}

/// The check on the chosen robot or animal, seen without focus.
private struct SelectedBadge: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 34))
            .foregroundStyle(.white, .green)
            .background(Circle().fill(.black.opacity(0.4)))
    }
}
