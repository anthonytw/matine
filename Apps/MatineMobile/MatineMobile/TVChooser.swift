import MatineKit
import SwiftUI

/// "Reproducir en la tele" on the detail page: the TVs
/// are asked for when the button is tapped (so one that has gone is never
/// offered). One TV gets the video at once, several are listed to choose
/// from, none is a plain message. `.tvChooser(_)` shows the list and the
/// two messages.
@MainActor @Observable
final class TVChooser {
    var choices: [TVTarget] = []
    var isChoosing = false
    var noTV = false
    var failed = false
    private var send: (@MainActor (TVTarget) async -> Void)?

    /// Asks for the TVs and hands the one to use to `send`.
    func tap(client: JellyfinClient, userId: String, model: AppModel, send: @escaping @MainActor (TVTarget) async -> Void) async {
        // A revoked token goes to sign-in, not to "couldn't send".
        guard let found = await tvs(client: client, userId: userId, model: model, reporting: true) else { return }
        switch found.count {
        case 0: noTV = true
        case 1: await send(found[0])
        default:
            choices = found
            self.send = send
            isChoosing = true
        }
    }

    /// A TV the user picked from the list.
    func pick(_ tv: TVTarget) async {
        let send = self.send
        self.send = nil
        await send?(tv)
    }

    /// The TVs right now; nil when the server could not be asked. `reporting`:
    /// a failure also raises `failed`, unless the session expired (sign-in shows).
    func tvs(client: JellyfinClient, userId: String, model: AppModel, reporting: Bool = false) async -> [TVTarget]? {
        do {
            return try await client.tvs(userId: userId)
        } catch {
            if !model.sessionExpired(error, userId: userId), reporting { failed = true }
            return nil
        }
    }
}

extension View {
    /// The TV list and the "no TV" / "could not send" messages of a `TVChooser`.
    func tvChooser(_ chooser: TVChooser) -> some View {
        @Bindable var chooser = chooser
        return confirmationDialog("Reproducir en la tele", isPresented: $chooser.isChoosing, titleVisibility: .visible) {
            ForEach(chooser.choices) { tv in Button { Task { await chooser.pick(tv) } } label: { Text(verbatim: tv.name) } }
        }
        .alert("No hay ninguna tele disponible.", isPresented: $chooser.noTV) { Button("Vale", role: .cancel) {} } message: {
            Text("Abre Matiné en la tele para mandarle vídeos. Si la tele está en el perfil de otra persona, solo la ves con una cuenta de administrador.")
        }
        .alert("No se ha podido mandar a la tele.", isPresented: $chooser.failed) { Button("Vale", role: .cancel) {} }
    }
}
