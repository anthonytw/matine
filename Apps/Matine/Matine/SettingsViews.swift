import MatineKit
import SwiftUI

/// The profile tab, led by the other profiles to switch to. A kid sees their avatar; a
/// grown-up also gets language, PIN, the household's profiles and sign-out.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    /// The profile as the tabs captured it; read through `model.current` so a
    /// change made here (language, PIN, look) shows at once.
    let account: Account

    /// What a verified PIN unlocks next.
    enum Next { case changePin, removePin, manage, newPin, signOut, remove, approve }
    enum Mode {
        case menu, avatar, newPin, confirmPin(String), manage
        /// Typing another device's Quick Connect code, to sign it in as this profile.
        case approve
        /// This profile's own PIN.
        case verify(Next)
        /// Any grown-up's PIN: a profile without a PIN of its own, in a house
        /// with kids, can't prove it's a grown-up's.
        case grownUp(Next)
    }
    @State private var mode: Mode = .menu
    @Environment(\.scenePhase) private var scenePhase
    @State private var pinMessage: Text?
    /// The menu's result line ("PIN guardado.", or what went wrong).
    @State private var menuMessage: Text?
    @State private var confirmingSignOut = false
    @State private var confirmingRemove = false
    /// An approval in flight: the pad takes no second code meanwhile.
    @State private var approving = false
    @Namespace private var namespace
    @AppStorage(NearbyCenter.enabledKey) private var nearbyAlerts = true

    private var profile: Account { model.current(account) }

    var body: some View {
        content
            #if DEBUG
            .onAppear {
                if model.debugOpensManage {
                    model.debugOpensManage = false
                    mode = .manage
                }
            }
            #endif
            // Leaving the tab ends a verified step: coming back starts at the
            // menu, so a parent who walks away leaves nothing unlocked.
            .onDisappear {
                mode = .menu
                pinMessage = nil
                confirmingSignOut = false
                confirmingRemove = false
            }
            // So does the screensaver or leaving the app: a grown-up's PIN
            // typed on a kid's profile must not leave the code pad open for
            // whoever picks up the remote next.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    mode = .menu
                    pinMessage = nil
                    // A confirmation a grown-up's PIN opened is not left up for the next hand.
                    confirmingSignOut = false
                    confirmingRemove = false
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .menu:
            ScrollView {
                if profile.isKid { kidMenu } else { menu }
            }
            .scrollClipDisabled()
        case .avatar:
            back(AvatarEditor(account: profile) { mode = .menu }.padding(60).padding(.top, SidebarRoom.top - 60))
        case .verify(let next):
            back(PinPad(title: "PIN actual", message: pinMessage) { pin in
                if let refusal = PinRefusal(model.checkPin(pin, for: profile)) {
                    pinMessage = refusal.text
                } else {
                    proceed(to: next)
                }
            })
        case .grownUp(let next):
            back(PinPad(title: "PIN de un adulto", message: pinMessage) { pin in
                if let refusal = PinRefusal(model.checkAdultPin(pin)) {
                    pinMessage = refusal.text
                } else {
                    proceed(to: next)
                }
            })
        case .newPin:
            back(PinPad(title: "Nuevo PIN", message: pinMessage) { mode = .confirmPin($0) })
        case .confirmPin(let first):
            back(PinPad(title: "Repite el PIN", message: pinMessage) { second in
                guard second == first else {
                    pinMessage = Text("Los PIN no coinciden.").foregroundStyle(.red)
                    mode = .newPin
                    return
                }
                finish((try? model.setPin(second, for: profile)) != nil ? Text("PIN guardado.") : Text("No se ha podido guardar el PIN.").foregroundStyle(.red))
            })
        case .manage:
            back(ScrollView { ManageProfilesView().padding(60).padding(.top, SidebarRoom.top - 60) }.scrollClipDisabled())
        case .approve:
            back(VStack(spacing: 24) {
                PinPad(title: "Código del otro dispositivo", message: pinMessage, length: 6) { code in
                    guard !approving else { return }
                    Task { await approve(code) }
                }
                Text("El iPhone, el iPad u otro aparato con Matiné muestra un código de 6 cifras en «Entrar con un código». Entrará como \(profile.shownName).")
                    .font(.callout).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center).frame(maxWidth: 1000)
            })
        }
    }

    /// Signs another device in as this profile (Jellyfin's Quick Connect).
    private func approve(_ code: String) async {
        approving = true
        defer { approving = false }
        pinMessage = Text("Aprobando…")
        do {
            try await model.profiles.approveQuickConnect(code: code, as: profile)
            // Left the screen meanwhile: nothing to show, and nowhere to show it.
            guard case .approve = mode else { return }
            finish(Text("Aprobado. El otro dispositivo entrará en unos segundos."))
        } catch where { if case .approve = mode { false } else { true } }() {
            return
        } catch QuickConnectError.disabled {
            pinMessage = Text("Este servidor no admite el acceso con código.").foregroundStyle(.red)
        } catch QuickConnectError.invalidCode {
            pinMessage = Text("Ese código no existe o ha caducado.").foregroundStyle(.red)
        } catch JellyfinError.unauthorized {
            _ = model.sessionExpired(JellyfinError.unauthorized, userId: profile.id)
        } catch {
            pinMessage = Text("No se ha podido aprobar el código.").foregroundStyle(.red)
        }
    }

    /// Approving hands out a long-lived session: a profile with a PIN asks
    /// for it again; one without, in a house with kids, a grown-up's.
    private func requestApprove() {
        switch model.rules.approveGate(for: profile) {
        case .ownPin: mode = .verify(.approve)
        case .grownUpPin: mode = .grownUp(.approve)
        case .open: mode = .approve
        case .notAllowed: break
        }
    }

    private func proceed(to next: Next) {
        pinMessage = nil
        switch next {
        case .changePin, .newPin: mode = .newPin
        case .manage: mode = .manage
        case .removePin:
            do {
                try model.removePin(for: profile)
                finish(Text("PIN quitado."))
            } catch AppModel.ChangeProblem.refused(let refusal) {
                finish(Text(RefusalText.key(refusal)).foregroundStyle(.red))
            } catch {
                finish(Text("No se ha podido guardar el PIN.").foregroundStyle(.red))
            }
        case .signOut:
            mode = .menu
            confirmingSignOut = true
        case .remove:
            mode = .menu
            confirmingRemove = true
        case .approve:
            mode = .approve
        }
    }

    /// A step below the menu: Back returns to the menu, not to the sidebar.
    private func back(_ step: some View) -> some View {
        step.onExitCommand {
            pinMessage = nil
            mode = .menu
        }
    }

    private func finish(_ message: Text) {
        pinMessage = nil
        menuMessage = message
        mode = .menu
    }

    // MARK: Menus

    /// The house's other profiles, first on the tab: the avatar in the
    /// sidebar is mostly reached to switch, so switching is one click (a
    /// profile with a PIN asks for it). Focus starts here.
    @ViewBuilder private var switcher: some View {
        let others = model.accounts.filter { $0.id != profile.id }
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Cambiar a").font(.headline).foregroundStyle(.white.opacity(0.75)).accessibilityAddTraits(.isHeader)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, account in
                            Button { model.choose(account) } label: {
                                ProfileTile(name: account.shownName, locked: model.hasPin(account)) {
                                    AvatarView(avatar: account.avatar, size: 120)
                                }
                            }
                            .buttonStyle(BareButtonStyle())
                            .prefersDefaultFocus(index == 0, in: namespace)
                            .accessibilityLabel(Text(model.hasPin(account) ? "Cambiar a \(account.shownName), con PIN" : "Cambiar a \(account.shownName)"))
                        }
                    }
                }
                .scrollClipDisabled()
            }
            .padding(.leading, -24) // the tiles' own padding: the circles line up with the text below
            .focusSection()
        }
    }

    private var header: some View {
        HStack(spacing: 40) {
            AvatarView(avatar: profile.avatar, size: 180)
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: profile.shownName).font(.title2.bold())
                Button { mode = .avatar } label: { Label("Cambiar avatar", systemImage: "paintpalette.fill") }
                    .prefersDefaultFocus(model.accounts.count < 2, in: namespace)
            }
        }
        .focusSection()
    }

    private var kidMenu: some View {
        VStack(alignment: .leading, spacing: 48) {
            switcher
            header
            if let menuMessage { menuMessage }
            section("Otros dispositivos") {
                if model.rules.approveGate(for: profile) == .notAllowed {
                    Text("Un adulto con PIN puede aprobar dispositivos para este perfil.")
                        .font(.callout).foregroundStyle(.white.opacity(0.75))
                } else {
                    Button { requestApprove() } label: { Label("Aprobar otro dispositivo", systemImage: "iphone.and.arrow.forward") }
                    Text("Para entrar en Matiné en un iPhone o iPad sin escribir la contraseña. Hace falta el PIN de un adulto.")
                        .font(.callout).foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .padding(60)
        .padding(.top, SidebarRoom.top - 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusScope(namespace)
    }

    /// Plain system buttons (their focused text turns dark, unlike a tvOS
    /// Form row's), in sections with room around them.
    private var menu: some View {
        VStack(alignment: .leading, spacing: 40) {
            switcher
            header
            if let menuMessage { menuMessage }
            section("Otros dispositivos") {
                Button { requestApprove() } label: { Label("Aprobar otro dispositivo", systemImage: "iphone.and.arrow.forward") }
                Text("Para entrar en Matiné en un iPhone o iPad sin escribir la contraseña.")
                    .font(.callout).foregroundStyle(.white.opacity(0.75))
                Toggle("Avisar cuando un dispositivo quiera entrar", isOn: $nearbyAlerts)
            }
            section("Idioma") {
                HStack(spacing: 24) {
                    languageButton(.spanish, "Español")
                    languageButton(.english, "English")
                }
            }
            section("PIN") {
                if model.rules.unguardedAdults.contains(where: { $0.id == profile.id }) {
                    Text("Pon un PIN para que los niños no puedan entrar en este perfil.").foregroundStyle(.yellow)
                }
                HStack(spacing: 24) {
                    if model.hasPin(profile) {
                        Button("Cambiar el PIN") { mode = .verify(.changePin) }
                        Button("Quitar el PIN") {
                            if let refusal = model.rules.refusal(removingPinOf: profile) {
                                menuMessage = Text(RefusalText.key(refusal)).foregroundStyle(.red)
                            } else {
                                mode = .verify(.removePin)
                            }
                        }
                    } else {
                        Button("Poner un PIN", action: setFirstPin)
                    }
                }
            }
            section("Perfiles de la casa") {
                if model.hasPin(profile) {
                    Button { mode = .verify(.manage) } label: { Label("Gestionar perfiles", systemImage: "person.3.fill") }
                } else {
                    Text("Con un PIN en este perfil podrás poner nombres y crear perfiles infantiles.")
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            section("Perfil") {
                HStack(spacing: 24) {
                    Button("Cambiar de perfil") { model.screen = .picker }
                    Button("Cerrar sesión", role: .destructive) { signOut(everywhere: false) }
                    Button("Quitar de todos los dispositivos", role: .destructive) { signOut(everywhere: true) }
                }
            }
        }
        .padding(60)
        .padding(.top, SidebarRoom.top - 60)
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusScope(namespace)
        .confirmationDialog("¿Cerrar la sesión de \(profile.shownName)?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) {
                Task { await model.signOut(profile) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Para volver a entrar hará falta la contraseña, o un código aprobado por otro de tus dispositivos donde este perfil siga abierto.")
        }
        .confirmationDialog("¿Quitar a \(profile.shownName) de todos los dispositivos?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Quitar de todos los dispositivos", role: .destructive) {
                Task { await model.removeEverywhere(profile) }
            }
            Button("Cancelar", role: .cancel) {}
        }
    }

    /// A first PIN: in a house with kids, a grown-up's PIN first, or a kid
    /// who walked into this profile could make theirs the household's key.
    private func setFirstPin() {
        mode = model.rules.needsGrownUp(toChange: profile) ? .grownUp(.newPin) : .newPin
    }

    private func signOut(everywhere: Bool) {
        // Signing out here leaves the profile in the household; only removing it is refused by the house rules.
        if everywhere, let refusal = model.signOutRefusal(profile) {
            menuMessage = Text(RefusalText.key(refusal)).foregroundStyle(.red)
        } else if model.rules.needsGrownUp(toChange: profile) {
            mode = .grownUp(everywhere ? .remove : .signOut)
        } else if everywhere {
            confirmingRemove = true
        } else {
            confirmingSignOut = true
        }
    }

    private func section(_ title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.75)).accessibilityAddTraits(.isHeader)
            content()
        }
        .focusSection()
    }

    private func languageButton(_ language: AppLanguage, _ name: String) -> some View {
        Button { model.setLanguage(language, for: profile) } label: {
            if profile.language == language { Label(name, systemImage: "checkmark") } else { Text(verbatim: name) }
        }
        .accessibilityAddTraits(profile.language == language ? .isSelected : [])
    }
}

/// What the house rules say when they refuse a change.
enum RefusalText {
    static func key(_ refusal: HouseRules.Refusal) -> LocalizedStringKey {
        switch refusal {
        case .lastAdult: "Tiene que quedar al menos un perfil adulto."
        case .needsAdultPin: "Con perfiles infantiles, al menos un perfil adulto necesita un PIN."
        }
    }
}

/// Every profile on this Apple TV: the name the picker shows, and adult or
/// kid. Reached only through a grown-up's PIN.
struct ManageProfilesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: String?
    @State private var typed = ""
    @State private var problems: [String: AppModel.ChangeProblem] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 48) {
            Text("Perfiles de la casa").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            ForEach(model.accounts) { account in
                row(account)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ account: Account) -> some View {
        HStack(alignment: .top, spacing: 40) {
            AvatarView(avatar: account.avatar, size: 120)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Text(verbatim: account.shownName).font(.title3.bold())
                    if account.shownName != account.name {
                        Text(verbatim: account.name).foregroundStyle(.white.opacity(0.6))
                    }
                }
                if editing == account.id {
                    // Cambiar nombre opens the keyboard at once; Done saves.
                    FormField(label: "Nombre en el selector", text: $typed, editsAtOnce: true) {
                        model.setDisplayName(typed, for: account)
                        editing = nil
                    }
                    .frame(maxWidth: 700)
                    HStack(spacing: 24) {
                        Button("Guardar") {
                            model.setDisplayName(typed, for: account)
                            editing = nil
                        }
                        Button("Cancelar") { editing = nil }
                    }
                } else {
                    HStack(spacing: 24) {
                        Button {
                            typed = account.displayName ?? ""
                            editing = account.id
                        } label: { Label("Cambiar nombre", systemImage: "pencil") }
                        roleButton(account, .adult, "Adulto")
                        roleButton(account, .kid, "Infantil")
                    }
                }
                switch problems[account.id] {
                case .refused(let refusal): Text(RefusalText.key(refusal)).foregroundStyle(.red)
                case .notSaved: Text("No se ha podido guardar.").foregroundStyle(.red)
                case nil: EmptyView()
                }
            }
        }
        .focusSection()
    }

    private func roleButton(_ account: Account, _ role: ProfileRole, _ title: LocalizedStringKey) -> some View {
        Button {
            problems[account.id] = model.setRole(role, for: account)
        } label: {
            if account.role == role { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        .accessibilityAddTraits(account.role == role ? .isSelected : [])
    }
}
