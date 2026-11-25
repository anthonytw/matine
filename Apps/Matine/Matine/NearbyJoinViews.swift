import MatineKit
import SwiftUI

/// What the TV knows about phones announcing a sign-in code nearby, and
/// whether its sheet is up. The decisions (what is offered, backoff, who may
/// approve and how) live in MatineKit (`NearbyRoster`, `HouseRules.nearbyChoices`);
/// this only holds them for the views.
@MainActor @Observable
final class NearbyCenter {
    /// "Avisar cuando un dispositivo quiera entrar": per TV, on by default.
    static let enabledKey = "matine.nearbyAlerts"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private var roster = NearbyRoster()
    private(set) var presented = false
    /// Counts presentations, so a late callback from an earlier sheet can't
    /// close or answer for a later one.
    private(set) var generation = 0
    /// The device picked from the list, when several are asking.
    var selected: String?
    /// An approval is being sent or has just gone through: the sheet stays
    /// even though the phone stops announcing.
    var busy = false

    var offer: NearbyOffer? { roster.offer() }

    func hear(_ joins: [NearbyJoin]) {
        roster.update(seen: joins)
        guard presented, !busy else { return }
        // A phone that stopped asking (cancelled, lapsed) takes its sheet
        // with it; that is not a decline.
        guard let offer else { return close() }
        if let selected, !offer.joins.contains(where: { $0.code == selected }) { self.selected = nil }
    }

    /// Opens the sheet when something is on offer and the screen allows it.
    func present(allowed: Bool) {
        guard allowed, !presented, Self.enabled, offer != nil else { return }
        selected = nil
        busy = false
        generation += 1
        presented = true
    }

    func answer(_ join: NearbyJoin, _ outcome: NearbyOutcome, generation: Int) {
        guard presented, generation == self.generation else { return }
        roster.finish(join, outcome)
        close()
    }

    /// "Ahora no" on the list, Menu, or a Play from the phone.
    func declineAll(generation: Int? = nil) {
        // Not while an approval is going through: that finishes on its own.
        guard presented, !busy, generation.map({ $0 == self.generation }) ?? true else { return }
        roster.declineAll()
        close()
    }

    /// Closes without answering: the phone vanished, or the app left the front.
    func close() {
        presented = false
        selected = nil
        busy = false
    }
}

/// A phone in "Entrar con un código" announced itself on the network. The
/// sheet is a warning first and a question second: it says who may approve and
/// when not to, starts with focus on "Ahora no", ignores input for a moment
/// after it appears, and never approves with a single press (a confirm step,
/// or a PIN). The code is approved as the chosen profile; the open profile
/// never changes. See the threat note on `NearbyJoin`.
struct NearbyJoinSheet: View {
    @Environment(AppModel.self) private var model
    let center: NearbyCenter
    let generation: Int
    /// The profile open behind the sheet, offered first.
    let open: Account

    private enum Stage {
        case choose
        case pin(NearbyChoice, NearbyJoin)
        case confirm(NearbyChoice, NearbyJoin)
        case approving
        case approved
    }
    private enum Focus { case decline, cancel }
    @State private var stage: Stage = .choose
    @State private var message: Text?
    /// Input counts only after the sheet has been up a moment, so a press
    /// meant for the screen behind it can't answer it.
    @State private var armed = false
    @State private var approval: Task<Void, Never>?
    @FocusState private var focus: Focus?

    private var confirming: Bool {
        if case .confirm = stage { true } else { false }
    }

    /// Changes with each stage (and the picked device), re-arming the guard.
    private var armKey: [String] {
        var key = [center.selected ?? ""]
        switch stage {
        case .choose: key.append(contentsOf: [])
        case .pin: key.append(contentsOf: ["p"])
        case .confirm: key.append(contentsOf: ["c"])
        case .approving, .approved: key.append(contentsOf: ["d"])
        }
        return key
    }

