import MatineKit
import SwiftUI

struct ProfilePickerView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: String?

    var body: some View {
        VStack(spacing: 64) {
            Text("¿Quién está viendo?")
                .font(.largeTitle.bold())
            HStack(spacing: 56) {
                ForEach(model.accounts) { account in
                    Button { model.choose(account) } label: {
                        ProfileTile(name: account.shownName, locked: model.hasPin(account)) {
                            AvatarView(avatar: account.avatar, size: 220)
                        }
                    }
                    .buttonStyle(BareButtonStyle())
                    .focused($focused, equals: account.id)
                    .accessibilityLabel(Text(model.hasPin(account) ? "\(account.shownName), con PIN" : "\(account.shownName)"))
                }
                Button { model.addProfile() } label: {
                    ProfileTile(name: String(localized: "Añadir perfil")) {
                        ZStack {
                            Circle().fill(.white.opacity(0.12))
                            Image(systemName: "plus").font(.system(size: 80, weight: .semibold))
                        }
                        .frame(width: 220, height: 220)
                    }
                }
                .buttonStyle(BareButtonStyle())
            }
            .focusSection()
            // Whoever watched last is most likely watching again.
            .defaultFocus($focused, model.lastProfileId)
        }
    }
}

/// A circle that grows, lifts and gets a white ring when focused, the name
/// under it brightening with it (no platter behind the circle).
struct ProfileTile<Picture: View>: View {
    let name: String
    var locked = false
    @ViewBuilder var picture: () -> Picture
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 28) {
            picture()
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(.white, lineWidth: focused ? 7 : 0) }
                .scaleEffect(focused ? 1.12 : 1)
                .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: focused ? 34 : 0, y: focused ? 22 : 0)
            HStack(spacing: 8) {
                Text(name).font(.title3.weight(focused ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 260)
                if locked { Image(systemName: "lock.fill").font(.callout) }
            }
            .foregroundStyle(.white.opacity(focused ? 1 : 0.7))
        }
        .padding(24)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
    }
}

/// Before adding a profile once a kid profile exists: any grown-up's PIN.
struct AdultCheckView: View {
    @Environment(AppModel.self) private var model
    @State private var message: Text?

    var body: some View {
        VStack(spacing: 32) {
            PinPad(title: "PIN de un adulto", message: message) { pin in
                if let refusal = PinRefusal(model.checkAdultPin(pin)) {
                    message = refusal.text
                } else {
                    model.screen = .addProfile(nil)
                }
            }
            Button("Cancelar") { model.screen = .picker }
        }
        .onExitCommand { model.screen = .picker }
    }
}

