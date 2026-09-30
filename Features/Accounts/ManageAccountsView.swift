import AzureAuth
import SwiftUI

struct ManageAccountsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: AccountProfile?
    @State private var newName = ""
    @State private var removing: AccountProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Manage accounts").font(.title2.bold())
            List(model.accounts) { account in
                HStack {
                    VStack(alignment: .leading) {
                        Text(account.displayName).font(.headline)
                        Text("\(account.upn) · \(account.homeTenantId)")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Rename") {
                        newName = account.displayName
                        renaming = account
                    }
                    Button("Re-login") { model.reLogin(account) }.disabled(model.isLoggingIn)
                    Button("Remove", role: .destructive) { removing = account }
                }
            }
            .frame(minHeight: 200)
            if model.isLoggingIn || model.loginError != nil { LoginFlowView() }
            HStack {
                Button("Add account…", systemImage: "plus") {
                    dismiss()
                    model.isAddAccountPresented = true
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .alert("Rename account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") {
                if let a = renaming, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Task { await model.rename(a, to: newName) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(
            "Remove \(removing?.displayName ?? "account")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let a = removing { Task { await model.remove(a) } }
                removing = nil
            }
        } message: {
            Text("Signs out with az and deletes the local profile.")
        }
    }
}
