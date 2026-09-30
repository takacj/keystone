import AzureARM
import AzureCore
import KeyVaultSecrets
import Persistence
import Search
import SwiftUI

/// Three-column main window: vault sidebar, secrets (#90), detail (#91).
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var context = ContextModel(
        store: UITestSupport.isActive ? UITestSupport.contextStore : ContextStateStore())
    @State private var secrets = SecretsModel()
    @State private var deleted = DeletedSecretsModel()
    @State private var detail = SecretDetailModel()
    @State private var palette = CommandPaletteModel()
    @AppStorage(CommandPaletteModel.defaultScopeKey) private var paletteDefaultScope =
        CommandPaletteModel.Scope.currentSubscription.storageValue
    @State private var editor = SecretEditorCoordinator()
    @State private var requests = ViewRequests()
    @State private var switcher: QuickSwitchKind?
    @FocusState private var pane: Pane?
    @Environment(LockModel.self) private var lock

    var body: some View {
        NavigationSplitView {
            VaultSidebar()
                .focused($pane, equals: .sidebar)
                .safeAreaInset(edge: .top) { if context.isProduction { ProdBadge().padding(.vertical, 4) } }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } content: {
            Group {
                if context.showsDeletedSecrets { DeletedSecretsView() } else { SecretsView() }
            }
            .focused($pane, equals: .list)
            .navigationSplitViewColumnWidth(min: 280, ideal: 420)
        } detail: {
            SecretDetailView()
                .focusable()
                .focused($pane, equals: .detail)
                .safeAreaInset(edge: .top) { if context.isProduction { ProdBadge().padding(.vertical, 4) } }
        }
        .tint(context.isProduction ? Color.red : nil)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                AccountMenu()
                ContextPickers()
                if context.isProduction { ProdBadge() }
            }
            ToolbarItem {
                Button("Search", systemImage: "magnifyingglass") { palette.toggle() }
                    .help("Command palette (⌘K)")
            }
            ToolbarItem {
                Button("Reload", systemImage: "arrow.clockwise") { refreshAll() }
                    .help("Reload vaults and refresh secrets (⌘R)")
            }
        }
        .focusedSceneValue(\.menuActions, menuActions)
        .overlay { paletteOverlay }
        .overlay(alignment: .bottom) {
            if let toast = palette.toast { ToastLabel(text: toast) }
        }
        .animation(.default, value: palette.toast)
        .sheet(item: $switcher) { kind in
            QuickSwitchSheet(kind: kind, items: switchItems(kind)) { selectSwitch(kind, $0) }
        }
        .sheet(item: Bindable(editor).sheet) { SecretEditorSheet(model: $0) }
        .overlay(alignment: .bottom) { SecretEditorToast() }
        .alert(
            "Undo failed",
            isPresented: Binding(get: { editor.undoError != nil }, set: { if !$0 { editor.clearUndoError() } })
        ) {
            Button("OK") {}
        } message: {
            Text(editor.undoError?.localizedDescription ?? "")
        }
        .onChange(of: lock.lockGeneration) {
            detail.clear()
            palette.reset()
        }
        .onChange(of: context.contextGeneration) { detail.contextChanged() }
        .onChange(of: paletteDefaultScope) {
            palette.scope = CommandPaletteModel.Scope(storageValue: paletteDefaultScope)
        }
        .onChange(of: context.selectedTenantID) { palette.startIndexing(tenant: context.selectedTenantID) }
        .onAppear {
            configureSecrets()
            configureDeleted()
            configureEditor()
            configurePalette()
        }
        .task(id: model.selectedAccountID) { switchAccount() }
        .sheet(isPresented: Bindable(model).isAddAccountPresented) { AddAccountSheet() }
        .sheet(isPresented: Bindable(model).isManageAccountsPresented) { ManageAccountsView() }
        // Keep last: sheets/overlays above are outside the scope of environment modifiers applied before them.
        .environment(context)
        .environment(secrets)
        .environment(deleted)
        .environment(detail)
        .environment(editor)
        .environment(palette)
        .environment(requests)
    }

    private func configureSecrets() {
        detail.clientFactory = { [secrets] vault in secrets.clientFactory(vault) }
        secrets.onHealth = { [context] vault, health in context.markVault(vault, health) }
        secrets.clientFactory = { [model, context] vault in
            guard let account = context.account, let provider = model.tokenProvider(for: account) else { return nil }
            let tenant = context.selectedTenantID ?? vault.tenantId
            guard let tenant else { return nil }
            let http = AzureHTTPClient(
                tokenProvider: provider, tenant: tenant, resource: .vault, transport: model.transport)
            return KeyVaultSecretsClient(vaultURI: vault.vaultUri, http: http)
        }
    }

    private func configureDeleted() {
        deleted.onRecovered = { [secrets] in secrets.reload() }
        deleted.opsFactory = { [secrets] vault in secrets.clientFactory(vault).map(DeletedSecretsOps.init(client:)) }
    }

    private func configureEditor() {
        editor.opsFactory = { [secrets] vault in secrets.clientFactory(vault).map(SecretEditorOps.init(client:)) }
        editor.onChanged = { [secrets, detail] vault, name in
            SecretValueCache.shared.remove(.init(vault: vault.vaultUri.absoluteString, name: name))
            await secrets.refresh()
            secrets.selection = [name]
            await detail.show(vault: vault, name: name)
        }
    }

    private func refreshAll() {
        context.reload()
        Task { await secrets.refresh() }
        if context.showsDeletedSecrets { Task { await deleted.refresh() } }
    }

    private var menuActions: MenuActions {
        var a = MenuActions()
        let vault = context.selectedVault
        a.hasVault = vault != nil
        a.hasSelection = !secrets.selection.isEmpty
        a.hasSingleSelection = secrets.selection.count == 1
        a.canEdit = secrets.selection.count == 1 && detail.phase == .loaded && detail.value != nil
        if palette.isPresented {
            a.hasVault = false
            a.hasSelection = false
            a.hasSingleSelection = false
            a.canEdit = false
        }
        a.showsDeleted = context.showsDeletedSecrets
        a.isFavorite = vault.map { context.isFavorite($0) } ?? false
        a.newSecret = { [editor, context] in editor.beginCreate(vault: context.selectedVault) }
        a.editSecret = { [editor, secrets, detail] in editor.beginEdit(vault: secrets.vault, bundle: detail.bundle) }
        a.copyValue = { [detail] in detail.copy() }
        a.copyName = { [secrets] in SecretsView.copy(names: secrets.selectedNames()) }
        a.toggleReveal = { [detail] in detail.toggleReveal() }
        a.deleteSecrets = { [requests] in requests.requestDelete() }
        a.versions = { [requests] in requests.requestVersions() }
        a.refresh = { refreshAll() }
        a.focusFilter = { [requests] in requests.requestFocusFilter() }
        a.palette = { [palette] in palette.toggle() }
        a.focusPane = { pane = $0 }
        a.switcher = { switcher = $0 }
        a.toggleDeleted = { [context] in context.showsDeletedSecrets.toggle() }
        a.toggleFavorite = { [context] in if let v = context.selectedVault { context.toggleFavorite(v) } }
        a.openPortal = { [context] in
            if let v = context.selectedVault, let url = ContextModel.portalURL(for: v, tenant: context.selectedTenantID)
            {
                NSWorkspace.shared.open(url)
            }
        }
        a.copyVaultURI = { [context] in
            guard let v = context.selectedVault else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(v.vaultUri.absoluteString, forType: .string)
        }
        return a
    }

    private func switchItems(_ kind: QuickSwitchKind) -> [QuickSwitchItem] {
        switch kind {
        case .account:
            model.accounts.map {
                .init(id: $0.id.uuidString, title: $0.displayName, isCurrent: $0.id == model.selectedAccountID)
            }
        case .tenant:
            context.tenants.map {
                .init(
                    id: $0.tenantId, title: $0.displayName ?? $0.defaultDomain ?? $0.tenantId,
                    isCurrent: $0.tenantId == context.selectedTenantID)
            }
        case .subscription:
            context.subscriptions.map {
                .init(
                    id: $0.subscriptionId, title: $0.displayName,
                    isCurrent: $0.subscriptionId == context.selectedSubscriptionID)
            }
        }
    }

    private func selectSwitch(_ kind: QuickSwitchKind, _ id: String) {
        switch kind {
        case .account: model.select(UUID(uuidString: id))
        case .tenant: context.selectTenant(id)
        case .subscription: context.selectSubscription(id)
        }
    }

    @ViewBuilder private var paletteOverlay: some View {
        if palette.isPresented {
            ZStack(alignment: .top) {
                Color.black.opacity(0.15).ignoresSafeArea().onTapGesture { palette.close() }
                CommandPaletteView().padding(.top, 80)
            }
        }
    }

    private func configurePalette() {
        palette.currentSubscription = { [context] in context.selectedSubscriptionID }
        palette.discover = { [model, context] tenant in
            guard let account = context.account, let provider = model.tokenProvider(for: account) else {
                return []
            }
            return try await ARMClient(tokenProvider: provider, transport: model.transport).discoverVaults(
                tenant: tenant)
        }
        palette.makeLister = { [model, context] tenant in
            guard let account = context.account, let provider = model.tokenProvider(for: account) else { return nil }
            return NameIndex.keyVaultLister(tokenProvider: provider, tenant: tenant, transport: model.transport)
        }
        palette.fetchValue = { [secrets] vault, name in
            guard let client = secrets.clientFactory(vault) else { throw CancellationError() }
            return try await client.getSecret(name: name).value ?? ""
        }
        palette.navigate = { [context, secrets] vault, name in
            await PaletteNavigator.navigate(vault: vault, secret: name, context: context, secrets: secrets)
        }
    }

    private func switchAccount() {
        palette.reset()
        secrets.invalidateCache()
        let account = model.selectedAccount
        let client = account.flatMap { model.tokenProvider(for: $0) }.map {
            ARMClient(tokenProvider: $0, transport: model.transport)
        }
        context.switchAccount(account, client: client)
    }
}
