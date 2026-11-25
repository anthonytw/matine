import MatineKit
import SwiftUI
import UIKit

/// Sign in to the server: with a password, or with a code approved on a
/// device that is already signed in (Jellyfin Quick Connect).
struct SignInView: View {
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
    /// A code just signed this profile in: shown before landing ("No soy yo").
    @State private var entered: QuickConnectSignIn?
    /// While the code is on screen, the code is also announced to Apple TVs on the
    /// network, so one can offer to approve it. Never the request's secret.
    @State private var announcement: NearbyAdvertiser?
    @FocusState private var focus: Field?

    private enum Field { case server, username, password }

    private var serverURL: URL? { Profiles.serverURL(from: server) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Añadir perfil").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                if let entered {
                    enteredPanel(entered)
                } else if let codeSession {
                    codePanel(codeSession)
                } else {
                    form
                }
            }
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if let again {
                server = again.server.absoluteString
                username = again.name
                // A profile the household brought, never signed in on this device.
                if !model.hasToken(again) { signInBroughtProfile(again) }
            }
        }
        .onDisappear {
            // Leaving with the "No soy yo" panel still up: the sign-in stands, so it is no longer held.
            if let entered { Task { await model.household.release(userId: entered.account.id) } }
            model.pendingConfirmation = nil
            withdrawRequest()
            codeTask?.cancel()
            announcement?.stop()
            announcement = nil
        }
        // On the air only while a live code is on screen: not once it lapses,
        // is approved (the screen goes away) or is cancelled.
        .onChange(of: codeSession?.code) { announce() }
        .onChange(of: lapsed) { announce() }
        .onChange(of: entered?.account.id) { model.pendingConfirmation = entered }
    }

    // MARK: Password

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let again {
                // Signing in again is for this profile only: its server and user, fixed.
                field("Servidor") { Text(verbatim: again.server.absoluteString).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                field("Servidor") {
                    TextField("https://", text: $server)
                        .textContentType(.URL).keyboardType(.URL)
                        .focused($focus, equals: .server)
                        .submitLabel(.next).onSubmit { focus = .username }
                }
            }
            if let address = again?.server ?? serverURL, !Profiles.isSecure(address) {
                // Plain http: allowed (most home servers have no certificate), never silent.
                Label("Sin cifrar: la contraseña y la sesión se envían sin protección. Úsala solo en la red de casa o usa una dirección https://.", systemImage: "lock.open")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let again {
                field("Usuario") { Text(verbatim: again.name).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                field("Usuario") {
                    TextField("Usuario", text: $username)
                        .textContentType(.username)
                        .focused($focus, equals: .username)
                        .submitLabel(.next).onSubmit { focus = .password }
                }
            }
            field("Contraseña") {
                SecureField("Contraseña", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go).onSubmit { Task { await submit() } }
            }
            Text("Déjalo vacío si la cuenta no tiene contraseña.").font(.footnote).foregroundStyle(.secondary)
            if let failure { Text(failure).foregroundStyle(.red).font(.callout) }
            Button { Task { await submit() } } label: {
                Group { if working { ProgressView() } else { Text("Iniciar sesión") } }.frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(working || serverURL == nil || (again == nil && Profiles.cleanUsername(username).isEmpty))

            HStack { Rectangle().fill(.quaternary).frame(height: 1); Text("o").foregroundStyle(.secondary); Rectangle().fill(.quaternary).frame(height: 1) }
            Button { startCode() } label: {
                Label("Entrar con un código", systemImage: "number.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(working || serverURL == nil)

            if !model.accounts.isEmpty {
                Button("Cancelar") { model.screen = .picker }.frame(maxWidth: .infinity)
            }
        }
    }

    private func field(_ label: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            content()
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func submit() async {
        guard let url = again?.server ?? serverURL else {
            failure = "La dirección del servidor debe empezar por https:// o http://."
            return
        }
        working = true
        defer { working = false }
        do {
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

    private func withdrawRequest() {
        guard let id = approvalRequest else { return }
        approvalRequest = nil
        Task { await model.household.withdraw(id) }
    }

    // MARK: Code

    private func codePanel(_ session: QuickConnectSession) -> some View {
        VStack(spacing: 20) {
            Text("Tu código").font(.headline).foregroundStyle(.secondary)
            Text(verbatim: session.code)
                .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                .kerning(6)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityLabel(Text(verbatim: session.code.map(String.init).joined(separator: " ")))
            Text("Apruébalo en otro dispositivo con Matiné o en la web de Jellyfin.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if !Profiles.isSecure(session.server) {
                Label("Sin cifrar: la sesión se envía sin protección. Úsala solo en la red de casa o usa una dirección https://.", systemImage: "lock.open")
                    .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            if lapsed {
                Text("El código ha caducado.").foregroundStyle(.red)
                Button("Pedir otro código") { startCode() }.buttonStyle(.borderedProminent)
            } else {
                ProgressView().padding(.top, 4)
            }
            Button("Cancelar") { cancelCode() }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func startCode() {
        guard let url = again?.server ?? serverURL else { return }
        failure = nil
        lapsed = false
        working = true
        withdrawRequest()
        codeTask?.cancel()
        codeTask = Task {
            defer {
                working = false
                withdrawRequest()
            }
            do {
                let session = try await model.profiles.startQuickConnect(server: url, deviceId: again?.deviceId)
                codeSession = session
                working = false
                if let again {
                    approvalRequest = await model.household.requestApproval(
                        server: session.server, userId: again.id, code: session.code, device: model.profiles.deviceName
                    )
                }
                // Signing in again: only that profile's own user may approve.
                let policy: QuickConnectPolicy = again.map { .again(userId: $0.id) } ?? .newProfile(grownUpCleared: model.grownUpCleared)
                let signedIn = try await model.finishQuickConnectHeld(session, policy: policy)
                // Off the air first, then say who signed in.
                codeSession = nil
                // Only a profile new to this phone can be undone with "No soy yo";
                // one already here lands directly (undoing could remove a grown-up's).
                if signedIn.isNew { entered = signedIn } else { model.land(signedIn) }
            } catch is CancellationError {
                return
            } catch QuickConnectError.disabled {
                failure = "Este servidor no admite el acceso con código."
            } catch QuickConnectError.expired, QuickConnectError.timedOut {
                lapsed = true
            } catch QuickConnectError.wrongUser {
                failure = "Ese código lo aprobó otro usuario. Pide otro y apruébalo con el perfil correcto."
                codeSession = nil
            } catch QuickConnectError.needsGrownUp {
                failure = "Para añadir un perfil hace falta el PIN de un adulto."
                codeSession = nil
            } catch JellyfinError.unsupportedServer {
                failure = "La dirección del servidor debe empezar por https:// o http://."
            } catch JellyfinError.transport {
                failure = "No se puede conectar con el servidor."
                codeSession = nil
            } catch {
                failure = "No se ha podido iniciar sesión."
                codeSession = nil
            }
        }
    }

    /// The announced code is public on the network: before opening the new
    /// profile, say who it is, and let the owner undo it at once.
    private func enteredPanel(_ signedIn: QuickConnectSignIn) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Has entrado como \(signedIn.account.shownName)").font(.title2.bold()).multilineTextAlignment(.center)
            Text("Si no eres tú, o no esperabas entrar ahora, cierra la sesión.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { model.land(signedIn) } label: { Text("Continuar").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("No soy yo", role: .destructive) {
                entered = nil
                Task { await model.refuseSignIn(signedIn) }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func announce() {
        announcement?.stop()
        announcement = nil
        guard let code = codeSession?.code, !lapsed,
              let join = NearbyJoin(kind: .init(model: UIDevice.current.model), code: code) else { return }
        announcement = NearbyAdvertiser(join)
    }

    private func cancelCode() {
        withdrawRequest()
        codeTask?.cancel()
        codeTask = nil
        codeSession = nil
        lapsed = false
    }
}