struct AddProfileView: View {
    @Environment(AppModel.self) private var model
    /// Signing in again for this profile: its server and name come prefilled.
    var again: Account?

    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var working = false
    @State private var failure: LocalizedStringKey?
    @State private var codeSession: QuickConnectSession?
    @State private var codeTask: Task<Void, Never>?
    @State private var lapsed = false
    /// The approval request this screen posted to the household's other devices.
    @State private var approvalRequest: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {
            Text("Añadir perfil").font(.largeTitle.bold())
            if let codeSession { codePanel(codeSession) } else { form }
        }
        .frame(maxWidth: 1000)
        .padding(80)
        // Back returns to the picker instead of leaving the app (with no
        // profile yet there is nowhere to go back to).
        .onExitCommand(perform: model.accounts.isEmpty ? nil : { cancelCode(); model.screen = .picker })
        .onAppear {
            if let again {
                server = again.server.absoluteString
                username = again.name
                // A profile the household brought, never signed in on this device.
                if !model.hasToken(again) { signInBroughtProfile(again) }
            }
        }
        .onDisappear {
            withdrawRequest()
            codeTask?.cancel()
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 36) {
            if let again {
                // Signing in again is for this profile only: its server and user, fixed.
                VStack(alignment: .leading, spacing: 12) {
                    Text("Servidor").font(.callout).foregroundStyle(.white.opacity(0.75))
                    Text(verbatim: again.server.absoluteString).font(.title3)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Usuario").font(.callout).foregroundStyle(.white.opacity(0.75))
                    Text(verbatim: again.name).font(.title3)
                }
            } else {
                FormField(label: "Servidor", text: $server, contentType: .URL, placeholder: "https://")
                FormField(label: "Usuario", text: $username, contentType: .username)
            }
            if let address = again?.server ?? Profiles.serverURL(from: server), !Profiles.isSecure(address) {
                // Plain http: allowed (most home servers have no certificate), never silent.
                Label("Sin cifrar: la contraseña y la sesión se envían sin protección. Úsala solo en la red de casa o usa una dirección https://.", systemImage: "lock.open")
                    .font(.callout).foregroundStyle(.orange)
            }
            FormField(label: "Contraseña", text: $password, secure: true, contentType: .password)
            Text("Déjalo vacío si la cuenta no tiene contraseña.").font(.callout).foregroundStyle(.white.opacity(0.75))
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
            HStack(spacing: 32) {
                Button("Iniciar sesión") { Task { await submit() } }
                    .disabled(working || Profiles.cleanUsername(username).isEmpty || (again == nil && Profiles.serverURL(from: server) == nil))
                if !model.accounts.isEmpty {
                    if let again, !again.isKid { Button("Entrar con un código") { startCode() } }
                    Button("Cancelar") { model.screen = .picker }
                }
            }
        }
    }

    /// Kids' accounts have no password: try it blank, and fall back to the form
    /// (name filled in). A grown-up's code goes to the household's other devices
    /// to approve; it also stays on screen for anyone to approve by hand.
    private func signInBroughtProfile(_ account: Account) {
        if account.isKid {
            working = true
            Task {
                defer { working = false }
                _ = try? await model.signIn(server: account.server, username: account.name, password: "", expecting: account.id)
            }
        } else {
            startCode()
        }
    }

    private func codePanel(_ session: QuickConnectSession) -> some View {
        VStack(spacing: 28) {
            Text("Tu código").font(.title3).foregroundStyle(.white.opacity(0.75))
            Text(verbatim: session.code)
                .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                .kerning(10)
                .accessibilityLabel(Text(verbatim: session.code.map(String.init).joined(separator: " ")))
            Text("Apruébalo en otro dispositivo con Matiné o en la web de Jellyfin.")
                .multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.75))
            if !Profiles.isSecure(session.server) {
                Label("Sin cifrar: la sesión se envía sin protección. Úsala solo en la red de casa o usa una dirección https://.", systemImage: "lock.open")
                    .font(.callout).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if lapsed {
                Text("El código ha caducado.").foregroundStyle(.red)
                Button("Pedir otro código") { startCode() }
            } else {
                ProgressView()
            }
            Button("Cancelar") { cancelCode() }
        }
        .frame(maxWidth: .infinity)
    }

    private func startCode() {
        guard let again else { return }
        let url = again.server
        failure = nil
        lapsed = false
        withdrawRequest()
        codeTask?.cancel()
        codeTask = Task {
            defer { withdrawRequest() }
            do {
                let session = try await model.profiles.startQuickConnect(server: url, deviceId: again.deviceId)
                codeSession = session
                approvalRequest = await model.household.requestApproval(
                    server: session.server, userId: again.id, code: session.code, device: model.profiles.deviceName
                )
                // Only that profile's own user may approve.
                try await model.finishQuickConnect(session, policy: .again(userId: again.id))
                codeSession = nil
            } catch is CancellationError {
                return
            } catch QuickConnectError.expired, QuickConnectError.timedOut {
                lapsed = true
            } catch QuickConnectError.wrongUser {
                failure = "Ese código lo aprobó otro usuario. Pide otro y apruébalo con el perfil correcto."
                codeSession = nil
            } catch QuickConnectError.disabled {
                failure = "Este servidor no admite el acceso con código."
                codeSession = nil
            } catch {
                failure = "No se ha podido iniciar sesión."
                codeSession = nil
            }
        }
    }

    private func cancelCode() {
        withdrawRequest()
        codeTask?.cancel()
        codeTask = nil
        codeSession = nil
        lapsed = false
    }

    private func withdrawRequest() {
        guard let id = approvalRequest else { return }
        approvalRequest = nil
        Task { await model.household.withdraw(id) }
    }

    private func submit() async {
        guard let url = again?.server ?? Profiles.serverURL(from: server) else {
            failure = "La dirección del servidor debe empezar por https:// o http://."
            return
        }
        working = true
        defer { working = false }
        do {
            // Signing in again is only ever for that profile's own server and user.
            try await model.signIn(server: url, username: again?.name ?? username, password: password, expecting: again?.id)
            password = ""
        } catch Profiles.SignInError.wrongUser {
            failure = "Esa cuenta no es la de este perfil."
        } catch JellyfinError.unsupportedServer {
            failure = "La dirección del servidor debe empezar por https:// o http://."
        } catch JellyfinError.badCredentials {
            failure = "Usuario o contraseña incorrectos."
        } catch JellyfinError.transport {
            failure = "No se puede conectar con el servidor."
        } catch {
            failure = "No se ha podido iniciar sesión."
        }
    }
}
