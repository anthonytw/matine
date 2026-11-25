import SwiftUI

/// A labelled text field with room inside it: the label sits above, and the
/// text keeps well clear of the rounded ends. tvOS ignores SwiftUI's
/// `.plain` text field style and its own field crowds the corners on a TV, so
/// the field is a borderless UITextField that draws its own box and focus.
struct FormField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var secure = false
    var contentType: UITextContentType?
    /// Greyed hint shown while the field is empty (verbatim, not localized).
    var placeholder: String?
    /// Opens the keyboard as soon as the field appears (it was asked for).
    var editsAtOnce = false
    /// Done on the keyboard.
    var onSubmit: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label).font(.callout).foregroundStyle(.white.opacity(0.75))
            RoomyTextField(text: $text, secure: secure, contentType: contentType, placeholder: placeholder, editsAtOnce: editsAtOnce, onSubmit: onSubmit)
                .frame(height: 96)
        }
    }
}

private struct RoomyTextField: UIViewRepresentable {
    @Binding var text: String
    let secure: Bool
    let contentType: UITextContentType?
    let placeholder: String?
    let editsAtOnce: Bool
    let onSubmit: (() -> Void)?

    func makeUIView(context: Context) -> PaddedField {
        let field = PaddedField()
        field.beginsEditing = editsAtOnce
        field.isSecureTextEntry = secure
        field.textContentType = contentType
        field.placeholder = placeholder
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.font = .preferredFont(forTextStyle: .title3)
        // editingDidEnd too: AutoFill and system-set text may not send editingChanged.
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: [.editingChanged, .editingDidEnd])
        field.addTarget(context.coordinator, action: #selector(Coordinator.submitted(_:)), for: .editingDidEndOnExit)
        return field
    }

    func updateUIView(_ field: PaddedField, context: Context) {
        if field.text != text { field.text = text }
        context.coordinator.onSubmit = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    @MainActor final class Coordinator: NSObject {
        let text: Binding<String>
        var onSubmit: (() -> Void)?
        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            self.text = text
            self.onSubmit = onSubmit
        }
        @objc func changed(_ field: UITextField) { text.wrappedValue = field.text ?? "" }
        @objc func submitted(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
            onSubmit?()
        }
    }
}

/// No system border: a rounded box with 40-point side insets that turns white
/// and lifts on a shadow while focused. (No scale transform: SwiftUI owns the
/// frame, and UIKit leaves `frame` undefined under a non-identity transform.)
final class PaddedField: UITextField {
    private let inset = UIEdgeInsets(top: 0, left: 40, bottom: 0, right: 40)
    /// Become first responder (the keyboard opens) once on screen.
    var beginsEditing = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        borderStyle = .none
        layer.cornerRadius = 20
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 10)
        layer.shadowRadius = 18
        style(focused: false)
    }

    required init?(coder: NSCoder) { fatalError("not used from a storyboard") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard beginsEditing, window != nil else { return }
        beginsEditing = false
        // After this layout pass: the field must be in the focus system first.
        DispatchQueue.main.async { self.becomeFirstResponder() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A known shadow shape: no offscreen pass each frame of the focus animation.
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    override func textRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { bounds.inset(by: inset) }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { self.style(focused: focused) }
    }

    private func style(focused: Bool) {
        backgroundColor = focused ? .white : UIColor.white.withAlphaComponent(0.2)
        textColor = focused ? .black : .white
        layer.shadowOpacity = focused ? 0.4 : 0
    }
}
