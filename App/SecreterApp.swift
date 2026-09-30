import SwiftUI

@main
struct SecreterApp: App {
    @State private var model = UITestSupport.isActive ? AppModel.uiTest() : AppModel()
    @State private var lock = LockModel.makeDefault()
    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup(id: SecreterApp.mainWindowID) {
            RootView()
                .environment(model)
                .appLock()
                .environment(lock)
        }
        Settings {
            SettingsView()
                .environment(model)
        }
        .commands {
            NewWindowCommand()
            SecreterCommands()
            CommandGroup(after: .appSettings) {
                Button("Lock Secreter") { lock.lock() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(!lock.isEnabled)
            }
        }
    }
}

/// ⌘N is "New Secret"; New Window moves to ⇧⌘N so the two don't collide.
private struct NewWindowCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: SecreterApp.mainWindowID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
