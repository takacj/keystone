import AzureARM
import Foundation

/// Applies a palette result to the main window: switch subscription/vault, then select the secret.
@MainActor
enum PaletteNavigator {
    static func navigate(
        vault: Vault, secret: String?, context: ContextModel, secrets: SecretsModel, timeout: Duration = .seconds(15)
    ) async {
        context.showsDeletedSecrets = false
        if context.selectedSubscriptionID?.lowercased() != vault.subscriptionId.lowercased() {
            context.selectSubscription(vault.subscriptionId)
            guard await wait(timeout, { context.vaults.contains { $0.id.lowercased() == vault.id.lowercased() } })
            else { return }
        }
        let id = context.vaults.first { $0.id.lowercased() == vault.id.lowercased() }?.id ?? vault.id
        context.selectVault(id)
        guard let secret else { return }
        let ok = await wait(timeout) {
            secrets.vault?.id.lowercased() == vault.id.lowercased()
                && (secrets.rows.contains { $0.id == secret } || secrets.phase == .loaded)
        }
        guard ok else { return }
        secrets.filterText = ""
        secrets.selection = [secret]
    }

    private static func wait(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if Task.isCancelled || ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }
}
