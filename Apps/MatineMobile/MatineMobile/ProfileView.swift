import MatineKit
import SwiftUI

/// The open profile: who it is, its language and PIN, approving another
/// device, switching profile and signing out. A kid profile gets only its
/// avatar and "Cambiar de perfil" (see `HouseRules`).
struct ProfileView: View {
    @Environment(AppModel.self) private var model
    let account: Account

    private enum Sheet: Identifiable {
        case grownUp(Action), ownPin(Action), newPin, approve
        var id: Int {
            switch self {
            case .grownUp: 0
            case .newPin: 1
            case .approve: 2
            case .ownPin: 3
            }
        }
    }

    /// What a grown-up's PIN unlocks.
    private enum Action { case firstPin, signOut, remove, approve }

    @State private var sheet: Sheet?
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmSignOut = false
    @State private var confirmRemove = false
    @State private var problem: LocalizedStringKey?

    private var shown: Account { model.current(account) }
    private var hasPin: Bool { model.hasPin(shown) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AvatarView(avatar: shown.avatar, size: 64)
                    VStack(alignment: .leading) {
                        Text(verbatim: shown.shownName).font(.title2.bold())
                        if shown.isKid { Text("Infantil").foregroundStyle(.secondary) }
                    }
                }
                .accessibilityElement(children: .combine)
                Button("Cambiar de perfil") { model.screen = .picker }
            }
            if shown.isKid {
                Section {
                    if model.rules.approveGate(for: shown) == .notAllowed {
                        Text("Un adulto con PIN puede aprobar dispositivos para este perfil.").foregroundStyle(.secondary)
                    } else {
                        Button("Aprobar otro dispositivo") { requestApprove() }
                    }
                } footer: {
                    if model.rules.approveGate(for: shown) != .notAllowed { Text("Hace falta el PIN de un adulto.") }
                }
            }
            if !shown.isKid {
                Section("Idioma") {
                    Picker("Idioma", selection: Binding(get: { shown.language }, set: { model.setLanguage($0, for: shown) })) {
                        Text("Español").tag(AppLanguage.spanish)
                        Text("English").tag(AppLanguage.english)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    Toggle("Descargar con datos móviles", isOn: Binding(
                        get: { model.downloads.allowsCellular }, set: { model.downloads.setAllowsCellular($0) }
                    ))
                } header: {
                    Text("Descargas")
                } footer: {
                    Text("Las descargas nuevas usan solo wifi, salvo que lo cambies aquí.")
                }
                Section {
                    if let progress = model.keywords.progress {
                        Text("Palabras clave: \(progress.have) de \(progress.of)")
                        if model.keywords.making {
                            Label("Haciendo palabras clave…", systemImage: "sparkles")
                                .foregroundStyle(.secondary)
                        }
                        if let problem = model.keywords.problem {
                            KeywordProblemText(problem: problem)
                        }
                    }
                    KeywordShareRow()  // keyword share (KeywordShareViews)
                } header: {
                    Text("Búsqueda")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Se hacen en este teléfono y llegan al Apple TV por iCloud. Enchufado y con la app abierta, la pantalla no se apaga hasta terminar.")
                        Text("Comparte solo las palabras clave de búsqueda, no los perfiles ni lo que veis.")
                    }
                }
                Section {
                    if hasPin {
                        Button("Cambiar PIN") { sheet = .newPin }
                        Button("Quitar PIN", role: .destructive) { removePin() }
                    } else {
                        Button("Poner un PIN") { requestFirstPin() }
                    }
                } header: {
                    Text("PIN")
                } footer: {
                    Text("Con PIN, este perfil no se abre sin él.")
                }
                Section {
                    Button("Aprobar otro dispositivo") { requestApprove() }
                } footer: {
                    Text("Para entrar en otro dispositivo sin escribir la contraseña: pon aquí el código que muestra.")
                }
                Section {
                    Button("Cerrar sesión", role: .destructive) { requestSignOut(everywhere: false) }
                    Button("Quitar de todos los dispositivos", role: .destructive) { requestSignOut(everywhere: true) }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let problem { Text(problem).foregroundStyle(.red) }
                        Text("Los perfiles se comparten con tus otros dispositivos por iCloud. Cerrar sesión solo afecta a este; quitar borra el perfil en todos.")
                    }
                }
            }
        }
        .navigationTitle("Perfil")
        .onChange(of: scenePhase) { _, phase in
            // An unlocked sheet or confirmation (a grown-up's PIN already typed) closes when the app is left.
            if phase == .background {
                sheet = nil
                confirmSignOut = false
                confirmRemove = false
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .grownUp(let action):
                GrownUpSheet { unlocked in unlock(unlocked, action) }
            case .ownPin(let action):
                OwnPinSheet(account: shown) { unlocked in unlock(unlocked, action) }
            case .newPin:
                NewPinSheet(account: shown) { self.sheet = nil }
            case .approve:
                ApproveDeviceSheet(account: shown) { self.sheet = nil }
            }
        }
        .confirmationDialog("¿Cerrar la sesión de \(shown.shownName) en este dispositivo?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Cerrar sesión", role: .destructive) { Task { await model.signOut(shown) } }
        }
        .confirmationDialog("¿Quitar a \(shown.shownName) de todos los dispositivos?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Quitar de todos los dispositivos", role: .destructive) { Task { await model.removeEverywhere(shown) } }
        }
    }

    /// What a passed PIN opens next.
    private func unlock(_ unlocked: Bool, _ action: Action) {
        sheet = nil
        guard unlocked else { return }
        switch action {
        case .firstPin: sheet = .newPin
        case .signOut: confirmSignOut = true
        case .remove: confirmRemove = true
        case .approve: sheet = .approve
        }
    }

    /// Approving a code hands out a long-lived session as this profile, so it
    /// asks for what opening the profile asks for: its own PIN, or (a profile
    /// without one, in a house with kids) a grown-up's.
    private func requestApprove() {
        switch model.rules.approveGate(for: shown) {
        case .ownPin: sheet = .ownPin(.approve)
        case .grownUpPin: sheet = .grownUp(.approve)
        case .open: sheet = .approve
        case .notAllowed: break
        }
    }

    private func requestFirstPin() {
        // A first PIN on an adult profile without one asks for a grown-up's
        // PIN once a kid profile exists.
        sheet = model.rules.needsGrownUp(toChange: shown) ? .grownUp(.firstPin) : .newPin
    }

    private func requestSignOut(everywhere: Bool) {
        // Signing out here leaves the profile in the household; only removing it is refused by the house rules.
        if everywhere, let refusal = model.signOutRefusal(shown) {
            problem = refusal == .lastAdult ? "Tiene que quedar al menos un perfil de adulto." : "Un perfil de adulto necesita un PIN antes."
            return
        }
        problem = nil
        if model.rules.needsGrownUp(toChange: shown) {
            sheet = .grownUp(everywhere ? .remove : .signOut)
        } else if everywhere {
            confirmRemove = true
        } else {
            confirmSignOut = true
        }
    }

    private func removePin() {
        do {
            try model.removePin(for: shown)
            problem = nil
        } catch {
            problem = "Con perfiles infantiles, hace falta al menos un adulto con PIN."
        }
    }
}

