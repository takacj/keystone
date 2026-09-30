import SwiftUI

enum Pane: Hashable { case sidebar, list, detail }

enum QuickSwitchKind: String, Identifiable {
    case account = "Account"
    case tenant = "Tenant"
    case subscription = "Subscription"
    var id: String { rawValue }
}

/// One-shot requests from menu commands to views that own the relevant state.
@MainActor @Observable
final class ViewRequests {
    private(set) var focusFilter = 0
    private(set) var deleteSelected = 0
    private(set) var showVersions = 0
    func requestFocusFilter() { focusFilter += 1 }
    func requestDelete() { deleteSelected += 1 }
    func requestVersions() { showVersions += 1 }
}

/// Actions the focused main window exposes to the menu bar.
struct MenuActions {
    var hasVault = false
    var hasSelection = false
    var hasSingleSelection = false
    var canEdit = false
    var showsDeleted = false
    var isFavorite = false
    var newSecret: () -> Void = {}
    var editSecret: () -> Void = {}
    var copyValue: () -> Void = {}
    var copyName: () -> Void = {}
    var toggleReveal: () -> Void = {}
    var deleteSecrets: () -> Void = {}
    var versions: () -> Void = {}
    var refresh: () -> Void = {}
    var focusFilter: () -> Void = {}
    var palette: () -> Void = {}
    var focusPane: (Pane) -> Void = { _ in }
    var switcher: (QuickSwitchKind) -> Void = { _ in }
    var toggleDeleted: () -> Void = {}
    var toggleFavorite: () -> Void = {}
    var openPortal: () -> Void = {}
    var copyVaultURI: () -> Void = {}
}

extension FocusedValues {
    @Entry var menuActions: MenuActions?
}

/// Menu bar: Secret, Vault menus plus View/Find additions.
struct SecreterCommands: Commands {
    @FocusedValue(\.menuActions) private var actions

    var body: some Commands {
        let a = actions ?? MenuActions()
        let live = actions != nil
        CommandMenu("Secret") {
            Button("New Secret") { a.newSecret() }
                .keyboardShortcut("n", modifiers: .command).disabled(!live || !a.hasVault)
            Button("Edit Secret") { a.editSecret() }
                .keyboardShortcut("e", modifiers: .command).disabled(!live || !a.canEdit)
            Divider()
            Button("Copy Value (⌘C on a row)") { a.copyValue() }.disabled(!live || !a.hasSingleSelection)
            Button("Copy Name") { a.copyName() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(!live || !a.hasSelection)
            Button("Reveal / Hide Value (Space)") { a.toggleReveal() }.disabled(!live || !a.canEdit)
            Button("Version History") { a.versions() }
                .keyboardShortcut("y", modifiers: .command).disabled(!live || !a.canEdit)
            Divider()
            Button("Delete…") { a.deleteSecrets() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!live || !a.hasSelection || a.showsDeleted)
        }
        CommandMenu("Vault") {
            Button("Command Palette") { a.palette() }
                .keyboardShortcut("k", modifiers: .command).disabled(!live)
            Button("Refresh") { a.refresh() }
                .keyboardShortcut("r", modifiers: .command).disabled(!live)
            Divider()
            Button(a.showsDeleted ? "Show Secrets" : "Show Deleted Secrets") { a.toggleDeleted() }
                .disabled(!live || !a.hasVault)
            Button(a.isFavorite ? "Remove from Favorites" : "Add to Favorites") { a.toggleFavorite() }
                .disabled(!live || !a.hasVault)
            Button("Open in Azure Portal") { a.openPortal() }.disabled(!live || !a.hasVault)
            Button("Copy Vault URI") { a.copyVaultURI() }.disabled(!live || !a.hasVault)
            Divider()
            Button("Switch Account…") { a.switcher(.account) }
                .keyboardShortcut("a", modifiers: [.command, .shift]).disabled(!live)
            Button("Switch Tenant…") { a.switcher(.tenant) }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!live)
            Button("Switch Subscription…") { a.switcher(.subscription) }
                .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(!live)
        }
        CommandGroup(after: .sidebar) {
            Button("Focus Sidebar") { a.focusPane(.sidebar) }
                .keyboardShortcut("1", modifiers: .command).disabled(!live)
            Button("Focus Secret List") { a.focusPane(.list) }
                .keyboardShortcut("2", modifiers: .command).disabled(!live)
            Button("Focus Detail") { a.focusPane(.detail) }
                .keyboardShortcut("3", modifiers: .command).disabled(!live)
        }
        CommandGroup(after: .textEditing) {
            Button("Filter Secrets") { a.focusFilter() }
                .keyboardShortcut("f", modifiers: .command).disabled(!live || !a.hasVault)
        }
    }
}
