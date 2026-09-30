import SwiftUI

struct AddAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add account").font(.title2.bold())
            LoginFlowView()
            HStack {
                Spacer()
                if !model.isLoggingIn { Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { model.clearLoginError() }
    }
}
