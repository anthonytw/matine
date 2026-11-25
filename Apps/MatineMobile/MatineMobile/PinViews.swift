import MatineKit
import SwiftUI

/// Four dots over a number pad. A pad of our own (not the keyboard) so the
/// PIN never lands in the keyboard's suggestions, and so it looks the same
/// on the phone and the tablet.
struct PinPad: View {
    let title: Text
    var message: Text?
    let onComplete: (String) -> Void

    @State private var entered = ""
    @ScaledMetric(relativeTo: .title) private var key: CGFloat = 76

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 28) {
            title.font(.title2.bold()).multilineTextAlignment(.center)
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 2)
                        .background(Circle().fill(index < entered.count ? Color.primary : .clear))
                        .frame(width: 18, height: 18)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(Text("PIN"))
            .accessibilityValue(Text("\(entered.count) de 4"))
            message.font(.callout).multilineTextAlignment(.center).frame(minHeight: 44)
            Grid(horizontalSpacing: 18, verticalSpacing: 14) {
                ForEach(rows, id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { digitButton($0) } }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    digitButton("0")
                    Button { if !entered.isEmpty { entered.removeLast() } } label: {
                        Image(systemName: "delete.left").font(.title2).frame(width: key, height: key)
                    }
                    .accessibilityLabel(Text("Borrar"))
                }
            }
        }
        .padding()
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            guard entered.count < 4 else { return }
            entered.append(digit)
            if entered.count == 4 {
                let pin = entered
                entered = ""
                onComplete(pin)
            }
        } label: {
            Text(verbatim: digit)
                .font(.title.weight(.medium))
                .frame(width: key, height: key)
                .background(.quaternary, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }
}

/// A PIN profile's gate: nothing opens without the right PIN.
struct PinEntryView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var message: Text?

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            AvatarView(avatar: account.avatar, size: 72)
            PinPad(title: Text("PIN de \(account.shownName)"), message: message) { pin in
                if let refusal = PinRefusal(model.checkPin(pin, for: account)) {
                    message = refusal.text
                } else {
                    model.screen = .home(model.current(account))
                }
            }
            Spacer()
            Button("Cancelar") { model.cancelPin() }.padding(.bottom)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Before adding a profile once a kid profile exists: any adult's PIN.
struct AdultCheckView: View {
    @Environment(AppModel.self) private var model
    @State private var message: Text?

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            PinPad(title: Text("PIN de un adulto"), message: message ?? Text("Para añadir un perfil hace falta el PIN de un adulto.")) { pin in
                if let refusal = PinRefusal(model.checkAdultPin(pin)) {
                    message = refusal.text
                } else {
                    model.grownUpCleared = true
                    model.screen = .addProfile(nil)
                }
            }
            Spacer()
            Button("Cancelar") { model.screen = .picker }.padding(.bottom)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Why a PIN didn't open, as the line under the dots. Nil means it opened.
struct PinRefusal {
    let text: Text

    init?(_ outcome: PinGate.Outcome?) {
        switch outcome {
        case .open:
            return nil
        case .wrong(let left):
            text = Text("PIN incorrecto. Quedan \(left) intentos.").foregroundStyle(.red)
        case .locked(let until):
            text = Text("Demasiados intentos. Prueba de nuevo dentro de \(until, style: .relative).").foregroundStyle(.red)
        case nil:
            text = Text("No se ha podido comprobar el PIN.").foregroundStyle(.red)
        }
    }
}