    var body: some View {
        Group {
            switch stage {
            case .choose:
                if let offer = center.offer { choose(offer) }
            case .pin(let choice, let join): pinStep(choice, join)
            case .confirm(let choice, let join): confirmStep(choice, join)
            case .approving:
                VStack(spacing: 24) { ProgressView(); Text("Aprobando…").font(.title3) }
            case .approved:
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 90)).foregroundStyle(.green)
                    Text("Aprobado. El otro dispositivo entrará en unos segundos.").font(.title3).multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultFocus($focus, confirming ? .cancel : .decline)
        .task(id: armKey) {
            armed = false
            try? await Task.sleep(for: .seconds(1))
            armed = true
        }
        .onDisappear { approval?.cancel() }
    }

    // MARK: Names

    private func title(_ kind: NearbyJoin.Kind) -> LocalizedStringKey {
        switch kind {
        case .iPhone: "Un iPhone quiere entrar"
        case .iPad: "Un iPad quiere entrar"
        case .other: "Un dispositivo quiere entrar"
        }
    }

    private func warning(_ kind: NearbyJoin.Kind) -> LocalizedStringKey {
        switch kind {
        case .iPhone: "Apruébalo solo si tienes ese iPhone en la mano y muestra este mismo código. Si nadie está entrando ahora, elige «Ahora no»."
        case .iPad: "Apruébalo solo si tienes ese iPad en la mano y muestra este mismo código. Si nadie está entrando ahora, elige «Ahora no»."
        case .other: "Apruébalo solo si tienes ese dispositivo en la mano y muestra este mismo código. Si nadie está entrando ahora, elige «Ahora no»."
        }
    }

    private func name(_ kind: NearbyJoin.Kind) -> LocalizedStringKey {
        switch kind {
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .other: "Dispositivo"
        }
    }

    private func spoken(_ join: NearbyJoin) -> String { join.code.map(String.init).joined(separator: " ") }

    // MARK: Stages

    /// One device: its code and the profiles. Several (or one right after an
    /// answer): a list first, never the first one quietly.
    @ViewBuilder private func choose(_ offer: NearbyOffer) -> some View {
        if let join = shown(in: offer) {
            detail(join)
        } else {
            list(offer)
        }
    }

    private func shown(in offer: NearbyOffer) -> NearbyJoin? {
        if let code = center.selected { return offer.joins.first { $0.code == code } }
        return offer.isCrowded ? nil : offer.joins.first
    }

