import AzureAuth
import SwiftUI

/// Toolbar account picker: switch, Add account…, Re-login, Manage accounts….
struct AccountMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    model.select(account.id)
                } label: {
                    if account.id == model.selectedAccountID {
                        Label(account.displayName, systemImage: "checkmark")
                    } else {
                        Text(account.displayName)
                    }
                }
            }
            Divider()
            Button("Add account…", systemImage: "plus") { model.isAddAccountPresented = true }
            if let account = model.selectedAccount {
                Button("Re-login \(account.upn)", systemImage: "arrow.clockwise") { model.reLogin(account) }
                    .disabled(model.isLoggingIn)
            }
            Button("Manage accounts…", systemImage: "person.2") { model.isManageAccountsPresented = true }
        } label: {
            Label(model.selectedAccount?.displayName ?? "No account", systemImage: "person.crop.circle")
        }
        .menuIndicator(.visible)
        .help("Switch account")
    }
}
