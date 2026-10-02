import SwiftUI

/// Pure check for the typed-name gate.
enum ProdConfirmRule {
    static func isSatisfied(typed: String, required: String?) -> Bool {
        guard let required else { return true }
        return typed.trimmingCharacters(in: .whitespaces) == required
    }
}

/// "PRODUCTION" capsule shown in toolbar / sidebar / detail when the context is prod.
struct ProdBadge: View {
    var body: some View {
        Label("PRODUCTION", systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.red, in: Capsule())
            .accessibilityLabel("Production environment")
    }
}

/// Reusable extra confirmation for prod: warning, optional "type the name" gate.
struct ProdConfirmationView: View {
    let title: String
    let message: String
    let actionTitle: String
    /// When set, the user must type this exactly before the action enables.
    var requiredText: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProdBadge()
            Text(title).font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let requiredText {
                Text("Type “\(requiredText)” to confirm.").font(.callout)
                TextField("", text: $typed, prompt: Text(requiredText))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { if satisfied { onConfirm() } }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction).tint(.primary)
                Button(actionTitle, role: .destructive, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!satisfied)
            }
        }
        .padding(20)
        .frame(width: 420)
        .tint(.red)
    }

    private var satisfied: Bool { ProdConfirmRule.isSatisfied(typed: typed, required: requiredText) }
}

extension View {
    /// Presents `ProdConfirmationView` as a sheet while `isPresented`.
    func prodConfirmation(
        isPresented: Binding<Bool>, title: String, message: String, actionTitle: String,
        requiredText: String? = nil, onConfirm: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            ProdConfirmationView(
                title: title, message: message, actionTitle: actionTitle, requiredText: requiredText,
                onConfirm: {
                    // Confirm first: dismissing runs the binding's setter, which clears the caller's pending state.
                    onConfirm()
                    isPresented.wrappedValue = false
                },
                onCancel: { isPresented.wrappedValue = false })
        }
    }
}
