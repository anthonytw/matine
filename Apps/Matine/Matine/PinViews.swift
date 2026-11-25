import MatineKit
import SwiftUI

/// Dots over a number pad: four for a PIN, six for a Quick Connect code.
/// tvOS has no numeric keyboard, so the digits are focusable buttons; the
/// remote moves between them.
struct PinPad: View {
    let title: LocalizedStringKey
    var message: Text?
    var length = 4
    let onComplete: (String) -> Void

    @State private var entered = ""

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]]

    var body: some View {
        VStack(spacing: 40) {
            Text(title).font(.title2.bold())
            HStack(spacing: 28) {
                ForEach(0..<length, id: \.self) { index in
                    Circle()
                        .strokeBorder(.secondary, lineWidth: 3)
                        .background(Circle().fill(index < entered.count ? Color.primary : .clear))
                        .frame(width: 32, height: 32)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(length == 4 ? Text("PIN") : Text("Código"))
            .accessibilityValue(Text("\(entered.count) de \(length)"))
            message.frame(minHeight: 40)
            // A grid, so 0 and Borrar line up under the columns above.
            Grid(horizontalSpacing: 20, verticalSpacing: 20) {
                ForEach(rows, id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { digitButton($0) } }
                }
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    digitButton("0")
                    Button { if !entered.isEmpty { entered.removeLast() } } label: {
                        Image(systemName: "delete.left").frame(width: 140, height: 100)
                    }
                    .accessibilityLabel(Text("Borrar"))
                }
            }
            .focusSection()
        }
    }

    private func digitButton(_ digit: String) -> some View {
        Button {
            guard entered.count < length else { return }
            entered.append(digit)
            if entered.count == length {
                let pin = entered
                entered = ""
                onComplete(pin)
            }
        } label: {
            Text(digit).font(.title).frame(width: 140, height: 100)
        }
    }
}

struct PinEntryView: View {
    @Environment(AppModel.self) private var model
    let account: Account
    @State private var message: Text?

    var body: some View {
        VStack(spacing: 32) {
            PinPad(title: "PIN de \(account.shownName)", message: message) { pin in
                if let refusal = PinRefusal(model.checkPin(pin, for: account)) {
                    message = refusal.text
                } else {
                    model.screen = .home(model.current(account))
                }
            }
            Button("Cambiar de perfil") {
                model.pinCancelReturnsTo = nil
                model.screen = .picker
            }
        }
        .onExitCommand { model.cancelPin() }
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
            // "dentro de 5 minutos": no "a las 1:05" agreement to get wrong.
            text = Text("Demasiados intentos. Prueba de nuevo dentro de \(until, style: .relative).").foregroundStyle(.red)
        case nil:
            text = Text("No se ha podido comprobar el PIN.").foregroundStyle(.red)
        }
    }
}