    private func list(_ offer: NearbyOffer) -> some View {
        VStack(spacing: 28) {
            Text("Hay varios dispositivos pidiendo entrar").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("Elige el que tienes en la mano, o «Ahora no» si no esperas ninguno.").foregroundStyle(.secondary)
            HStack(spacing: 24) {
                ForEach(offer.joins) { join in
                    Button {
                        guard armed else { return }
                        armed = false
                        center.selected = join.code
                    } label: {
                        VStack(spacing: 8) {
                            Text(name(join.kind)).font(.headline)
                            Text(verbatim: join.spacedCode).font(.system(size: 48, weight: .bold, design: .rounded).monospacedDigit())
                        }
                        .padding(12)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Button("Ahora no") { guard armed else { return }; center.declineAll(generation: generation) }
                .focused($focus, equals: .decline)
        }
    }

    private func detail(_ join: NearbyJoin) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                Text(title(join.kind)).font(.title2.bold())
                Text("Código").font(.headline).foregroundStyle(.secondary)
                Text(verbatim: join.spacedCode)
                    .font(.system(size: 80, weight: .bold, design: .rounded).monospacedDigit())
                    .accessibilityLabel(Text(verbatim: spoken(join)))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            // The check is the security, so it is the loudest thing here.
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(warning(join.kind)).fontWeight(.semibold).multilineTextAlignment(.leading)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
            }
            .font(.title3)
            .padding(24)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: 1100)
            .accessibilityElement(children: .combine)
            message
            HStack(spacing: 24) {
                ForEach(model.rules.nearbyChoices(openId: open.id), id: \.account.id) { choice in
                    Button { pick(choice, join) } label: {
                        HStack(spacing: 14) {
                            AvatarView(avatar: choice.account.avatar, size: 64)
                            Text("Entrar como \(choice.account.shownName)")
                            if choice.step != .confirm { Image(systemName: "lock.fill").font(.caption) }
                        }
                        .padding(6)
                    }
                    .accessibilityLabel(choice.step == .confirm
                        ? Text("Entrar como \(choice.account.shownName)") : Text("Entrar como \(choice.account.shownName), con PIN"))
                }
            }
            Button("Ahora no") {
                guard armed else { return }
                center.answer(join, .declined, generation: generation)
            }
            .focused($focus, equals: .decline)
        }
    }

    private func confirmStep(_ choice: NearbyChoice, _ join: NearbyJoin) -> some View {
        VStack(spacing: 36) {
            Text(verbatim: join.spacedCode)
                .font(.system(size: 96, weight: .bold, design: .rounded).monospacedDigit())
                .accessibilityLabel(Text(verbatim: spoken(join)))
            Text("Aprobar \(join.spacedCode) como \(choice.account.shownName)").font(.title2.bold())
            Text(warning(join.kind)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 1000)
                .fixedSize(horizontal: false, vertical: true)
            Button("Aprobar \(join.spacedCode) como \(choice.account.shownName)") {
                guard armed else { return }
                approve(join, as: choice.account)
            }
            Button("Cancelar") {
                message = nil
                go(.choose)
            }
            .focused($focus, equals: .cancel)
        }
        .onAppear { focus = .cancel }
        .onExitCommand { go(.choose) }
    }

    @ViewBuilder private func pinStep(_ choice: NearbyChoice, _ join: NearbyJoin) -> some View {
        let title: LocalizedStringKey = choice.step == .ownPin ? "PIN de \(choice.account.shownName)" : "PIN de un adulto"
        VStack(spacing: 24) {
            Text(verbatim: join.spacedCode)
                .font(.system(size: 64, weight: .bold, design: .rounded).monospacedDigit())
                .accessibilityLabel(Text(verbatim: spoken(join)))
            PinPad(title: title, message: message) { pin in
                let outcome = choice.step == .ownPin ? model.checkPin(pin, for: choice.account) : model.checkAdultPin(pin)
                if let refusal = PinRefusal(outcome) {
                    message = refusal.text
                } else {
                    approve(join, as: choice.account)
                }
            }
        }
        .onExitCommand {
            message = nil
            go(.choose)
        }
    }

    // MARK: Actions

    /// Every stage change disarms at once; the restarted `.task` re-arms a
    /// second later. (Waiting for the task alone leaves a window in which a
    /// press meant for the stage before lands on the new one.)
    private func go(_ next: Stage) {
        armed = false
        stage = next
    }

    private func pick(_ choice: NearbyChoice, _ join: NearbyJoin) {
        guard armed else { return }
        message = nil
        go(choice.step == .confirm ? .confirm(choice, join) : .pin(choice, join))
    }

    private func approve(_ join: NearbyJoin, as account: Account) {
        go(.approving)
        center.busy = true
        approval?.cancel()
        approval = Task {
            do {
                try await model.profiles.approveQuickConnect(code: join.code, as: account)
                guard !Task.isCancelled else { return }
                go(.approved)
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                center.answer(join, .approved, generation: generation)
            } catch {
                guard !Task.isCancelled else { return }
                center.busy = false
                switch error {
                case QuickConnectError.invalidCode: fail("Ese código no existe o ha caducado.")
                case QuickConnectError.disabled: fail("Este servidor no admite el acceso con código.")
                default: fail("No se ha podido aprobar el código.")
                }
            }
        }
    }

    private func fail(_ text: LocalizedStringKey) {
        message = Text(text).foregroundStyle(.red)
        go(.choose)
    }
}