/// A grown-up's PIN (any adult's), for the changes a kid mustn't make.
private struct GrownUpSheet: View {
    @Environment(AppModel.self) private var model
    let done: (Bool) -> Void
    @State private var message: Text?

    var body: some View {
        VStack {
            PinPad(title: Text("PIN de un adulto"), message: message) { pin in
                if let refusal = PinRefusal(model.checkAdultPin(pin)) { message = refusal.text } else { done(true) }
            }
            Button("Cancelar") { done(false) }
        }
        .presentationDetents([.large])
    }
}

/// This profile's own PIN again, before something that acts as it.
private struct OwnPinSheet: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let done: (Bool) -> Void
    @State private var message: Text?

    var body: some View {
        VStack {
            PinPad(title: Text("PIN de \(account.shownName)"), message: message) { pin in
                if let refusal = PinRefusal(model.checkPin(pin, for: account)) { message = refusal.text } else { done(true) }
            }
            Button("Cancelar") { done(false) }
        }
        .presentationDetents([.large])
    }
}

/// Type a new PIN, then again.
private struct NewPinSheet: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let done: () -> Void
    @State private var first: String?
    @State private var message: Text?

    var body: some View {
        VStack {
            PinPad(title: first == nil ? Text("Elige un PIN de 4 cifras") : Text("Repite el PIN"), message: message) { pin in
                guard let firstPin = first else {
                    first = pin
                    message = nil
                    return
                }
                if pin == firstPin {
                    do {
                        try model.setPin(pin, for: account)
                        done()
                    } catch {
                        message = Text("No se ha podido guardar el PIN.").foregroundStyle(.red)
                    }
                } else {
                    first = nil
                    message = Text("No coinciden. Prueba otra vez.").foregroundStyle(.red)
                }
            }
            Button("Cancelar", action: done)
        }
        .presentationDetents([.large])
    }
}

/// Approves the code another device shows (Quick Connect), as this profile.
private struct ApproveDeviceSheet: View {
    @Environment(AppModel.self) private var model
    let account: Account
    let done: () -> Void

    @State private var code = ""
    @State private var working = false
    @State private var approved = false
    @State private var failure: LocalizedStringKey?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("000000", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .onChange(of: code) { code = String(code.filter(\.isNumber).prefix(6)) }
                        .accessibilityLabel(Text("Código de 6 cifras"))
                } footer: {
                    if approved {
                        Label("Aprobado. El otro dispositivo entrará en unos segundos.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if let failure {
                        Text(failure).foregroundStyle(.red)
                    } else {
                        Text("Pon el código de 6 cifras que muestra el otro dispositivo. Entrará como \(account.shownName).")
                    }
                }
                Section {
                    Button { Task { await approve() } } label: {
                        HStack { Spacer(); if working { ProgressView() } else { Text("Aprobar") }; Spacer() }
                    }
                    .disabled(!Profiles.isQuickConnectCode(code) || working || approved)
                }
            }
            .navigationTitle("Aprobar otro dispositivo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(approved ? "Listo" : "Cancelar", action: done) } }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func approve() async {
        working = true
        defer { working = false }
        do {
            try await model.profiles.approveQuickConnect(code: code, as: account)
            approved = true
            failure = nil
        } catch QuickConnectError.invalidCode {
            failure = "Ese código no existe o ha caducado."
        } catch JellyfinError.unauthorized {
            _ = model.sessionExpired(JellyfinError.unauthorized, userId: account.id)
        } catch {
            failure = "No se ha podido aprobar el código."
        }
    }
}

/// Why no keywords are being made, with what to do about it.
private struct KeywordProblemText: View {
    let problem: KeywordProblem

    var body: some View {
        switch problem {
        case .appleIntelligenceOff:
            Text("Activa Apple Intelligence en Ajustes, o descarga español e inglés en Ajustes › Apps › Traducir.")
                .foregroundStyle(.secondary)
        case .notEligible:
            Text("Este teléfono no puede usar Apple Intelligence. Descarga español e inglés en Ajustes › Apps › Traducir.")
                .foregroundStyle(.secondary)
        case .modelDownloading:
            Text("Apple Intelligence todavía se está descargando. Se seguirá cuando termine.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Text("Último error: \(message)")
                .font(.footnote)
                .lineLimit(4)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
    }
}
