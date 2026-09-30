import Persistence
import SwiftUI

@main
struct KeystoneApp: App {
    @State private var model: AppModel
    @State private var lock: LockModel
    static let mainWindowID = "main"

    init() {
        if !UITestSupport.isActive { LegacyMigrator().run() }
        _model = State(initialValue: UITestSupport.isActive ? AppModel.uiTest() : AppModel())
        _lock = State(initialValue: LockModel.makeDefault())
    }

    var body: some Scene {
        WindowGroup(id: KeystoneApp.mainWindowID) {
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
            KeystoneCommands()
            CommandGroup(after: .appSettings) {
                Button("Lock Keystone") { lock.lock() }
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
            Button("New Window") { openWindow(id: KeystoneApp.mainWindowID) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }
}
